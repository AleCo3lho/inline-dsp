import AVFAudio
import AudioToolbox
import CoreAudio
import Foundation
import Observation

struct EngineError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Owns the device bindings and the AVAudioEngine lifecycle. Every mutation happens on the main
/// queue: HAL listeners, engine notifications, timers and signals are all delivered there, so the
/// process idles in the main run loop with no polling. Observable so the menu bar UI can bind to
/// its status, meters and live DSP settings.
@MainActor
@Observable
final class BroadcastEngine {
    struct Options {
        /// Empty = the macOS default input device.
        var inputQuery = ""
        var outputQuery = "VB-Cable"
        var inputChannel = InputChannelSelection.microphone
        var bufferFrames: UInt32 = 128
        var statusInterval: TimeInterval = 30
        var settings = DSPSettings()
    }

    enum Status: Equatable {
        case stopped, starting, running, recovering, waiting

        var label: String {
            switch self {
            case .stopped: "Stopped"
            case .starting: "Starting…"
            case .running: "Running"
            case .recovering: "Recovering from a device change…"
            case .waiting: "Waiting for devices"
            }
        }
    }

    struct DeviceChoice: Hashable, Identifiable {
        let uid: String
        let name: String
        var id: String { uid }
    }

    struct Meters: Equatable {
        var inputPeakDB = -Float.infinity
        var outputPeakDB = -Float.infinity
        /// Gate attenuation and limiter gain (<= 0); compressor and de-esser reduction (>= 0).
        var gateDB: Float = 0
        var compressorDB: Float = 0
        var deEsserDB: Float = 0
        var limiterDB: Float = 0
    }

    // MARK: Observable state

    private(set) var status = Status.stopped {
        didSet { if status != oldValue { Log.info("State: \(oldValue.label) -> \(status.label)") } }
    }
    private(set) var meters = Meters()
    private(set) var lastError: String?
    /// Channel names of the bound input device, for the channel picker.
    private(set) var inputChannelNames: [String] = []
    private(set) var activeInputChannel: Int?
    /// The XLR mic input's channel name on the bound device, if the device has a known profile.
    private(set) var micChannelName: String?
    private(set) var routeDescription: String?

    /// Devices offered by the menu pickers, kept current through hot-plug.
    private(set) var inputDevices: [DeviceChoice] = []
    private(set) var outputDevices: [DeviceChoice] = []
    /// UIDs of the devices the current selections resolve to (nil if not connected).
    private(set) var selectedInputUID: String?
    private(set) var selectedOutputUID: String?

    /// Input device as a name or UID (the pickers store UIDs). Changing it resets the channel to
    /// the device's mic input and rebuilds the session on the new device pair.
    var inputDevice: String {
        didSet {
            guard inputDevice != oldValue else { return }
            Preferences.inputDevice = inputDevice
            isChangingDevice = true
            inputChannel = .microphone
            isChangingDevice = false
            deviceSelectionChanged()
        }
    }

    /// Output (virtual cable) device as a name or UID.
    var outputDevice: String {
        didSet {
            guard outputDevice != oldValue else { return }
            Preferences.outputDevice = outputDevice
            deviceSelectionChanged()
        }
    }

    /// Live DSP settings: changes are applied to the running units immediately and persisted.
    var settings: DSPSettings {
        didSet {
            guard settings != oldValue else { return }
            Preferences.settings = settings
            guard let chain = session?.chain else { return }
            chain.apply(settings)
        }
    }

    /// Which device channel is captured; changing it re-maps the running engine in place.
    var inputChannel: InputChannelSelection {
        didSet {
            guard inputChannel != oldValue else { return }
            Preferences.inputChannel = inputChannel
            guard !isChangingDevice else { return }
            if session == nil { refreshDeviceLists() }
            remapInputChannel()
        }
    }

    // MARK: Private state

