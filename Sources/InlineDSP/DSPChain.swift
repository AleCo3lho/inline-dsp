import AVFAudio
import AudioToolbox
import ObjCExceptionCatcher

/// Runs AVAudioEngine graph calls that report misconfiguration by raising an NSException.
func catchingObjCException(_ operation: String, _ block: () -> Void) throws {
    do {
        try ObjCExceptionCatcher.catching(block)
    } catch {
        throw EngineError("\(operation): \(error.localizedDescription)")
    }
}

// MARK: - Broadcast format

enum BroadcastFormat {
    static let sampleRate: Double = 48_000
    static let channels: UInt32 = 2

    /// The hardcoded device-facing stream contract: 48 kHz, 32-bit float, 2ch, interleaved.
    /// Applied as the physical format of the virtual output device (VB-Cable) so it presents
    /// itself exactly like a stereo hardware interface to downstream apps.
    static var streamDescription: AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, // no NonInterleaved flag => interleaved
            mBytesPerPacket: 4 * channels,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4 * channels,
            mChannelsPerFrame: channels,
            mBitsPerChannel: 32,
            mReserved: 0
        )
    }

    static var interleaved: AVAudioFormat {
        var asbd = streamDescription
        return AVAudioFormat(streamDescription: &asbd)!
    }

    /// The same 48 kHz / Float32 / stereo format in the non-interleaved layout used on every
    /// connection inside the graph. Apple's effect units only accept non-interleaved buffers;
    /// passing the interleaved format to `AVAudioEngine.connect` raises an uncatchable
    /// Objective-C exception (kAudioUnitErr_FormatNotSupported, -10868) and kills the process.
    static var graph: AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: channels, interleaved: false)!
    }
}

// MARK: - Tunables

/// Every DSP placeholder in one place. Applied when the chain is built (so a rebuild after a
/// device reconnect comes back identical) and re-applied live when the menu bar sliders move.
struct DSPSettings: Equatable {
    // Node 1: high-pass
    var highPassCutoffHz: Float = 80

    // Node 2: expander / compressor (AUDynamicsProcessor)
    var expansionThresholdDB: Float = -60      // [-120, 0] signal below this is pushed down (noise gate)
    var expansionRatio: Float = 3              // [1, 50] 1 = off, higher = harder gate
    var compressionThresholdDB: Float = -24    // [-100, 20]
    /// AUDynamicsProcessor has no ratio parameter. Its curve bends from 1:1 at the threshold
    /// towards a ceiling of threshold + headroom, so headroom is the ratio control: smaller =
    /// harder. Measured with -24 / 8: ~2:1 from -24 to -12 dBFS, ~12:1 from -12 to 0 dBFS.
    var compressionHeadroomDB: Float = 8       // [0.1, 40]
    var compressorAttackSeconds: Float = 0.005 // [0.001, 0.3]
    var compressorReleaseSeconds: Float = 0.12 // [0.01, 3]
    var makeupGainDB: Float = 8                // [-40, 40]

    // Node 3: tone EQ
    var boxCutFrequencyHz: Float = 350
    var boxCutBandwidthOctaves: Float = 1.5    // wide
    var boxCutGainDB: Float = -3
    var presenceShelfFrequencyHz: Float = 5_000
    var presenceShelfGainDB: Float = 3

    // Node 4: de-esser (AUMultibandCompressor, only band 4 active)
    var deEssLowCrossoverHz: Float = 4_000     // band 4 = everything above this (to Nyquist)
    var deEssThresholdDB: Float = -32          // [-100, 0]
    var deEssHeadroomDB: Float = 1             // [0.1, 40] small = aggressive
    var deEssAttackSeconds: Float = 0.001      // [0.001, 0.2]
    var deEssReleaseSeconds: Float = 0.06      // [0.01, 3]

    // Node 5: limiter
    var limiterCeilingDB: Float = -1.5
    var limiterAttackSeconds: Float = 0.002    // [0.0005, 0.03]
    var limiterDecaySeconds: Float = 0.024     // [0.001, 0.04]
}

// MARK: - Chain

