import ServiceManagement
import SwiftUI

struct DellControlApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    var body: some Scene {
        MenuBarExtra("Dell Control", systemImage: "sun.max") { QuickPanel() }
            .menuBarExtraStyle(.window)
        Window("Dell Control", id: "settings") { SettingsView() }
            .windowResizability(.contentMinSize)
            .defaultLaunchBehavior(.suppressed)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ n: Notification) {
        // Quit doesn't close windows, so the Settings window's own cleanup never runs.
        if BrightnessFollow.shared.calibrationStep != nil { BrightnessFollow.shared.endCalibration() }
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        BrightnessFollow.shared.start()
        Task {
            await Monitor.shared.refresh()
            // Catch colour-mode changes made with the Dell's joystick, so the profile always matches.
            while true {
                try? await Task.sleep(for: .seconds(10))
                await Monitor.shared.refresh([Monitor.preset])
            }
        }
        // Sleep/wake and display changes invalidate the cached DDC service.
        for (center, name) in [(NSWorkspace.shared.notificationCenter, NSWorkspace.didWakeNotification),
                               (NotificationCenter.default, NSApplication.didChangeScreenParametersNotification)] {
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { Monitor.shared.reconnect() }
            }
        }
    }
}

// MARK: menu bar panel, styled like Control Center's Display and Sound modules

struct QuickPanel: View {
    private let m = Monitor.shared
    private let follow = BrightnessFollow.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 10) {
            if !m.connected { Module { NotAnswering() } }
            Module(title: "Display", subtitle: follow.enabled && follow.macAvailable ? "Following MacBook" : nil) {
                CapsuleSlider(code: Monitor.brightness, name: "Brightness") { v in v < 0.5 ? "sun.min.fill" : "sun.max.fill" }
            }
            Module(title: "Sound") {
                CapsuleSlider(code: Monitor.volume, name: "Volume") { v in
                    v == 0 ? "speaker.slash.fill" : v < 0.34 ? "speaker.wave.1.fill" : v < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
                }
            }
            Button {
                NSApp.activate()  // a menu bar app's windows open behind the front app otherwise
                openWindow(id: "settings")
            } label: {
                Label("Display Settings…", systemImage: "slider.horizontal.3")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .moduleBackground()
        }
        .padding(10)
        .frame(width: 300)
        .task { await m.refresh([Monitor.brightness, Monitor.volume]) }  // the Dell's own menu may have changed them
    }
}

struct Module<Content: View>: View {
    var title: String?
    var subtitle: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Spacer()
                    if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
                }
            }
            content
        }
        .padding(12)
        .moduleBackground()
    }
}

extension View {
    @ViewBuilder func moduleBackground() -> some View {
        if #available(macOS 26, *) {
            glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        } else {
            background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }
}

/// Control Center's thick capsule slider: white fill growing from the left, symbol riding inside it.
struct CapsuleSlider: View {
    let code: UInt8, name: String
    let icon: (Double) -> String
    private let m = Monitor.shared

    var body: some View {
        let maxV = Double(max(m.maxValue[code] ?? 100, 1))
        let fraction = Double(m.value[code] ?? 0) / maxV
        GeometryReader { g in
            let h = g.size.height
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.12))
                Capsule().fill(.white).frame(width: h + (g.size.width - h) * fraction)
                Image(systemName: icon(fraction))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.black.opacity(0.55))
                    .frame(width: h)
            }
            .contentShape(Capsule())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                let f = min(max((drag.location.x - h / 2) / max(g.size.width - h, 1), 0), 1)
                m.userSet(code, Int((f * maxV).rounded()))
            })
        }
        .frame(height: 24)
        .accessibilityRepresentation {
            Slider(value: Binding(get: { Double(m.value[code] ?? 0) }, set: { m.userSet(code, Int($0.rounded())) }), in: 0...maxV) {
                Text(name)
            }
        }
    }
}

// MARK: settings window

struct SettingsView: View {
    private let m = Monitor.shared
    private let follow = BrightnessFollow.shared

