import AppKit
import SwiftUI

/// Menu bar front end: the engine runs exactly as in headless mode, and the panel binds to its
/// observable status, meters and live DSP settings.
struct MenuBarApp: App {
    /// Set by `Entry` before `main()` so command-line options apply to the menu bar app too.
    @MainActor static var engine: BroadcastEngine!

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            ControlPanel(engine: Self.engine)
        } label: {
            MenuBarIcon(engine: Self.engine)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu bar only: no Dock icon, no app menu.
        NSApp.setActivationPolicy(.accessory)
        Entry.startWithMicrophoneAccess(MenuBarApp.engine)
    }

    func applicationWillTerminate(_ notification: Notification) {
        MenuBarApp.engine.stop()
    }
}

private struct MenuBarIcon: View {
    let engine: BroadcastEngine

    var body: some View {
        switch engine.status {
        case .running: Image(systemName: "waveform.circle.fill")
        case .stopped: Image(systemName: "waveform.circle")
        case .starting, .recovering, .waiting: Image(systemName: "exclamationmark.circle")
        }
    }
}

private struct ControlPanel: View {
    @Bindable var engine: BroadcastEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            devicePickers
            Divider()
            meters
            Divider()
            sliders
            Divider()
            HStack {
                Button("Reset to defaults") {
                    engine.settings = DSPSettings()
                    engine.inputChannel = .microphone
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(16)
        .frame(width: 340)
        .onAppear { engine.setMetering(true) }
        .onDisappear { engine.setMetering(false) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("InlineDSP").font(.headline)
                Spacer()
                Toggle("Engine", isOn: Binding(
                    get: { engine.status != .stopped },
                    set: { $0 ? Entry.startWithMicrophoneAccess(engine) : engine.stop() }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
            }
            Text(engine.status.label)
                .font(.subheadline)
                .foregroundStyle(engine.status == .running ? Color.green : .secondary)
            if let route = engine.routeDescription {
                Text(route).font(.caption).foregroundStyle(.secondary)
            }
            if let error = engine.lastError {
                Text(error).font(.caption).foregroundStyle(.red).lineLimit(4).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var devicePickers: some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
            GridRow {
                Text("Input").gridColumnAlignment(.trailing)
                DevicePicker(choices: engine.inputDevices, selection: engine.selectedInputUID,
                             missing: engine.inputDevice.isEmpty ? "System default" : engine.inputDevice) { engine.inputDevice = $0 }
            }
            GridRow {
                Text("Channel")
                Picker("Channel", selection: Binding(
                    get: { engine.activeInputChannel ?? -1 },
                    set: { engine.inputChannel = .named(engine.inputChannelNames[$0]) }
                )) {
                    if engine.activeInputChannel == nil { Text("—").tag(-1) }
                    ForEach(Array(engine.inputChannelNames.enumerated()), id: \.offset) { index, name in
                        Text(name == engine.micChannelName ? "\(name) (XLR mic)" : name).tag(index)
                    }
                }
                .labelsHidden()
                .disabled(engine.inputChannelNames.isEmpty)
            }
            GridRow {
                Text("Output")
                DevicePicker(choices: engine.outputDevices, selection: engine.selectedOutputUID,
                             missing: engine.outputDevice) { engine.outputDevice = $0 }
            }
        }
        .onAppear { engine.refreshDeviceLists() }
    }

    private var meters: some View {
        VStack(alignment: .leading, spacing: 8) {
            LevelMeter(title: "Input", level: engine.meters.inputPeakDB,
                       marker: engine.settings.gateThresholdDB)
            LevelMeter(title: "Output", level: engine.meters.outputPeakDB, marker: nil)
            // Gain change per stage, as attenuation in dB (0 = untouched).
            HStack {
                Text("Gate \(formatDB(-engine.meters.gateDB))")
                Spacer()
                Text("Comp \(formatDB(engine.meters.compressorDB))")
                Spacer()
                Text("De-ess \(formatDB(engine.meters.deEsserDB))")
                Spacer()
                Text("Limit \(formatDB(-engine.meters.limiterDB))")
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private var sliders: some View {
        VStack(alignment: .leading, spacing: 12) {
            ParameterSlider(title: "Gate threshold", value: $engine.settings.gateThresholdDB, range: -80...(-20),
                            hint: "Below this the input is turned down by 15 dB. Keep it under your voice on the input meter.")
            ParameterSlider(title: "Compressor threshold", value: $engine.settings.compressorThresholdDB, range: -50...(-6),
                            hint: "Compression starts here. Lower = more of your voice is levelled.")
            ParameterSlider(title: "Compressor ratio", value: $engine.settings.compressorRatio, range: 1...10,
                            format: { String(format: "%.1f:1", $0) },
                            hint: "How strongly levels above the threshold are reduced.")
            ParameterSlider(title: "De-esser threshold", value: $engine.settings.deEssThresholdDB, range: -60...0,
                            hint: "Lower = more sibilance reduction around 6.5 kHz.")
        }
    }
}

/// Device menu keyed by UID. A saved selection that is not connected stays visible as such
/// instead of silently showing some other device.
private struct DevicePicker: View {
    let choices: [BroadcastEngine.DeviceChoice]
    let selection: String?
    let missing: String
    let select: (String) -> Void

    var body: some View {
        Picker("Device", selection: Binding(get: { selection ?? "" }, set: { if !$0.isEmpty { select($0) } })) {
            if selection == nil { Text("\(missing) (not connected)").tag("") }
            ForEach(choices) { Text($0.name).tag($0.uid) }
        }
        .labelsHidden()
    }
}

private struct ParameterSlider: View {
    let title: String
    @Binding var value: Float
    let range: ClosedRange<Float>
    var format: (Float) -> String = { "\(formatDB($0)) dB" }
    let hint: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(format(value)).monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range)
            Text(hint).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Peak level on a -72...0 dBFS scale, with an optional tick (the gate threshold on the input
/// meter) so you can see whether your voice clears it.
private struct LevelMeter: View {
    let title: String
    let level: Float
    let marker: Float?

    private static let floor: Float = -72

    private func fraction(_ dB: Float) -> CGFloat {
        guard dB.isFinite else { return 0 }
        return CGFloat(min(max((dB - Self.floor) / -Self.floor, 0), 1))
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(title).frame(width: 48, alignment: .leading)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.2))
                    Capsule()
                        .fill(level > -6 ? Color.orange : .green)
                        .frame(width: geometry.size.width * fraction(level))
                    if let marker {
                        Rectangle()
                            .fill(Color.primary)
                            .frame(width: 2)
                            .offset(x: geometry.size.width * fraction(marker) - 1)
                    }
                }
            }
            .frame(height: 8)
            Text(formatDB(level))
                .font(.caption.monospacedDigit())
                .frame(width: 40, alignment: .trailing)
        }
    }
}