/// Mono capture -> stereo upmix -> HPF -> dynamics -> tone EQ -> de-esser -> limiter -> ceiling trim.
final class DSPChain {
    let upmix = AVAudioMixerNode()
    let highPass = AVAudioUnitEQ(numberOfBands: 1)
    let dynamics = DSPChain.appleEffect(kAudioUnitSubType_DynamicsProcessor)
    let toneEQ = AVAudioUnitEQ(numberOfBands: 2)
    let deEsser = DSPChain.appleEffect(kAudioUnitSubType_MultiBandCompressor)
    let limiter = DSPChain.appleEffect(kAudioUnitSubType_PeakLimiter)
    private(set) var settings: DSPSettings
    private weak var engine: AVAudioEngine?

    /// Upmix first, then the five processing nodes in signal order.
    var nodes: [AVAudioNode] { [upmix, highPass, dynamics, toneEQ, deEsser, limiter] }

    init(settings: DSPSettings) throws {
        self.settings = settings
        try apply(settings)
    }

    /// (Re)configures every node. Safe while the engine is rendering: parameter writes are
    /// picked up by the units on their next render cycle.
    func apply(_ settings: DSPSettings) throws {
        self.settings = settings
        configureHighPass()
        try configureDynamics()
        configureToneEQ()
        try configureDeEsser()
        try configureLimiter()
        engine?.mainMixerNode.outputVolume = ceilingTrim
    }

    /// Wires `engine.inputNode` (delivering `captureFormat`, the mono mic channel) through the
    /// chain into `engine.mainMixerNode`, which acts as the post-limiter ceiling trim.
    func install(in engine: AVAudioEngine, captureFormat: AVAudioFormat) throws {
        self.engine = engine
        let graph = BroadcastFormat.graph
        try catchingObjCException("Building the DSP graph") {
            nodes.forEach(engine.attach)
            for (source, destination) in zip(nodes, nodes.dropFirst()) {
                engine.connect(source, to: destination, format: graph)
            }
            engine.connect(limiter, to: engine.mainMixerNode, format: graph)
        }
        try connectCapture(in: engine, format: captureFormat)

        // AUPeakLimiter has no ceiling parameter: it is transparent below 0 dBFS and holds its
        // output at 0 dBFS. Boosting into it by |ceiling| and trimming by ceiling afterwards
        // gives unity gain below the ceiling and a brick wall exactly at the ceiling.
        engine.mainMixerNode.outputVolume = ceilingTrim
    }

    /// The hardware-facing input connection. Re-made on its own when the device's sample rate
    /// changes underneath a running session.
    func connectCapture(in engine: AVAudioEngine, format: AVAudioFormat) throws {
        try catchingObjCException("Connecting capture at \(Int(format.sampleRate)) Hz") {
            // The "WhatsApp fix": a mono bus entering a stereo mixer bus with centred pan is
            // copied at unity gain to BOTH output channels (no pan-law attenuation; `--self-test`
            // verifies L - R == 0). The mixer also resamples to 48 kHz if the interface does not
            // run at 48 kHz.
            engine.connect(engine.inputNode, to: upmix, format: format)
            engine.inputNode.pan = 0
            engine.inputNode.volume = 1
        }
    }

    private var ceilingTrim: Float { powf(10, settings.limiterCeilingDB / 20) }

    // MARK: Telemetry

    /// Current gain change of the dynamics processor, expander and compressor combined (dB, >= 0).
    var dynamicsGainReductionDB: Float? {
        parameter(dynamics, AudioUnitParameterID(kDynamicsProcessorParam_CompressionAmount)).map { abs($0) }
    }

    /// Current gain reduction of the de-esser band (dB, >= 0).
    var deEsserGainReductionDB: Float? {
        parameter(deEsser, AudioUnitParameterID(kMultibandCompressorParam_CompressionAmount4)).map { abs($0) }
    }

    // MARK: Node configuration

    private func configureHighPass() {
        let band = highPass.bands[0]
        band.filterType = .highPass
        band.frequency = settings.highPassCutoffHz
        band.bypass = false
        highPass.globalGain = 0
    }

    private func configureDynamics() throws {
        try set(dynamics, [
            (kDynamicsProcessorParam_ExpansionThreshold, settings.expansionThresholdDB),
            (kDynamicsProcessorParam_ExpansionRatio, settings.expansionRatio),
            (kDynamicsProcessorParam_Threshold, settings.compressionThresholdDB),
            (kDynamicsProcessorParam_HeadRoom, settings.compressionHeadroomDB),
            (kDynamicsProcessorParam_AttackTime, settings.compressorAttackSeconds),
            (kDynamicsProcessorParam_ReleaseTime, settings.compressorReleaseSeconds),
            (kDynamicsProcessorParam_OverallGain, settings.makeupGainDB),
        ])
    }

