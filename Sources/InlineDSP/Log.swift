import Foundation

/// Timestamped, line-buffered console logging (stdout for status, stderr for problems), so
/// output stays ordered and flushed when piped into a file or captured by launchd.
enum Log {
    nonisolated(unsafe) private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let lock = NSLock()

    static func configureStreams() {
        setvbuf(stdout, nil, _IOLBF, 0)
        setvbuf(stderr, nil, _IOLBF, 0)
    }

    static func info(_ message: String) { write(stdout, "INFO ", message) }
    static func warn(_ message: String) { write(stderr, "WARN ", message) }
    static func error(_ message: String) { write(stderr, "ERROR", message) }

    private static func write(_ stream: UnsafeMutablePointer<FILE>, _ level: String, _ message: String) {
        lock.lock()
        defer { lock.unlock() }
        fputs("\(formatter.string(from: Date())) [\(level)] \(message)\n", stream)
    }
}

func formatDB(_ value: Float?, precision: Int = 1) -> String {
    guard let value, value.isFinite else { return "-inf" }
    return String(format: "%.\(precision)f", value)
}

func linearToDB(_ value: Float) -> Float {
    value > 0 ? 20 * log10f(value) : -.infinity
}
