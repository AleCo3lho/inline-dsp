import AudioToolbox
import CoreAudio
import Foundation

// MARK: - Errors

struct CoreAudioError: Error, CustomStringConvertible {
    let status: OSStatus
    let operation: String

    var description: String { "\(operation) failed: \(fourCC(status)) (\(status))" }
}

/// Throws when a Core Audio / AudioToolbox call does not return noErr.
func check(_ status: OSStatus, _ operation: @autoclosure () -> String) throws {
    guard status == noErr else { throw CoreAudioError(status: status, operation: operation()) }
}

/// Renders an OSStatus as its four-character code when it is printable (e.g. '!dev', 'nope').
func fourCC(_ status: OSStatus) -> String {
    let bytes = withUnsafeBytes(of: UInt32(bitPattern: status).bigEndian, Array.init)
    guard bytes.allSatisfy({ (0x20...0x7E).contains($0) }) else { return String(status) }
    return "'" + String(decoding: bytes, as: UTF8.self) + "'"
}

// MARK: - Device model

enum Direction: CustomStringConvertible {
    case input, output

    var scope: AudioObjectPropertyScope {
        self == .input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput
    }

    var description: String { self == .input ? "input" : "output" }
}

struct AudioDevice: CustomStringConvertible {
    let id: AudioObjectID
    let name: String
    let uid: String
    let inputChannels: Int
    let outputChannels: Int
    let nominalSampleRate: Double

    func channels(_ direction: Direction) -> Int {
        direction == .input ? inputChannels : outputChannels
    }

    var description: String {
        "\"\(name)\" [id \(id), uid \(uid), in \(inputChannels)ch, out \(outputChannels)ch, \(Int(nominalSampleRate)) Hz]"
    }
}

enum DeviceLookupError: Error, CustomStringConvertible {
    case notFound(query: String, direction: Direction, available: [String])

    var description: String {
        switch self {
        case let .notFound(query, direction, available):
            let list = available.isEmpty ? "none" : available.map { "\"\($0)\"" }.joined(separator: ", ")
            return "No \(direction) device matching \"\(query)\" (available \(direction) devices: \(list))"
        }
    }
}

// MARK: - Mic channel profiles

/// Where the physical XLR mic input lives on known interfaces. Drivers only publish generic
/// channel names, and the position differs between generations, so it cannot be inferred.
enum MicInputProfile {
    private static let profiles: [(devicePrefix: String, channelName: String)] = [
        // 4th Gen: Input 1 = front 1/4" line/instrument jack, Input 2 = rear XLR mic input.
        ("Scarlett Solo 4th Gen", "Input 2"),
        // 3rd Gen and earlier: Input 1 = XLR mic input, Input 2 = instrument jack.
        ("Scarlett Solo", "Input 1"),
    ]

    static func micChannelName(for device: AudioDevice) -> String? {
        profiles.first { device.name.lowercased().hasPrefix($0.devicePrefix.lowercased()) }?.channelName
    }
}

/// How the capture channel is chosen. Resolved against the device's published channel names
/// every time a session is built, so the selection survives re-enumeration.
enum InputChannelSelection: Equatable, Codable {
    /// The XLR mic input from `MicInputProfile`; channel 0 if the device is unknown.
    case microphone
    case named(String)
    case index(Int)

    struct Resolved {
        let index: Int
        let name: String
        let reason: String
    }

    func resolve(on device: AudioDevice) throws -> Resolved {
        let names = AudioSystem.channelNames(device.id, .input)
        func find(_ name: String) -> Int? {
            names.firstIndex { $0.caseInsensitiveCompare(name) == .orderedSame }
        }
        switch self {
        case .microphone:
            if let name = MicInputProfile.micChannelName(for: device), let index = find(name) {
                return Resolved(index: index, name: name, reason: "XLR mic input per device profile")
            }
            Log.warn("No mic-input profile for \"\(device.name)\"; using its first channel. Pick the mic channel explicitly if this is wrong.")
            guard !names.isEmpty else { throw EngineError("\(device.name) has no input channels") }
            return Resolved(index: 0, name: names[0], reason: "first channel (unknown device)")
        case let .named(name):
            guard let index = find(name) else {
                throw EngineError("\(device.name) has no input channel named \"\(name)\" (channels: \(names.joined(separator: ", ")))")
            }
            return Resolved(index: index, name: names[index], reason: "selected by name")
        case let .index(index):
            guard names.indices.contains(index) else {
                throw EngineError("Input channel \(index) does not exist on \(device.name) (\(names.count) channels)")
            }
            return Resolved(index: index, name: names[index], reason: "selected by index")
        }
    }
}

