import AVFAudio
import Foundation

/// Renders synthetic signals through the exact production chain (same `DSPChain.install`) in
/// offline manual-rendering mode, so the routing and DSP can be verified without any hardware.
enum SelfTest {
    private static let rate = BroadcastFormat.sampleRate

    static func run(settings: DSPSettings) -> Bool {
        var failures = 0
        func verdict(_ passed: Bool, _ name: String, _ detail: String) {
            if !passed { failures += 1 }
            print("  [\(passed ? "PASS" : "FAIL")] \(name): \(detail)")
        }

        print("Self-test: offline render through the production chain at \(Int(rate)) Hz")
        do {
            // 1. Mono -> stereo upmix must be bit-identical on both sides, at unity gain.
            let upmix = try render(sine(1_000, dBFS: -36, seconds: 1), settings: settings)
            let difference = zip(upmix.left, upmix.right).reduce(Float(0)) { max($0, abs($1.0 - $1.1)) }
            verdict(difference == 0 && upmix.peak(.all) > 0, "Upmix L == R",
                    "max |L - R| = \(difference), output peak \(formatDB(linearToDB(upmix.peak(.all)))) dBFS")

            // 2. Ceiling: hot sines, a hot transient after silence, and broadband noise.
            let ceilingSignals: [(String, [Float])] = [
                ("1 kHz @ +12 dBFS", sine(1_000, dBFS: 12, seconds: 1.5)),
                ("6 kHz @ +6 dBFS", sine(6_000, dBFS: 6, seconds: 1.5)),
                ("transient @ +18 dBFS", [Float](repeating: 0, count: Int(rate / 2)) + sine(3_000, dBFS: 18, seconds: 1)),
                ("noise @ +10 dBFS", noise(dBFS: 10, seconds: 1.5)),
            ]
            for (name, signal) in ceilingSignals {
                let peak = linearToDB(try render(signal, settings: settings).peak(.all))
                verdict(peak <= settings.limiterCeilingDB + 0.01, "Ceiling, \(name)",
                        "peak \(formatDB(peak, precision: 3)) dBFS (limit \(formatDB(settings.limiterCeilingDB)) dBFS)")
            }

            // 3/4. Each node's own contribution: render with the node bypassed vs. active, at a
            //      level where the compressor is linear so dynamics don't skew the comparison.
            func contribution(of node: (DSPChain) -> AVAudioUnitEffect, _ frequency: Double, dBFS: Double) throws -> Float {
                let signal = sine(frequency, dBFS: dBFS, seconds: 1.5)
                let active = try render(signal, settings: settings).rmsDB(.tail)
                let bypassed = try render(signal, settings: settings) { node($0).bypass = true }.rmsDB(.tail)
                return active - bypassed
            }

            let cutoff = Double(settings.highPassCutoffHz)
            let rumble = try contribution(of: { $0.highPass }, 30, dBFS: -36)
            let atCutoff = try contribution(of: { $0.highPass }, cutoff, dBFS: -36)
            let voice = try contribution(of: { $0.highPass }, 1_000, dBFS: -36)
            verdict(rumble <= -12 && abs(atCutoff + 3) <= 1 && abs(voice) <= 0.5, "High-pass",
                    "30 Hz \(formatDB(rumble)) dB, \(Int(cutoff)) Hz \(formatDB(atCutoff)) dB, 1 kHz \(formatDB(voice, precision: 2)) dB")

            let sibilance = try contribution(of: { $0.deEsser }, 6_000, dBFS: -12)
            verdict(sibilance <= -3, "De-esser on 6 kHz", "\(formatDB(sibilance)) dB")
            for frequency in [100.0, 500.0, 1_000.0, 2_500.0] {
                let change = try contribution(of: { $0.deEsser }, frequency, dBFS: -12)
                verdict(abs(change) <= 0.25, "De-esser transparent at \(Int(frequency)) Hz", "\(formatDB(change, precision: 2)) dB")
            }

            // 5. Informational: static level response at 1 kHz, for gain-staging the placeholders.
            print("  Level response at 1 kHz (input -> output peak, dBFS):")
            for level in stride(from: -60.0, through: 0, by: 12) {
                let output = try render(sine(1_000, dBFS: level, seconds: 1.5), settings: settings)
                print("    \(String(format: "%6.1f", level)) -> \(String(format: "%6.1f", output.peakDB(.tail)))   (dyn GR \(formatDB(output.dynamicsGR)) dB)")
            }
        } catch {
            failures += 1
            print("  [FAIL] Render error: \(error)")
        }

        print(failures == 0 ? "Self-test passed." : "Self-test FAILED (\(failures) check(s)).")
        return failures == 0
    }