    /// Everything tied to one engine instance. Configuration changes are recovered in place on the
    /// same session; only losing a device tears it down and builds a new one.
    private final class Session {
        let engine: AVAudioEngine
        let chain: DSPChain
        let input: AudioDevice
        let output: AudioDevice
        let aggregateID: AudioObjectID
        var channel: InputChannelSelection.Resolved
        var listeners: [PropertyListener] = []
        var configObserver: NSObjectProtocol?
        let inputMeter = PeakMeter()
        let outputMeter = PeakMeter()

        init(engine: AVAudioEngine, chain: DSPChain, input: AudioDevice, output: AudioDevice,
             aggregateID: AudioObjectID, channel: InputChannelSelection.Resolved) {
            self.engine = engine
            self.chain = chain
            self.input = input
            self.output = output
            self.aggregateID = aggregateID
            self.channel = channel
        }

        /// Input meter sits on the capture (raw mic level, before any processing); output meter
        /// on the main mixer (what the virtual driver receives).
        func installMeters() {
            inputMeter.install(on: engine.inputNode)
            outputMeter.install(on: engine.mainMixerNode)
        }

        func removeMeters() {
            engine.inputNode.removeTap(onBus: 0)
            engine.mainMixerNode.removeTap(onBus: 0)
        }
    }

    @ObservationIgnored private let options: Options
    @ObservationIgnored private var session: Session?
    @ObservationIgnored private var deviceListListener: PropertyListener?
    @ObservationIgnored private var statusTimer: DispatchSourceTimer?
    @ObservationIgnored private var meterTimer: Timer?
    @ObservationIgnored private var pendingReconcile: DispatchWorkItem?
    @ObservationIgnored private var retryDelay: TimeInterval = 1
    @ObservationIgnored private var watchdogTimer: DispatchSourceTimer?
    @ObservationIgnored private var silentChecks = 0
    @ObservationIgnored private var watchdogRebuilds = 0
    /// A freshly built engine must show live input quickly; until then silence is judged sooner.
    @ObservationIgnored private var probationUntil = Date.distantPast
    @ObservationIgnored private var runningSince: Date?
    @ObservationIgnored private var overloads = 0
    /// Device sample rates are forced to 48 kHz only on a user-initiated start. After that the
    /// engine adapts to whatever rate the hardware has: fighting a browser that re-clocks a
    /// device mid-call just ping-pongs configuration changes between the two processes.
    @ObservationIgnored private var enforceDeviceFormats = true
    @ObservationIgnored private var isChangingDevice = false

    init(options: Options) {
        self.options = options
        self.settings = options.settings
        self.inputChannel = options.inputChannel
        self.inputDevice = options.inputQuery
        self.outputDevice = options.outputQuery
        do {
            deviceListListener = try PropertyListener(
                objectID: AudioObjectID(kAudioObjectSystemObject),
                selector: kAudioHardwarePropertyDevices
            ) { [weak self] in
                MainActor.assumeIsolated {
                    self?.refreshDeviceLists()
                    self?.scheduleReconcile(reason: "device list changed")
                }
            }
        } catch {
            Log.warn("Hot-plug monitoring unavailable: \(error)")
        }
        refreshDeviceLists()
    }

    /// Re-reads the device lists and resolves the current selections against them. While no
    /// session is running it also fills the channel picker from the selected input device.
    func refreshDeviceLists() {
        let devices = (try? AudioSystem.allDevices()) ?? []
        inputDevices = devices.filter { $0.inputChannels > 0 }.map { DeviceChoice(uid: $0.uid, name: $0.name) }
        outputDevices = devices.filter { $0.outputChannels > 0 }.map { DeviceChoice(uid: $0.uid, name: $0.name) }
        let input = try? resolveInputDevice()
        selectedInputUID = input?.uid
        selectedOutputUID = (try? AudioSystem.findDevice(matching: outputDevice, direction: .output))?.uid
        guard session == nil else { return }
        if let input {
            inputChannelNames = AudioSystem.channelNames(input.id, .input)
            micChannelName = MicInputProfile.micChannelName(for: input)
            activeInputChannel = (try? inputChannel.resolve(on: input))?.index
        } else {
            inputChannelNames = []
            activeInputChannel = nil
        }
    }