    private func configureToneEQ() {
        let boxCut = toneEQ.bands[0]
        boxCut.filterType = .parametric
        boxCut.frequency = settings.boxCutFrequencyHz
        boxCut.bandwidth = settings.boxCutBandwidthOctaves
        boxCut.gain = settings.boxCutGainDB
        boxCut.bypass = false

        let presence = toneEQ.bands[1]
        presence.filterType = .highShelf
        presence.frequency = settings.presenceShelfFrequencyHz
        presence.gain = settings.presenceShelfGainDB
        presence.bypass = false
    }

    private func configureDeEsser() throws {
        // AUMultibandCompressor has no per-band bypass. Bands 1-3 are neutralised instead:
        // 0 dBFS threshold + maximum headroom means they never compress and 0 dB band EQ means
        // unity gain. Band 4 (above the top crossover) is the de-esser and only clamps down
        // when sibilant energy pushes it over its threshold.
        //
        // The crossovers do NOT sum flat: with the stock 200/900/4000 Hz layout the idle unit
        // notches ~6 dB around 1 kHz, and a dedicated 4-7 kHz band (crossovers at 4k/7k)
        // notches ~17 dB at 5 kHz. Parking crossovers 1 and 2 below the audio band leaves a
        // single split at the de-ess frequency, measured flat within 0.05 dB from 100 Hz up.
        // Consequence: band 4 extends from the crossover to Nyquist, not just to 7 kHz.
        var parameters: [(AudioUnitParameterID, Float)] = [
            (kMultibandCompressorParam_Pregain, 0),
            (kMultibandCompressorParam_Postgain, 0),
            (kMultibandCompressorParam_Crossover1, 20),
            (kMultibandCompressorParam_Crossover2, 22),
            (kMultibandCompressorParam_Crossover3, settings.deEssLowCrossoverHz),
            (kMultibandCompressorParam_AttackTime, settings.deEssAttackSeconds),
            (kMultibandCompressorParam_ReleaseTime, settings.deEssReleaseSeconds),
            (kMultibandCompressorParam_Threshold4, settings.deEssThresholdDB),
            (kMultibandCompressorParam_Headroom4, settings.deEssHeadroomDB),
            (kMultibandCompressorParam_EQ4, 0),
        ]
        for (threshold, headroom, eq) in [
            (kMultibandCompressorParam_Threshold1, kMultibandCompressorParam_Headroom1, kMultibandCompressorParam_EQ1),
            (kMultibandCompressorParam_Threshold2, kMultibandCompressorParam_Headroom2, kMultibandCompressorParam_EQ2),
            (kMultibandCompressorParam_Threshold3, kMultibandCompressorParam_Headroom3, kMultibandCompressorParam_EQ3),
        ] {
            parameters += [(threshold, 0), (headroom, 40), (eq, 0)]
        }
        try set(deEsser, parameters)
    }

    private func configureLimiter() throws {
        try set(limiter, [
            (kLimiterParam_AttackTime, settings.limiterAttackSeconds),
            (kLimiterParam_DecayTime, settings.limiterDecaySeconds),
            (kLimiterParam_PreGain, -settings.limiterCeilingDB),
        ])
    }

    // MARK: Helpers

    private static func appleEffect(_ subType: OSType) -> AVAudioUnitEffect {
        AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: subType,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        ))
    }

    private func set<ID: BinaryInteger>(_ unit: AVAudioUnitEffect, _ parameters: [(ID, Float)]) throws {
        let name = unit.auAudioUnit.audioUnitName ?? "AudioUnit"
        for (id, value) in parameters {
            try check(AudioUnitSetParameter(unit.audioUnit, AudioUnitParameterID(id), kAudioUnitScope_Global, 0, value, 0),
                      "\(name): setting parameter \(id) to \(value)")
        }
    }

    private func parameter(_ unit: AVAudioUnitEffect, _ id: AudioUnitParameterID) -> Float? {
        var value: AudioUnitParameterValue = 0
        return AudioUnitGetParameter(unit.audioUnit, id, kAudioUnitScope_Global, 0, &value) == noErr ? value : nil
    }
}