    // MARK: Rendering

    private struct Rendered {
        enum Region { case all, tail }
        let left: [Float]
        let right: [Float]
        /// Read while the engine is still running; the AU resets its meters on stop.
        let dynamicsGR: Float?

        /// The last 0.5 s, after attack/release and filter transients have settled.
        private func samples(_ region: Region) -> ArraySlice<Float> {
            let both = left + right
            guard region == .tail else { return both[...] }
            let tail = min(Int(rate / 2), left.count)
            return (left.suffix(tail) + right.suffix(tail))[...]
        }

        func peak(_ region: Region) -> Float { samples(region).reduce(0) { max($0, abs($1)) } }
        func peakDB(_ region: Region) -> Float { linearToDB(peak(region)) }
        func rmsDB(_ region: Region) -> Float {
            let slice = samples(region)
            return 10 * log10f(slice.reduce(0) { $0 + $1 * $1 } / Float(max(slice.count, 1)))
        }
    }

    private final class SignalSource: @unchecked Sendable {
        private let samples: [Float]
        private var cursor = 0
        private let scratch: AVAudioPCMBuffer

        init(_ samples: [Float], format: AVAudioFormat, capacity: AVAudioFrameCount) {
            self.samples = samples
            scratch = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity)!
        }

        func pull(_ frames: AVAudioFrameCount) -> UnsafePointer<AudioBufferList> {
            let destination = scratch.floatChannelData![0]
            for i in 0..<Int(frames) {
                destination[i] = cursor < samples.count ? samples[cursor] : 0
                cursor += 1
            }
            scratch.frameLength = frames
            return UnsafePointer(scratch.audioBufferList)
        }
    }

    private static func render(_ signal: [Float], settings: DSPSettings,
                               configure: (DSPChain) -> Void = { _ in }) throws -> Rendered {
        let maxFrames: AVAudioFrameCount = 1_024
        let engine = AVAudioEngine()
        try engine.enableManualRenderingMode(.offline, format: BroadcastFormat.graph, maximumFrameCount: maxFrames)

        let mono = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let source = SignalSource(signal, format: mono, capacity: maxFrames)
        guard engine.inputNode.setManualRenderingInputPCMFormat(mono, inputBlock: { source.pull($0) }) else {
            throw EngineError("Could not attach offline input")
        }

        let chain = try DSPChain(settings: settings)
        configure(chain)
        try chain.install(in: engine, captureFormat: mono)
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: BroadcastFormat.graph)
        try engine.start()
        defer { engine.stop() }

        let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: maxFrames)!
        var left: [Float] = [], right: [Float] = []
        left.reserveCapacity(signal.count)
        right.reserveCapacity(signal.count)
        while left.count < signal.count {
            let frames = min(maxFrames, AVAudioFrameCount(signal.count - left.count))
            guard try engine.renderOffline(frames, to: buffer) == .success else {
                throw EngineError("Offline render did not succeed")
            }
            let count = Int(buffer.frameLength)
            left += UnsafeBufferPointer(start: buffer.floatChannelData![0], count: count)
            right += UnsafeBufferPointer(start: buffer.floatChannelData![1], count: count)
        }
        return Rendered(left: left, right: right, dynamicsGR: chain.dynamicsGainReductionDB)
    }

    // MARK: Signals

    private static func sine(_ frequency: Double, dBFS: Double, seconds: Double) -> [Float] {
        let amplitude = pow(10, dBFS / 20)
        return (0..<Int(seconds * rate)).map { Float(amplitude * sin(2 * .pi * frequency * Double($0) / rate)) }
    }

    /// Deterministic white noise (LCG) with the given peak level.
    private static func noise(dBFS: Double, seconds: Double) -> [Float] {
        let amplitude = Float(pow(10, dBFS / 20))
        var state: UInt32 = 0x1234_5678
        return (0..<Int(seconds * rate)).map { _ in
            state = state &* 1_664_525 &+ 1_013_904_223
            return amplitude * (Float(state) / Float(UInt32.max) * 2 - 1)
        }
    }
}
