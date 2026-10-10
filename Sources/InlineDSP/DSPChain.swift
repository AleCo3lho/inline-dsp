import AVFAudio
import AudioToolbox
import ObjCExceptionCatcher
import VoiceKernel

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
    /// connection inside the graph. Audio units only accept non-interleaved buffers; passing
    /// the interleaved format to `AVAudioEngine.connect` raises an Objective-C exception
    /// (kAudioUnitErr_FormatNotSupported, -10868).
    static var graph: AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: channels, interleaved: false)!
    }
}

// MARK: - Tunables

/// Every DSP setting in one place, mapped one-to-one onto the voice kernel's parameters
/// (Sources/VoiceKernel). Applied when the chain is built and re-applied live when the menu bar
/// sliders move.
struct DSPSettings: Equatable {
    // High-pass: 12 dB/oct Butterworth.
    var highPassEnabled = true
    var highPassCutoffHz: Float = 80

    // Gate: attenuates by `gateRangeDB` (never mutes) when the input stays below the threshold.
    var gateEnabled = true
    var gateThresholdDB: Float = -60           // opens above this input level
    var gateRangeDB: Float = -15
    var gateHysteresisDB: Float = 6             // closes 6 dB below the threshold
    var gateHoldSeconds: Float = 0.15
    var gateAttackSeconds: Float = 0.001
    var gateReleaseSeconds: Float = 0.1

    // Compressor: feed-forward, soft knee, no lookahead.
    var compressorEnabled = true
    var compressorThresholdDB: Float = -24
    var compressorRatio: Float = 3
    var compressorKneeDB: Float = 6
    var compressorAttackSeconds: Float = 0.005
    var compressorReleaseSeconds: Float = 0.12
    var makeupGainDB: Float = 8

    // Tone EQ
    var toneEnabled = true
    var boxCutFrequencyHz: Float = 350
    var boxCutGainDB: Float = -3
    var boxCutQ: Float = 0.92                   // ~1.5 octaves wide
    var presenceShelfFrequencyHz: Float = 5_000
    var presenceShelfGainDB: Float = 3

    // De-esser: dynamic cut of a band around `deEssFrequencyHz`, triggered only when that band
    // is above `deEssThresholdDB` *and* within `deEssRelativeThresholdDB` of the full band.
    var deEsserEnabled = true
    var deEssFrequencyHz: Float = 6_500
    var deEssQ: Float = 1.4
    var deEssThresholdDB: Float = -30
    var deEssRelativeThresholdDB: Float = -9
    var deEssRatio: Float = 5
    var deEssMaxReductionDB: Float = 12
    var deEssAttackSeconds: Float = 0.0005
    var deEssReleaseSeconds: Float = 0.06

    // Limiter: 1 ms lookahead, guaranteed sample-peak ceiling.
    var limiterEnabled = true
    var limiterCeilingDB: Float = -1.5
    var limiterReleaseSeconds: Float = 0.05

    /// Every stage off; the limiter's 1 ms delay remains so latency never changes.
    var bypass = false

    fileprivate var parameters: [(IDSPParam, Float)] {
        func flag(_ on: Bool) -> Float { on ? 1 : 0 }
        return [
            (.bypass, flag(bypass)),
            (.highPassEnabled, flag(highPassEnabled)), (.highPassFrequency, highPassCutoffHz),
            (.gateEnabled, flag(gateEnabled)), (.gateThreshold, gateThresholdDB), (.gateRange, gateRangeDB),
            (.gateHysteresis, gateHysteresisDB), (.gateHold, gateHoldSeconds), (.gateAttack, gateAttackSeconds),
            (.gateRelease, gateReleaseSeconds),
            (.compressorEnabled, flag(compressorEnabled)), (.compressorThreshold, compressorThresholdDB),
            (.compressorRatio, compressorRatio), (.compressorKnee, compressorKneeDB),
            (.compressorAttack, compressorAttackSeconds), (.compressorRelease, compressorReleaseSeconds),
            (.compressorMakeup, makeupGainDB),
            (.toneEnabled, flag(toneEnabled)), (.toneCutFrequency, boxCutFrequencyHz), (.toneCutGain, boxCutGainDB),
            (.toneCutQ, boxCutQ), (.toneShelfFrequency, presenceShelfFrequencyHz), (.toneShelfGain, presenceShelfGainDB),
            (.deEsserEnabled, flag(deEsserEnabled)), (.deEsserFrequency, deEssFrequencyHz), (.deEsserQ, deEssQ),
            (.deEsserThreshold, deEssThresholdDB), (.deEsserRelativeThreshold, deEssRelativeThresholdDB),
            (.deEsserRatio, deEssRatio), (.deEsserMaxReduction, deEssMaxReductionDB),
            (.deEsserAttack, deEssAttackSeconds), (.deEsserRelease, deEssReleaseSeconds),
            (.limiterEnabled, flag(limiterEnabled)), (.limiterCeiling, limiterCeilingDB),
            (.limiterRelease, limiterReleaseSeconds),
        ]
    }
}

