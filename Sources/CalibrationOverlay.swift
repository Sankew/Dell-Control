import AppKit
import SwiftUI

/// Full-screen comparison target for "Match Brightness by Eye": the same white, 50% and 20% bands on both screens,
/// with the white bands on the edges where the two screens meet, so the two whites sit side by side.
/// Laid out for a MacBook in front of and below the monitor; macOS's display arrangement doesn't say where it physically is.
enum CalibrationOverlay {
    private static var windows: [NSWindow] = []
    private static var keys: Any?

    static func show() {
        guard windows.isEmpty, let dell = screen(Displays.dell), let mac = screen(Displays.builtin) else { return }
        // White on the Dell's bottom edge and the MacBook's top edge.
        windows = [(dell, false, true), (mac, true, false)].map { screen, whiteFirst, controls in
            let w = KeyWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
            w.level = .screenSaver
            w.contentView = NSHostingView(rootView: CalibrationBands(whiteFirst: whiteFirst, controls: controls))
            w.setFrame(screen.frame, display: true)
            w.orderFrontRegardless()
            return w
        }
        windows[0].makeKey()
        NSApp.activate()
        keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            let follow = BrightnessFollow.shared, m = Monitor.shared
            let step = e.modifierFlags.contains(.shift) ? 5 : 1
            switch e.keyCode {
            case 123: m.set(Monitor.brightness, (m.value[Monitor.brightness] ?? 50) - step)  // ←
            case 124: m.set(Monitor.brightness, (m.value[Monitor.brightness] ?? 50) + step)  // →
            case 36, 76: follow.nextCalibrationStep()  // Return
            case 53: follow.endCalibration()  // Esc
            default: return e
            }
            return nil
        }
    }

    static func hide() {
        windows.forEach { $0.orderOut(nil) }
        windows = []
        if let keys { NSEvent.removeMonitor(keys) }
        keys = nil
    }

    private static func screen(_ id: CGDirectDisplayID?) -> NSScreen? {
        NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == id }
    }

    /// Borderless windows can't take the keyboard unless they say so.
    private final class KeyWindow: NSWindow {
        override var canBecomeKey: Bool { true }
    }
}

struct CalibrationBands: View {
    let whiteFirst: Bool, controls: Bool

    var body: some View {
        let levels = whiteFirst ? [1.0, 0.5, 0.2] : [0.2, 0.5, 1.0]
        ZStack {
            VStack(spacing: 0) { ForEach(levels, id: \.self) { Color(.sRGB, white: $0) } }
            if controls { CalibrationPanel() }
        }
        .ignoresSafeArea()
    }
}

struct CalibrationPanel: View {
    private let follow = BrightnessFollow.shared

    var body: some View {
        let step = follow.calibrationStep ?? 0, count = BrightnessFollow.calibrationLevels.count
        VStack(alignment: .leading, spacing: 14) {
            Text("Match Brightness: step \(step + 1) of \(count)").font(.title3.weight(.semibold))
            Text("Your MacBook is at \(Int(BrightnessFollow.calibrationLevels[step] * 100))%. Change the Dell until its white band looks as bright as the MacBook's next to it, then check the greys.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            LevelRow(name: "Dell brightness", icon: "sun.max.fill", code: Monitor.brightness)
            HStack {
                Text("← → to adjust, ⇧ for bigger steps").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { follow.endCalibration() }
                Button(step + 1 < count ? "Next" : "Finish") { follow.nextCalibrationStep() }.buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 440)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .environment(\.colorScheme, .dark)
    }
}