// MARK: - HAL queries

enum AudioSystem {
    static func allDevices() throws -> [AudioDevice] {
        let ids: [AudioObjectID] = try readArray(AudioObjectID(kAudioObjectSystemObject),
                                                 address(kAudioHardwarePropertyDevices))
        // Private aggregates (inline-dsp's own, and the ones Core Audio creates per process,
        // e.g. "CADefaultDeviceAggregate-<pid>-0") are visible to this process but are not
        // devices anyone should pick.
        return ids.filter { !isPrivateAggregate($0) }.compactMap { try? device(for: $0) }
    }

    static func isPrivateAggregate(_ id: AudioObjectID) -> Bool {
        guard (try? read(id, address(kAudioDevicePropertyTransportType), as: UInt32.self)) == kAudioDeviceTransportTypeAggregate else {
            return false
        }
        var addr = address(kAudioAggregateDevicePropertyComposition)
        var size = UInt32(MemoryLayout<Unmanaged<CFDictionary>?>.size)
        var value: Unmanaged<CFDictionary>?
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr,
              let composition = value?.takeRetainedValue() as? [String: Any] else { return false }
        return (composition[kAudioAggregateDeviceIsPrivateKey] as? Int ?? 0) != 0
    }

    static func device(for id: AudioObjectID) throws -> AudioDevice {
        AudioDevice(
            id: id,
            name: try readString(id, address(kAudioObjectPropertyName)),
            uid: try readString(id, address(kAudioDevicePropertyDeviceUID)),
            inputChannels: channelCount(id, .input),
            outputChannels: channelCount(id, .output),
            nominalSampleRate: (try? read(id, address(kAudioDevicePropertyNominalSampleRate), as: Float64.self)) ?? 0
        )
    }

    /// Resolves a device by UID or by name, considering only devices that actually have
    /// channels in `direction`. Names are compared ignoring case, spaces and punctuation, so
    /// "VBCable", "vb cable" and "VB-Cable" all match the VB-Audio driver's "VB-Cable".
    /// Preference: UID > exact name > prefix > substring. Within a tier, the shortest name wins
    /// so "Scarlett Solo" binds to "Scarlett Solo 4th Gen" rather than a wrapper such as
    /// "Scarlett Solo 4th Gen (eqMac)".
    static func findDevice(matching query: String, direction: Direction) throws -> AudioDevice {
        let candidates = try allDevices().filter { $0.channels(direction) > 0 }
        let needle = normalized(query)
        let tiers: [(AudioDevice) -> Bool] = [
            { $0.uid == query },
            { normalized($0.name) == needle },
            { normalized($0.name).hasPrefix(needle) },
            { normalized($0.name).contains(needle) },
        ]
        for matches in tiers {
            let hits = candidates.filter(matches).sorted { $0.name.count < $1.name.count }
            guard let best = hits.first else { continue }
            if hits.count > 1 {
                Log.warn("\"\(query)\" matches \(hits.count) \(direction) devices (\(hits.map(\.name).joined(separator: ", "))); using \"\(best.name)\". Pass the full name or UID to disambiguate.")
            }
            return best
        }
        throw DeviceLookupError.notFound(query: query, direction: direction, available: candidates.map(\.name))
    }

    private static func normalized(_ name: String) -> String {
        String(name.lowercased().unicodeScalars.filter(CharacterSet.alphanumerics.contains).map(Character.init))
    }

    /// The device macOS currently uses as its default input or output.
    static func defaultDevice(_ direction: Direction) throws -> AudioDevice {
        let selector = direction == .input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice
        let id = try read(AudioObjectID(kAudioObjectSystemObject), address(selector), as: AudioObjectID.self)
        guard id != kAudioObjectUnknown else { throw EngineError("macOS has no default \(direction) device") }
        return try device(for: id)
    }