    /// The chosen input device, or the macOS default input when none has been chosen.
    private func resolveInputDevice() throws -> AudioDevice {
        inputDevice.isEmpty ? try AudioSystem.defaultDevice(.input)
                            : try AudioSystem.findDevice(matching: inputDevice, direction: .input)
    }

    private func deviceSelectionChanged() {
        refreshDeviceLists()
        guard status != .stopped else { return }
        pendingReconcile?.cancel()
        teardown(reason: "device selection changed")
        enforceDeviceFormats = true
        retryDelay = 1
        status = .starting
        attemptStart()
    }

    // MARK: Lifecycle

    func start() {
        guard status == .stopped else { return }
        status = .starting
        lastError = nil
        enforceDeviceFormats = true
        retryDelay = 1
        refreshDeviceLists()
        startStatusTimer()
        startWatchdog()
        attemptStart()
    }

    func stop() {
        guard status != .stopped else { return }
        pendingReconcile?.cancel()
        statusTimer?.cancel()
        statusTimer = nil
        watchdogTimer?.cancel()
        watchdogTimer = nil
        teardown(reason: "stop requested")
        status = .stopped
        meters = Meters()
        routeDescription = nil
    }

    /// Menu bar meters refresh at 10 Hz only while the panel is visible.
    func setMetering(_ enabled: Bool) {
        meterTimer?.invalidate()
        meterTimer = nil
        guard enabled else { return }
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshMeters() }
        }
    }

    private func attemptStart() {
        guard status != .stopped, session == nil else { return }
        do {
            let session = try makeSession()
            self.session = session
            runningSince = Date()
            probationUntil = Date().addingTimeInterval(5)
            retryDelay = 1
            enforceDeviceFormats = false
            lastError = nil
            status = .running
            logSummary(session)
        } catch {
            report("Engine start failed: \(error)")
            status = .waiting
            Log.info("Retrying in \(Int(retryDelay)) s (or immediately when the device list changes)")
            scheduleReconcile(reason: "retry", after: retryDelay)
            retryDelay = min(retryDelay * 2, 30)
        }
    }

    private func teardown(reason: String, keepAggregate: Bool = false) {
        guard let session else { return }
        Log.info("Stopping engine (\(reason))")
        session.listeners.forEach { $0.invalidate() }
        if let observer = session.configObserver { NotificationCenter.default.removeObserver(observer) }
        session.removeMeters()
        session.engine.stop()
        if !keepAggregate { AudioSystem.destroyAggregate(session.aggregateID) }
        self.session = nil
        routeDescription = nil
        silentChecks = 0
        runningSince = nil
    }

    func report(_ message: String) {
        Log.error(message)
        lastError = message
    }

    // MARK: Configuration changes and hot-plug

    /// Debounced: bursts of notifications (a browser opening devices for a call, a USB
    /// interface enumerating) collapse into one reconcile pass.
    private func scheduleReconcile(reason: String, after delay: TimeInterval = 0.3) {
        guard status != .stopped else { return }
        pendingReconcile?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.reconcile(reason: reason) }
        }
        pendingReconcile = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Three outcomes, cheapest first:
    /// 1. Engine still running: the notification was non-destructive (another app opened a
    ///    device, a buffer size changed). Nothing to do.
    /// 2. Engine stopped but both devices still present: AVAudioEngine stops itself on any I/O
    ///    reconfiguration (e.g. a browser starting voice processing for a call). Restarting that
    ///    same engine instance was measured to resume with a dead input (exact digital silence),
    ///    so a fresh engine is built on the *existing* aggregate. No device is created or
    ///    destroyed, so the browser in the call sees no device-list change.
    /// 3. A device is gone, or the engine rebuild fails: tear everything down and start over.
    private func reconcile(reason: String) {
        if let session {
            let inputPresent = AudioSystem.deviceExists(session.input.id)
            let outputPresent = AudioSystem.deviceExists(session.output.id)
            if inputPresent && outputPresent {
                if session.engine.isRunning {
                    if status != .running { status = .running }
                    return
                }
                do {
                    try rebuildEngine(reason: reason)
                    return
                } catch {
                    report("Engine rebuild after \(reason) failed: \(error)")
                }
            } else {
                Log.warn("Device lost after \(reason): input present=\(inputPresent), output present=\(outputPresent)")
                teardown(reason: reason)
            }
            status = .waiting
        }
        attemptStart()
    }

    /// Replaces the AVAudioEngine (re-reading the hardware formats and re-applying the channel
    /// maps) while keeping the devices and the aggregate. On failure the aggregate is released
    /// and `session` is nil, so the caller falls back to a full start.
    private func rebuildEngine(reason: String) throws {
        guard let previous = session else { return }
        let begin = Date()
        status = .recovering
        teardown(reason: reason, keepAggregate: true)
        do {
            let session = try makeSession(reusing: previous)
            self.session = session
            runningSince = Date()
            probationUntil = Date().addingTimeInterval(5)
            lastError = nil
            status = .running
            Log.info(String(format: "Engine rebuilt on the existing aggregate after %@ in %.0f ms",
                            reason, Date().timeIntervalSince(begin) * 1000))
        } catch {
            AudioSystem.destroyAggregate(previous.aggregateID)
            throw error
        }
    }

    private func remapInputChannel() {
        guard session != nil else { return }
        do {
            try rebuildEngine(reason: "input channel change")
        } catch {
            report("Changing input channel failed: \(error)")
            status = .waiting
            scheduleReconcile(reason: "input channel change")
        }
    }

    /// A live microphone never produces exact zeros (even an empty Scarlett input reads about
    /// -99 dBFS of noise). Exact digital silence while the engine claims to run means the I/O
    /// path is broken, so rebuild it: after 2 s for an engine still on probation (just built),
    /// 6 s otherwise. Checks back off if a device keeps genuinely delivering zeros (e.g. a
    /// hardware-muted input).
    private func startWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(200))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.checkInputAlive() }
        }
        timer.resume()
        watchdogTimer = timer
    }

    private func checkInputAlive() {
        guard let session, session.engine.isRunning, status == .running else { return }
        if (session.inputMeter.drain(.watchdog).max() ?? 0) > 0 {
            silentChecks = 0
            watchdogRebuilds = 0
            return
        }
        silentChecks += 1
        let limit = watchdogRebuilds >= 5 ? 60 : Date() < probationUntil ? 2 : 6
        guard silentChecks >= limit else { return }
        silentChecks = 0
        watchdogRebuilds += 1
        Log.warn("Input has delivered exact digital silence for \(limit) s; rebuilding the engine")
        do {
            try rebuildEngine(reason: "silent input")
        } catch {
            report("Engine rebuild after silent input failed: \(error)")
            status = .waiting
            attemptStart()
        }
    }

    // MARK: Session construction

    /// Builds a session: devices, aggregate and engine, or only a new engine on `previous`'s
    /// devices and aggregate.
    private func makeSession(reusing previous: Session? = nil) throws -> Session {
        let input = try previous?.input ?? resolveInputDevice()
        let output = try previous?.output ?? AudioSystem.findDevice(matching: outputDevice, direction: .output)
        guard input.id != output.id else {
            throw EngineError("Input and output are the same device (\(input.name)). Pick a different output.")
        }
        let channel = try inputChannel.resolve(on: input)
        inputChannelNames = AudioSystem.channelNames(input.id, .input)
        micChannelName = MicInputProfile.micChannelName(for: input)
        if previous == nil {
            Log.info("Input  device: \(input)")
            Log.info("Output device: \(output)")
        }
        Log.info("Input channel: \"\(channel.name)\" (index \(channel.index), \(channel.reason))")
        if previous == nil && enforceDeviceFormats { prepareDevices(input: input, output: output) }

        // On macOS, AVAudioEngine's inputNode and outputNode are two faces of ONE AUHAL
        // (`inputNode.auAudioUnit === outputNode.auAudioUnit`), so setDeviceID on one rebinds
        // both and the last call wins. Two devices on independent clocks are therefore joined
        // in a private aggregate: the interface is the clock source and the HAL drift-compensates
        // the virtual driver to it. Sub-device order fixes the channel layout: output device
        // channels come first, then the input device's.
        let aggregateID = try previous?.aggregateID ?? AudioSystem.createPrivateAggregate(
            name: "inline-dsp (\(input.name) -> \(output.name))",
            clock: input, drifting: output, subDevices: [output, input]
        )
        // A reused aggregate is released by the caller (`rebuildEngine`) if this fails.
        var keepAggregate = previous != nil
        defer { if !keepAggregate { AudioSystem.destroyAggregate(aggregateID) } }
        if previous == nil && enforceDeviceFormats {
            do {
                try AudioSystem.ensureNominalSampleRate(aggregateID, BroadcastFormat.sampleRate)
            } catch {
                Log.warn("Aggregate device is not at \(Int(BroadcastFormat.sampleRate)) Hz (\(error)); resampling instead")
            }
        }

        let engine = AVAudioEngine()
        try engine.outputNode.auAudioUnit.setDeviceID(aggregateID)
        try engine.inputNode.auAudioUnit.setDeviceID(aggregateID)
        guard engine.inputNode.auAudioUnit.deviceID == aggregateID,
              engine.outputNode.auAudioUnit.deviceID == aggregateID else {
            throw EngineError("I/O unit did not bind to aggregate device \(aggregateID)")
        }
        setBufferFrameSize(engine.outputNode)

        let (hardwareInput, hardwareOutput) = try hardwareFormats(engine)
        let chain = try DSPChain(settings: settings)
        try chain.install(in: engine, captureFormat: captureFormat(hardwareInput))
        try connectOutput(engine, hardwareOutput)

        let session = Session(engine: engine, chain: chain, input: input, output: output,
                              aggregateID: aggregateID, channel: channel)
        try applyChannelMaps(engine, session: session)
        session.installMeters()

        engine.prepare()
        do {
            try engine.start()
        } catch {
            session.removeMeters()
            throw error
        }
        keepAggregate = true

        session.configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                Log.info("Engine configuration change notified; verifying session")
                // Another process reconfiguring a device (a browser starting a call) leaves the
                // aggregate unsettled for a moment; an engine built immediately was measured to
                // come up with a dead input, so give the HAL a second first.
                self?.scheduleReconcile(reason: "engine configuration change", after: 1)
            }
        }
        session.listeners = deviceListeners(input: input, output: output, aggregateID: aggregateID)
        activeInputChannel = channel.index
        selectedInputUID = input.uid
        selectedOutputUID = output.uid
        updateRoute(session)
        return session
    }

    private func hardwareFormats(_ engine: AVAudioEngine) throws -> (input: AVAudioFormat, output: AVAudioFormat) {
        let input = engine.inputNode.inputFormat(forBus: 0)
        guard input.sampleRate > 0, input.channelCount > 0 else {
            throw EngineError("Input reports no usable format (\(input)); device busy or unplugged?")
        }
        let output = engine.outputNode.outputFormat(forBus: 0)
        guard output.sampleRate > 0, output.channelCount >= BroadcastFormat.channels else {
            throw EngineError("Output reports no usable stereo format (\(output))")
        }
        return (input, output)
    }

    /// Mono capture: only one channel leaves the AUHAL; the channel map pins it to the mic.
    private func captureFormat(_ hardwareInput: AVAudioFormat) -> AVAudioFormat {
        AVAudioFormat(standardFormatWithSampleRate: hardwareInput.sampleRate, channels: 1)!
    }

    private func connectOutput(_ engine: AVAudioEngine, _ hardwareOutput: AVAudioFormat) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: hardwareOutput.sampleRate, channels: BroadcastFormat.channels)!
        try catchingObjCException("Connecting output at \(Int(format.sampleRate)) Hz") {
            engine.connect(engine.mainMixerNode, to: engine.outputNode, format: format)
        }
    }

    /// Locks both devices to the 48 kHz contract and stamps the interleaved stereo float format
    /// onto the virtual output's streams. Best-effort: a refusal is logged and the mixers
    /// resample instead, which keeps the chain running.
    private func prepareDevices(input: AudioDevice, output: AudioDevice) {
        for device in [input, output] where device.nominalSampleRate != BroadcastFormat.sampleRate {
            do {
                try AudioSystem.ensureNominalSampleRate(device.id, BroadcastFormat.sampleRate)
                Log.info("Set \"\(device.name)\" nominal rate \(Int(device.nominalSampleRate)) -> \(Int(BroadcastFormat.sampleRate)) Hz")
            } catch {
                Log.warn("Could not set \"\(device.name)\" to \(Int(BroadcastFormat.sampleRate)) Hz (\(error)); resampling instead")
            }
        }
        do {
            let formats = try AudioSystem.applyPhysicalFormat(BroadcastFormat.streamDescription, to: output.id, direction: .output)
            let matches = formats.allSatisfy { $0 == BroadcastFormat.streamDescription }
            let summary = formats.map { "\($0.mChannelsPerFrame)ch \(Int($0.mSampleRate)) Hz \($0.mBitsPerChannel)-bit" }
            if matches {
                Log.info("\"\(output.name)\" physical stream format: \(BroadcastFormat.interleaved)")
            } else {
                Log.warn("\"\(output.name)\" kept physical format(s) \(summary.joined(separator: ", "))")
            }
        } catch {
            Log.warn("Could not apply stereo stream format to \"\(output.name)\": \(error)")
        }
    }

    private func setBufferFrameSize(_ node: AVAudioIONode) {
        guard let unit = node.audioUnit else { return }
        var frames = options.bufferFrames
        let size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioUnitSetProperty(unit, kAudioDevicePropertyBufferFrameSize, kAudioUnitScope_Global, 0, &frames, size)
        if status != noErr {
            Log.warn("Could not set I/O buffer to \(options.bufferFrames) frames: \(fourCC(status))")
        }
    }

    /// kAudioOutputUnitProperty_ChannelMap has one entry per *destination* channel naming the
    /// *source* channel that feeds it (-1 = silence).
    /// - Input side (output scope, element 1): destination = client channels (mono), source =
    ///   aggregate input channels, so the single entry picks the mic channel. The input
    ///   device's channels follow the output device's in the aggregate.
    /// - Output side (input scope, element 0): destination = aggregate output channels, source
    ///   = the engine's stereo bus, so L/R land on the virtual driver and the interface's own
    ///   outputs (also part of the aggregate) receive silence.
    private func applyChannelMaps(_ engine: AVAudioEngine, session: Session) throws {
        guard let unit = engine.outputNode.audioUnit else { throw EngineError("Engine has no AUHAL") }
        let inputChannel = session.output.inputChannels + session.channel.index

        var client = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &client, &size),
                  "Reading input client format")
        var inputMap = [Int32](repeating: Int32(inputChannel), count: max(Int(client.mChannelsPerFrame), 1))
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_ChannelMap, kAudioUnitScope_Output, 1,
                                       &inputMap, UInt32(inputMap.count * MemoryLayout<Int32>.size)),
                  "Setting input channel map \(inputMap)")

        let stereo = 0..<Int(BroadcastFormat.channels)
        let deviceOutputs = AudioSystem.channelCount(session.aggregateID, .output)
        var outputMap = (0..<deviceOutputs).map { stereo.contains($0) ? Int32($0) : -1 }
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_ChannelMap, kAudioUnitScope_Input, 0,
                                       &outputMap, UInt32(outputMap.count * MemoryLayout<Int32>.size)),
                  "Setting output channel map \(outputMap)")

        Log.info("Channel map: aggregate input \(inputMap) -> mono -> stereo upmix -> aggregate outputs \(outputMap)")
    }

    private func deviceListeners(input: AudioDevice, output: AudioDevice, aggregateID: AudioObjectID) -> [PropertyListener] {
        var listeners: [PropertyListener] = []
        for device in [input, output] {
            let name = device.name
            do {
                listeners.append(try PropertyListener(objectID: device.id, selector: kAudioDevicePropertyDeviceIsAlive) { [weak self] in
                    MainActor.assumeIsolated {
                        Log.warn("\"\(name)\" is no longer alive")
                        self?.scheduleReconcile(reason: "\"\(name)\" disconnected", after: 0)
                    }
                })
            } catch {
                Log.warn("Could not monitor \"\(name)\": \(error)")
            }
        }
        // The I/O cycle runs on the aggregate, so that is where overloads are reported.
        do {
            listeners.append(try PropertyListener(objectID: aggregateID, selector: kAudioDeviceProcessorOverload) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if self.overloads == 0 { Log.warn("I/O cycle overload (consider a larger --buffer)") }
                    self.overloads += 1
                }
            })
        } catch {
            Log.warn("Could not monitor I/O overloads: \(error)")
        }
        return listeners
    }

    private func updateRoute(_ session: Session) {
        routeDescription = "\(session.input.name) · \(session.channel.name) → \(session.output.name)"
    }

    // MARK: Status

    private func refreshMeters() {
        guard let session, session.engine.isRunning else {
            meters = Meters()
            return
        }
        meters = Meters(
            // The panel's input meter shows what the gate hears (after the high-pass), so its
            // threshold marker is directly comparable; the raw capture is in the status log.
            inputPeakDB: session.chain.takeDetectorPeakDB(),
            outputPeakDB: linearToDB(session.outputMeter.drain(.ui).max() ?? 0),
            gateDB: session.chain.gateGainDB,
            compressorDB: session.chain.compressorReductionDB,
            deEsserDB: session.chain.deEsserReductionDB,
            limiterDB: session.chain.limiterGainDB
        )
    }

    private func startStatusTimer() {
        guard options.statusInterval > 0 else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + options.statusInterval, repeating: options.statusInterval, leeway: .seconds(1))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.logStatus() }
        }
        timer.resume()
        statusTimer = timer
    }

    private func logStatus() {
        guard let session, let runningSince else {
            Log.info("Status: \(status.label) (input \"\(inputDevice.isEmpty ? "system default" : inputDevice)\", output \"\(outputDevice)\")")
            return
        }
        let input = formatDB(linearToDB(session.inputMeter.drain(.log).max() ?? 0))
        let output = session.outputMeter.drain(.log).map { formatDB(linearToDB($0)) }
        Log.info([
            "Status: \(session.engine.isRunning ? "running" : "NOT RUNNING")",
            "uptime \(Self.duration(Date().timeIntervalSince(runningSince)))",
            "in peak \(input) dBFS",
            "gate \(formatDB(session.chain.gateGainDB)) dB",
            "comp GR \(formatDB(session.chain.compressorReductionDB)) dB",
            "de-ess GR \(formatDB(session.chain.deEsserReductionDB)) dB",
            "limiter \(formatDB(session.chain.limiterGainDB)) dB",
            "out peak L \(output[0]) / R \(output[1]) dBFS",
            "overloads \(overloads)",
        ].joined(separator: " | "))
        overloads = 0
    }

    private func logSummary(_ session: Session) {
        let engine = session.engine
        let rate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        let dspLatency = session.chain.nodes.reduce(0) { $0 + $1.latency }
        let ioLatency = engine.inputNode.presentationLatency + engine.outputNode.presentationLatency
        Log.info("Clock:   \"\(session.input.name)\" drives a private aggregate (id \(session.aggregateID)); \"\(session.output.name)\" is drift-compensated")
        Log.info("Capture: \(engine.inputNode.outputFormat(forBus: 0))")
        Log.info("Graph:   voice processor [HPF -> gate -> compressor -> tone EQ -> de-esser -> limiter] -> stereo upmix")
        Log.info("Output:  \(engine.outputNode.inputFormat(forBus: 0))")
        Log.info(String(format: "Latency: I/O %.1f ms + DSP %.1f ms (requested buffer %u frames = %.1f ms @ %.0f Hz)",
                        ioLatency * 1000, dspLatency * 1000, options.bufferFrames,
                        Double(options.bufferFrames) / rate * 1000, rate))
        Log.info("Ceiling: \(formatDB(settings.limiterCeilingDB)) dBFS | Running.")
    }

    private static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return String(format: "%02d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
    }
}