// MARK: - Chain

/// Mono capture -> voice processor (HPF, gate, compressor, tone EQ, de-esser, limiter; mono in,
/// stereo out) -> mixer (48 kHz). Processing happens once, in mono, so L and R are identical by
/// construction.
final class DSPChain {
    let processorNode: AVAudioUnitEffect
    let upmix = AVAudioMixerNode()
    private let processor: VoiceProcessorAU
    private(set) var settings: DSPSettings

    var nodes: [AVAudioNode] { [processorNode, upmix] }

    init(settings: DSPSettings) throws {
        VoiceProcessorAU.registerSubclassOnce()
        processorNode = AVAudioUnitEffect(audioComponentDescription: VoiceProcessorAU.componentDescription)
        guard let processor = processorNode.auAudioUnit as? VoiceProcessorAU else {
            throw EngineError("The voice processor audio unit could not be instantiated")
        }
        self.processor = processor
        self.settings = settings
        apply(settings)
    }

    /// Writes every parameter. Safe while rendering: the kernel picks changes up at the start
    /// of its next render block.
    func apply(_ settings: DSPSettings) {
        self.settings = settings
        for (parameter, value) in settings.parameters {
            processor.setValue(value, forParameter: parameter)
        }
    }

    /// Wires `engine.inputNode` (delivering `captureFormat`, the mono mic channel) through the
    /// processor and the upmix into `engine.mainMixerNode`.
    func install(in engine: AVAudioEngine, captureFormat: AVAudioFormat) throws {
        try catchingObjCException("Building the DSP graph") {
            nodes.forEach(engine.attach)
            engine.connect(upmix, to: engine.mainMixerNode, format: BroadcastFormat.graph)
            engine.mainMixerNode.outputVolume = 1
        }
        try connectCapture(in: engine, format: captureFormat)
    }

    /// The capture-rate part of the graph, re-made on its own if the device's rate changes.
    func connectCapture(in engine: AVAudioEngine, format: AVAudioFormat) throws {
        try catchingObjCException("Connecting capture at \(Int(format.sampleRate)) Hz") {
            // The "WhatsApp fix": the processor takes the mono mic and writes the processed signal
            // to BOTH output channels, bit-identical (`--self-test` verifies L - R == 0). Doing the
            // upmix in the processor rather than the mixer avoids AVAudioMixerNode's equal-power
            // pan law, which was measured to attenuate a mono bus from an audio unit by 3 dB.
            // The mixer then only passes stereo through and resamples to 48 kHz if needed.
            let stereo = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: BroadcastFormat.channels)!
            engine.connect(engine.inputNode, to: processorNode, format: format)
            engine.connect(processorNode, to: upmix, format: stereo)
            upmix.volume = 1
        }
    }

    // MARK: Telemetry (dB, per render block)

    /// Gate attenuation (<= 0).
    var gateGainDB: Float { processor.meter(.gate) }
    /// Compressor gain reduction (>= 0).
    var compressorReductionDB: Float { processor.meter(.compressor) }
    /// De-esser gain reduction (>= 0).
    var deEsserReductionDB: Float { processor.meter(.deEsser) }
    /// Limiter gain (<= 0).
    var limiterGainDB: Float { processor.meter(.limiter) }
    /// Peak level the gate listens to (after the high-pass) since the previous call, in dBFS.
    func takeDetectorPeakDB() -> Float { linearToDB(processor.takeDetectorPeak()) }
}
