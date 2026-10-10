import AVFAudio
import Foundation

@main
enum Entry {
    static let usage = """
        inline-dsp — broadcast vocal chain (mono mic -> true stereo virtual output)

        USAGE: inline-dsp [options]

        Runs as a menu bar app by default.

          --headless                 Run without the menu bar UI (terminal / launchd)
          --input NAME               Input device name or UID (default: the macOS default input)
          --output NAME              Output device name or UID (default: "VB-Cable")
          --input-channel-name NAME  Capture the input channel with this name (e.g. "Input 2")
          --input-channel N          Capture input channel N, 0-based
                                     (default: the XLR mic input of known interfaces)
          --buffer FRAMES            I/O buffer size in frames (default: 128)
          --status-interval SEC      Seconds between status log lines, 0 disables (default: 30)
          --list-devices             List audio devices and their input channels, then exit
          --self-test                Verify the DSP chain offline (no hardware) and exit
          --version                  Print the version and exit
          -h, --help                 Show this help
        """

    @MainActor
    static func main() {
        Log.configureStreams()

        // Devices, channel and slider values picked in the menu bar persist and apply to both modes;
        // command-line flags override them for this run.
        var options = BroadcastEngine.Options()
        options.settings = Preferences.settings
        options.inputChannel = Preferences.inputChannel
        if let device = Preferences.inputDevice { options.inputQuery = device }
        if let device = Preferences.outputDevice { options.outputQuery = device }
        var headless = false

        var arguments = CommandLine.arguments.dropFirst()
        func value(for flag: String) -> String {
            guard let value = arguments.popFirst() else { fail("\(flag) needs a value") }
            return value
        }
        while let argument = arguments.popFirst() {
            switch argument {
            case "--headless": headless = true
            case "--input": options.inputQuery = value(for: argument)
            case "--output": options.outputQuery = value(for: argument)
            case "--input-channel-name": options.inputChannel = .named(value(for: argument))
            case "--input-channel":
                guard let channel = Int(value(for: argument)), channel >= 0 else { fail("--input-channel must be >= 0") }
                options.inputChannel = .index(channel)
            case "--buffer":
                guard let frames = UInt32(value(for: argument)), (16...4096).contains(frames) else { fail("--buffer must be 16...4096") }
                options.bufferFrames = frames
            case "--status-interval":
                guard let seconds = TimeInterval(value(for: argument)), seconds >= 0 else { fail("--status-interval must be >= 0") }
                options.statusInterval = seconds
            case "--list-devices":
                listDevices()
            case "--self-test":
                // Code defaults, not saved slider values, so the checks are reproducible.
                exit(SelfTest.run(settings: DSPSettings()) ? EXIT_SUCCESS : EXIT_FAILURE)
            case "--version":
                print("inline-dsp \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown")")
                exit(EXIT_SUCCESS)
            case "-h", "--help":
                print(usage)
                exit(EXIT_SUCCESS)
            default:
                fail("Unknown argument \(argument)\n\n\(usage)")
            }
        }

        let engine = BroadcastEngine(options: options)
        installSignalHandlers(engine)
        Log.info("inline-dsp started (pid \(getpid()), \(headless ? "headless" : "menu bar"))")

        guard headless else {
            MenuBarApp.engine = engine
            MenuBarApp.main()
            return
        }
        startWithMicrophoneAccess(engine) { granted in
            guard granted else { exit(EX_NOPERM) }
        }
        // Park the main thread in its run loop (not `dispatchMain()`, which exits the main thread
        // and drains the main queue on a worker thread, breaking MainActor isolation). The port
        // keeps the run loop from returning; the process sleeps until an event arrives.
        RunLoop.main.add(Port(), forMode: .default)
        RunLoop.main.run()
    }

    /// Without microphone access the HAL delivers silence, so refuse to run rather than
    /// broadcast it. For a terminal launch the permission belongs to the terminal app; otherwise
    /// to this binary via its embedded Info.plist.
    @MainActor
    static func startWithMicrophoneAccess(_ engine: BroadcastEngine,
                                          completion: @escaping @MainActor @Sendable (Bool) -> Void = { _ in }) {
        let finish: @MainActor @Sendable (Bool) -> Void = { granted in
            if granted {
                engine.start()
            } else {
                engine.report("Microphone access denied. Enable it in System Settings > Privacy & Security > Microphone.")
            }
            completion(granted)
        }
        switch AVAudioApplication.shared.recordPermission {
        case .granted: finish(true)
        case .denied: finish(false)
        default:
            Log.info("Requesting microphone access…")
            AVAudioApplication.requestRecordPermission { @Sendable granted in
                DispatchQueue.main.async { MainActor.assumeIsolated { finish(granted) } }
            }
        }
    }

    private static func listDevices() -> Never {
        do {
            for device in try AudioSystem.allDevices() {
                print(device)
                let mic = MicInputProfile.micChannelName(for: device)
                for (index, name) in AudioSystem.channelNames(device.id, .input).enumerated() {
                    print("    input \(index): \(name)\(name == mic ? "  <- XLR mic input" : "")")
                }
            }
            exit(EXIT_SUCCESS)
        } catch {
            Log.error("Could not enumerate devices: \(error)")
            exit(EXIT_FAILURE)
        }
    }

    // Graceful shutdown: route SIGINT/SIGTERM through dispatch so the engine stops and the
    // aggregate device is destroyed on the main queue instead of inside a signal handler.
    @MainActor private static var signalSources: [DispatchSourceSignal] = []

    @MainActor
    private static func installSignalHandlers(_ engine: BroadcastEngine) {
        for (number, name) in [(SIGINT, "SIGINT"), (SIGTERM, "SIGTERM")] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler {
                MainActor.assumeIsolated {
                    Log.info("Received \(name), shutting down")
                    engine.stop()
                    exit(EXIT_SUCCESS)
                }
            }
            source.resume()
            signalSources.append(source)
        }
    }

    private static func fail(_ message: String) -> Never {
        Log.error(message)
        exit(EX_USAGE)
    }
}
