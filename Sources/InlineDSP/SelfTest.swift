import AVFAudio
import Foundation

/// Renders synthetic signals through the exact production chain (same `DSPChain.install`) in
/// offline manual-rendering mode, so the routing and DSP can be verified without any hardware.
/// Stages are isolated by toggling them in `DSPSettings`, so each check measures one stage.
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
            // 1. Mono -> stereo upmix must be bit-identical on both sides.
            let upmix = try render(sine(1_000, dBFS: -36, seconds: 1), settings: settings)
            let difference = zip(upmix.left, upmix.right).reduce(Float(0)) { max($0, abs($1.0 - $1.1)) }
            verdict(difference == 0 && upmix.peak(.all) > 0, "Upmix L == R",
                    "max |L - R| = \(difference), output peak \(formatDB(linearToDB(upmix.peak(.all)))) dBFS")

            // 2. Latency and transparency: with every stage bypassed the output must be the input,
            //    sample for sample, delayed by exactly the latency the audio unit reports.
            var bypassed = settings
            bypassed.bypass = true
            let probe = noise(dBFS: -20, seconds: 0.5)
            let through = try render(probe, settings: bypassed)
            let delay = through.reportedLatencySamples
            var error: Float = 0
            for index in 0..<(probe.count - delay) {
                error = max(error, abs(through.left[index + delay] - probe[index]))
            }
            verdict(error == 0 && delay > 0, "Bypass is bit-exact",
                    "output == input delayed \(delay) samples, max error \(error)")
            let impulse = [Float](repeating: 0, count: 1_000) + [0.5] + [Float](repeating: 0, count: 2_000)
            let response = try render(impulse, settings: bypassed)
            let measured = response.left.indices.max { abs(response.left[$0]) < abs(response.left[$1]) }! - 1_000
            let latencyMs = Double(measured) / rate * 1_000
            verdict(measured == delay && latencyMs <= 1.1, "Processing latency",
                    String(format: "%d samples = %.2f ms (reported %d)", measured, latencyMs, delay))

            // 3. Ceiling: hot sines, a hot transient after silence, broadband noise. The limiter's
            //    lookahead makes this a guarantee, so the tolerance is float rounding only.
            let ceilingSignals: [(String, [Float])] = [
                ("1 kHz @ +12 dBFS", sine(1_000, dBFS: 12, seconds: 1.5)),
                ("6 kHz @ +6 dBFS", sine(6_000, dBFS: 6, seconds: 1.5)),
                ("transient @ +18 dBFS", [Float](repeating: 0, count: Int(rate / 2)) + sine(3_000, dBFS: 18, seconds: 1)),
                ("noise @ +10 dBFS", noise(dBFS: 10, seconds: 1.5)),
            ]
            for (name, signal) in ceilingSignals {
                let peak = linearToDB(try render(signal, settings: settings).peak(.all))
                verdict(peak <= settings.limiterCeilingDB + 0.001, "Ceiling, \(name)",
                        "peak \(formatDB(peak, precision: 3)) dBFS (limit \(formatDB(settings.limiterCeilingDB)) dBFS)")
            }

            /// Level change a stage causes: the chain with the stage on vs off.
            func contribution(_ stage: WritableKeyPath<DSPSettings, Bool>, base: DSPSettings = settings,
                              _ frequency: Double, dBFS: Double) throws -> Float {
                let signal = sine(frequency, dBFS: dBFS, seconds: 1.5)
                var off = base
                off[keyPath: stage] = false
                return try render(signal, settings: base).rmsDB(.tail) - render(signal, settings: off).rmsDB(.tail)
            }

            // 4. High-pass: 12 dB/oct Butterworth at the cutoff.
            let cutoff = Double(settings.highPassCutoffHz)
            let rumble = try contribution(\.highPassEnabled, 30, dBFS: -36)
            let atCutoff = try contribution(\.highPassEnabled, cutoff, dBFS: -36)
            let voice = try contribution(\.highPassEnabled, 1_000, dBFS: -36)
            verdict(rumble <= -12 && abs(atCutoff + 3) <= 0.5 && abs(voice) <= 0.1, "High-pass",
                    "30 Hz \(formatDB(rumble)) dB, \(Int(cutoff)) Hz \(formatDB(atCutoff)) dB, 1 kHz \(formatDB(voice, precision: 2)) dB")

            // 5. Gate alone: closes to its range below threshold - hysteresis, untouched above.
            var gateOnly = settings
            (gateOnly.compressorEnabled, gateOnly.toneEnabled, gateOnly.deEsserEnabled, gateOnly.limiterEnabled) = (false, false, false, false)
            let closed = try contribution(\.gateEnabled, base: gateOnly, 1_000, dBFS: Double(settings.gateThresholdDB - settings.gateHysteresisDB - 14))
            let open = try contribution(\.gateEnabled, base: gateOnly, 1_000, dBFS: Double(settings.gateThresholdDB + 20))
            verdict(abs(closed - settings.gateRangeDB) <= 0.5 && abs(open) <= 0.05, "Gate",
                    "closed \(formatDB(closed)) dB (range \(formatDB(settings.gateRangeDB))), open \(formatDB(open, precision: 2)) dB")

            // 6. Compressor alone (no makeup): unity below the knee, the set ratio above it.
            var compOnly = gateOnly
            (compOnly.gateEnabled, compOnly.compressorEnabled, compOnly.makeupGainDB) = (false, true, 0)
            func outputPeak(_ dBFS: Double) throws -> Float {
                try render(sine(1_000, dBFS: dBFS, seconds: 1.5), settings: compOnly).peakDB(.tail)
            }
            let quiet = try outputPeak(Double(settings.compressorThresholdDB - 15)) - (settings.compressorThresholdDB - 15)
            let ratio = 12 / (try outputPeak(0) - outputPeak(-12))
            verdict(abs(quiet) <= 0.1 && abs(ratio - settings.compressorRatio) <= 0.25, "Compressor",
                    String(format: "below threshold %+.2f dB, measured ratio %.2f:1 (set %.1f:1)", quiet, ratio, settings.compressorRatio))

            // 7. De-esser: cuts the sibilance band, leaves everything else exactly alone.
            let sibilance = try contribution(\.deEsserEnabled, 6_000, dBFS: -12)
            verdict(sibilance <= -3, "De-esser on 6 kHz", "\(formatDB(sibilance)) dB")
            for frequency in [100.0, 500.0, 1_000.0, 2_500.0] {
                let change = try contribution(\.deEsserEnabled, frequency, dBFS: -12)
                verdict(abs(change) <= 0.05, "De-esser transparent at \(Int(frequency)) Hz", "\(formatDB(change, precision: 2)) dB")
            }

            // 8. Informational: static level response of the full chain at 1 kHz.
            print("  Level response at 1 kHz (input -> output peak, dBFS):")
            for level in stride(from: -72.0, through: 0, by: 12) {
                let output = try render(sine(1_000, dBFS: level, seconds: 1.5), settings: settings)
                print(String(format: "    %6.1f -> %6.1f   (gate %@ dB, comp %@ dB, limiter %@ dB)", level, output.peakDB(.tail),
                             formatDB(output.gateDB), formatDB(output.compressorDB), formatDB(output.limiterDB)))
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
        let reportedLatencySamples: Int
        // Read while the engine is still running (last render block).
        let gateDB: Float
        let compressorDB: Float
        let limiterDB: Float

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

    private static func render(_ signal: [Float], settings: DSPSettings) throws -> Rendered {
        let maxFrames: AVAudioFrameCount = 1_024
        let engine = AVAudioEngine()
        try engine.enableManualRenderingMode(.offline, format: BroadcastFormat.graph, maximumFrameCount: maxFrames)

        let mono = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let source = SignalSource(signal, format: mono, capacity: maxFrames)
        guard engine.inputNode.setManualRenderingInputPCMFormat(mono, inputBlock: { source.pull($0) }) else {
            throw EngineError("Could not attach offline input")
        }

        let chain = try DSPChain(settings: settings)
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
        return Rendered(left: left, right: right,
                        reportedLatencySamples: Int((chain.processorNode.latency * rate).rounded()),
                        gateDB: chain.gateGainDB, compressorDB: chain.compressorReductionDB,
                        limiterDB: chain.limiterGainDB)
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