    var body: some View {
        Form {
            if !m.connected { Section { NotAnswering() } }
            Section("Picture") {
                LevelRow(name: "Brightness", icon: "sun.max.fill", code: Monitor.brightness)
                LevelRow(name: "Contrast", icon: "circle.lefthalf.filled", code: Monitor.contrast)
                LevelRow(name: "Sharpness", icon: "triangle.lefthalf.filled", code: Monitor.sharpness)
            }
            Section {
                Toggle("Follow MacBook brightness", isOn: Binding(get: { follow.enabled }, set: { follow.enabled = $0 }))
                if follow.enabled {
                    LabeledContent("Your adjustment", value: follow.offset == 0 ? "None" : String(format: "%+d", follow.offset))
                    HStack {
                        Button("Match Brightness by Eye…") { follow.beginCalibration() }
                            .disabled(!follow.macAvailable || follow.calibrationStep != nil)
                        Spacer()
                        Button("Clear Adjustment") { follow.resetOffset() }.disabled(follow.offset == 0)
                    }
                }
            } header: {
                Text("Brightness")
            } footer: {
                Text(follow.macAvailable
                     ? "The Dell follows the MacBook screen as it brightens and dims. Moving the Dell's slider keeps your change as an adjustment."
                     : "Open the MacBook's lid to follow its brightness.")
                    .foregroundStyle(.secondary)
            }
            Section("Sound") {
                LevelRow(name: "Volume", icon: "speaker.wave.2.fill", code: Monitor.volume)
            }
            Section {
                Picker("Colour mode", selection: Binding(get: { m.value[Monitor.preset] ?? 0 }, set: { m.setPreset($0) })) {
                    ForEach(Monitor.presets, id: \.0) { Text($0.1).tag($0.0) }
                }
                Picker("Contrast", selection: Binding(get: { m.toneCurve }, set: { m.toneCurve = $0 })) {
                    Text("Accurate (matches MacBook)").tag(0)
                    Text("More (gamma 2.3)").tag(1)
                    Text("Most (gamma 2.4)").tag(2)
                }
                .disabled(m.value[Monitor.preset] == 1)
                if m.value[Monitor.preset] == Monitor.customColor {
                    LevelRow(name: "Red", icon: "circle.fill", code: Monitor.red, tint: .red)
                    LevelRow(name: "Green", icon: "circle.fill", code: Monitor.green, tint: .green)
                    LevelRow(name: "Blue", icon: "circle.fill", code: Monitor.blue, tint: .blue)
                }
            } header: {
                Text("Colour")
            } footer: {
                Text((m.value[Monitor.preset] == Monitor.customColor
                      ? "Keep the gains at 100: white balance is applied by the Mac's GPU from the colour profile, and lowering a gain in the monitor causes banding. "
                      : "Choose Custom Color to adjust the red, green and blue gains. ")
                     + "More and Most deepen shadows and mid-tones to make up for the IPS panel's grey blacks; Accurate matches the MacBook. macOS uses the matching colour profile for each mode automatically.")
                    .foregroundStyle(.secondary)
            }
            Section("General") {
                Toggle("Open at login", isOn: Binding(get: { SMAppService.mainApp.status == .enabled }, set: { on in
                    try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                    // Once turned off in System Settings, macOS needs the user to approve it there again.
                    if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
                }))
                HStack {
                    Button("Show Test Pattern") { showPattern() }
                    Button("Show Gradient Test") { showPattern("gradient") }
                }
                HStack {
                    Button("Read Values from Monitor") { Task { await m.refresh() } }
                    Spacer()
                    Button("Quit Dell Control") { NSApp.terminate(nil) }
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 420, idealWidth: 440, minHeight: 520, idealHeight: 820)
        .navigationTitle("DELL S2725QC")
        .task { await m.refresh() }
        .onDisappear { if follow.calibrationStep != nil { follow.endCalibration() } }  // never leave the MacBook at a test level
    }
}

/// Same binary in pattern mode: fills every screen until any key or click.
private func showPattern(_ mode: String? = nil) {
    let p = Process()
    p.executableURL = Bundle.main.executableURL
    p.arguments = ["pattern"] + (mode.map { [$0] } ?? [])
    try? p.run()
}

struct LevelRow: View {
    let name: String, icon: String, code: UInt8
    var tint: Color = .accentColor
    private let m = Monitor.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label(name, systemImage: icon).foregroundStyle(tint == .accentColor ? .primary : tint)
                Spacer()
                Text(m.value[code].map(String.init) ?? "–").monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: Binding(get: { Double(m.value[code] ?? 0) }, set: { m.userSet(code, Int($0.rounded())) }),
                   in: 0...Double(max(m.maxValue[code] ?? 100, 1)))
                .tint(tint)
                .accessibilityLabel(name)
                .accessibilityValue(m.value[code].map(String.init) ?? "unknown")
        }
    }
}

struct NotAnswering: View {
    var body: some View {
        Label("The monitor isn't answering. Check the cable or wake it.", systemImage: "exclamationmark.triangle")
            .font(.callout).foregroundStyle(.secondary)
    }
}