    static func isAlive(_ id: AudioObjectID) -> Bool {
        ((try? read(id, address(kAudioDevicePropertyDeviceIsAlive), as: UInt32.self)) ?? 0) != 0
    }

    static func deviceExists(_ id: AudioObjectID) -> Bool {
        let ids: [AudioObjectID] = (try? readArray(AudioObjectID(kAudioObjectSystemObject),
                                                   address(kAudioHardwarePropertyDevices))) ?? []
        return ids.contains(id) && isAlive(id)
    }

    static func channelCount(_ id: AudioObjectID, _ direction: Direction) -> Int {
        var addr = address(kAudioDevicePropertyStreamConfiguration, scope: direction.scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        let abl = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, abl) == noErr else { return 0 }
        return UnsafeMutableAudioBufferListPointer(abl).reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    /// Per-channel names as published by the driver (kAudioObjectPropertyElementName; channel
    /// elements are 1-based). Unnamed channels fall back to "Channel N".
    static func channelNames(_ id: AudioObjectID, _ direction: Direction) -> [String] {
        (0..<channelCount(id, direction)).map { index in
            let name = try? readString(id, address(kAudioObjectPropertyElementName, scope: direction.scope,
                                                   element: AudioObjectPropertyElement(index + 1)))
            return name.flatMap { $0.isEmpty ? nil : $0 } ?? "Channel \(index + 1)"
        }
    }

    /// Sets the device's nominal sample rate and waits (bounded) for the HAL to apply it,
    /// since the change is asynchronous and AVAudioEngine reads the hardware format right after.
    static func ensureNominalSampleRate(_ id: AudioObjectID, _ rate: Float64, timeout: TimeInterval = 2) throws {
        var addr = address(kAudioDevicePropertyNominalSampleRate)
        if (try? read(id, addr, as: Float64.self)) == rate { return }
        var value = rate
        try check(AudioObjectSetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<Float64>.size), &value),
                  "Setting nominal sample rate to \(rate) Hz")
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if (try? read(id, addr, as: Float64.self)) == rate { return }
            usleep(10_000)
        }
        throw CoreAudioError(status: kAudioHardwareUnspecifiedError, operation: "Waiting for \(rate) Hz to take effect")
    }

    /// Requests `format` as the physical format of every stream of `id` in `direction`.
    /// Returns the format each stream ended up with.
    @discardableResult
    static func applyPhysicalFormat(_ format: AudioStreamBasicDescription, to id: AudioObjectID,
                                    direction: Direction) throws -> [AudioStreamBasicDescription] {
        let streams: [AudioStreamID] = try readArray(id, address(kAudioDevicePropertyStreams, scope: direction.scope))
        return try streams.map { stream in
            var addr = address(kAudioStreamPropertyPhysicalFormat)
            let current = try read(stream, addr, as: AudioStreamBasicDescription.self)
            if current == format { return current }
            var settable: DarwinBoolean = false
            try check(AudioObjectIsPropertySettable(stream, &addr, &settable), "Querying stream \(stream) format settability")
            guard settable.boolValue else {
                throw CoreAudioError(status: kAudioHardwareIllegalOperationError, operation: "Stream \(stream) physical format is read-only;")
            }
            var desired = format
            try check(AudioObjectSetPropertyData(stream, &addr, 0, nil, UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &desired),
                      "Setting stream \(stream) physical format")
            return try read(stream, addr, as: AudioStreamBasicDescription.self)
        }
    }

    // MARK: Aggregate device

    /// Creates a private (process-local, invisible to other apps, destroyed by the HAL if this
    /// process dies) aggregate of two devices on independent clocks. `clock` drives the
    /// aggregate; `drifting` is resampled by the HAL to follow it. Channels are laid out in
    /// sub-device order: `subDevices[0]` first, then `subDevices[1]`.
    static func createPrivateAggregate(name: String, clock: AudioDevice, drifting: AudioDevice,
                                       subDevices: [AudioDevice]) throws -> AudioObjectID {
        let subDeviceList: [[String: Any]] = subDevices.map { device in
            device.id == drifting.id
                ? [kAudioSubDeviceUIDKey: device.uid,
                   kAudioSubDeviceDriftCompensationKey: 1,
                   kAudioSubDeviceDriftCompensationQualityKey: kAudioAggregateDriftCompensationMaxQuality]
                : [kAudioSubDeviceUIDKey: device.uid,
                   kAudioSubDeviceDriftCompensationKey: 0]
        }
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: name,
            kAudioAggregateDeviceUIDKey: "inline-dsp.aggregate.\(getpid()).\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceIsStackedKey: 0,
            kAudioAggregateDeviceMainSubDeviceKey: clock.uid,
            kAudioAggregateDeviceClockDeviceKey: clock.uid,
            kAudioAggregateDeviceSubDeviceListKey: subDeviceList,
        ]
        var id = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateAggregateDevice(description as CFDictionary, &id), "Creating aggregate device")
        return id
    }

    static func destroyAggregate(_ id: AudioObjectID) {
        let status = AudioHardwareDestroyAggregateDevice(id)
        if status != noErr { Log.warn("Destroying aggregate device \(id) failed: \(fourCC(status))") }
    }

    // MARK: Generic property access

    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func read<T>(_ id: AudioObjectID, _ address: AudioObjectPropertyAddress, as: T.Type) throws -> T {
        var addr = address
        var size = UInt32(MemoryLayout<T>.size)
        let value = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { value.deallocate() }
        try check(AudioObjectGetPropertyData(id, &addr, 0, nil, &size, value), "Reading property \(fourCC(OSStatus(bitPattern: address.mSelector))) of object \(id)")
        return value.move()
    }

    static func readArray<T>(_ id: AudioObjectID, _ address: AudioObjectPropertyAddress) throws -> [T] {
        var addr = address
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size), "Sizing property of object \(id)")
        let count = Int(size) / MemoryLayout<T>.stride
        guard count > 0 else { return [] }
        return try [T](unsafeUninitializedCapacity: count) { buffer, initialized in
            try check(AudioObjectGetPropertyData(id, &addr, 0, nil, &size, buffer.baseAddress!), "Reading property of object \(id)")
            initialized = Int(size) / MemoryLayout<T>.stride
        }
    }

    static func readString(_ id: AudioObjectID, _ address: AudioObjectPropertyAddress) throws -> String {
        var addr = address
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?
        try check(AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value), "Reading string property of object \(id)")
        return value?.takeRetainedValue() as String? ?? ""
    }
}

