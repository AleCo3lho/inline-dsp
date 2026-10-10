import AVFAudio
import Accelerate
import os

/// Collects per-channel sample peaks from a render tap. The tap block runs on an AVAudioEngine
/// worker thread (not the real-time I/O thread), so a short unfair lock is acceptable here.
/// Each reader (status log, menu bar meters, silent-input watchdog) drains its own peak-hold.
final class PeakMeter: Sendable {
    enum Reader: Int, CaseIterable { case log, ui, watchdog }

    private let peaks = OSAllocatedUnfairLock(
        initialState: [[Float]](repeating: [0, 0], count: Reader.allCases.count)
    )

    /// Installed from this nonisolated type on purpose: a tap closure created inside a
    /// @MainActor context would inherit main-actor isolation and trap when invoked off-main.
    func install(on node: AVAudioNode, bus: AVAudioNodeBus = 0) {
        node.installTap(onBus: bus, bufferSize: 4_800, format: nil) { [self] buffer, _ in
            ingest(buffer)
        }
    }

    func ingest(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData else { return }
        let frames = vDSP_Length(buffer.frameLength)
        let count = min(Int(buffer.format.channelCount), 2)
        var local: [Float] = [0, 0]
        for channel in 0..<count {
            vDSP_maxmgv(channels[channel], buffer.stride, &local[channel], frames)
        }
        if count == 1 { local[1] = local[0] }
        let measured = local
        peaks.withLock { state in
            for reader in state.indices {
                for channel in 0..<2 { state[reader][channel] = max(state[reader][channel], measured[channel]) }
            }
        }
    }

    /// Returns the peaks (linear, L/R) `reader` has not seen yet and resets its hold.
    func drain(_ reader: Reader) -> [Float] {
        peaks.withLock { state in
            defer { state[reader.rawValue] = [0, 0] }
            return state[reader.rawValue]
        }
    }
}