extension AudioStreamBasicDescription: @retroactive Equatable {
    public static func == (a: Self, b: Self) -> Bool {
        a.mSampleRate == b.mSampleRate && a.mFormatID == b.mFormatID && a.mFormatFlags == b.mFormatFlags
            && a.mBytesPerPacket == b.mBytesPerPacket && a.mFramesPerPacket == b.mFramesPerPacket
            && a.mBytesPerFrame == b.mBytesPerFrame && a.mChannelsPerFrame == b.mChannelsPerFrame
            && a.mBitsPerChannel == b.mBitsPerChannel
    }
}

// MARK: - Property listeners

/// RAII wrapper around AudioObjectAddPropertyListenerBlock. The HAL requires the *same* block
/// instance for removal, so the block is retained here and removed on `invalidate()`/deinit.
final class PropertyListener {
    private let objectID: AudioObjectID
    private var address: AudioObjectPropertyAddress
    private let queue: DispatchQueue
    private let block: AudioObjectPropertyListenerBlock
    private var active = false

    init(objectID: AudioObjectID, selector: AudioObjectPropertySelector,
         scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
         queue: DispatchQueue = .main, handler: @escaping @Sendable () -> Void) throws {
        self.objectID = objectID
        self.address = AudioSystem.address(selector, scope: scope)
        self.queue = queue
        self.block = { _, _ in handler() }
        try check(AudioObjectAddPropertyListenerBlock(objectID, &address, queue, block),
                  "Adding listener \(fourCC(OSStatus(bitPattern: selector))) on object \(objectID)")
        active = true
    }

    func invalidate() {
        guard active else { return }
        active = false
        // Fails harmlessly with '!obj' when the device has already vanished.
        _ = AudioObjectRemovePropertyListenerBlock(objectID, &address, queue, block)
    }

    deinit { invalidate() }
}
