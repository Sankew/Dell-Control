import AppKit
import SwiftUI

/// The same patch grid on every screen at once, so one photo shows both displays rendering identical colours.
/// Colours are sRGB, so each screen draws them through its own macOS colour profile, as real content would be.
enum TestPattern {
    static let patches: [(name: String, r: Double, g: Double, b: Double)] =
        [1.0, 0.85, 0.7, 0.55, 0.4, 0.25, 0.12, 0.05].map { ("\(Int(($0 * 100).rounded()))%", $0, $0, $0) }
        + [("red", 1, 0, 0), ("green", 0, 1, 0), ("blue", 0, 0, 1), ("yellow", 1, 1, 0)]
    /// Dark greys only, so no bright patch can scatter light inside the camera lens onto them.
    static let shadows: [(name: String, r: Double, g: Double, b: Double)] =
        [0.25, 0.2, 0.16, 0.12, 0.1, 0.08, 0.06, 0.05, 0.04, 0.03, 0.02, 0].map { ("\(Int(($0 * 100).rounded()))%", $0, $0, $0) }

    /// `flat`: every patch white, so a photo of it measures lens vignetting and screen unevenness at each patch.
    static func run(flat: Bool = false, dark: Bool = false, gradient: Bool = false) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let windows = NSScreen.screens.map { screen in
            let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
            w.level = .screenSaver
            w.backgroundColor = .black
            w.contentView = gradient ? NSHostingView(rootView: GradientTest())
                                     : NSHostingView(rootView: PatternGrid(flat: flat, patches: dark ? shadows : patches))
            w.setFrame(screen.frame, display: true)
            w.orderFrontRegardless()
            return w
        }
        NSCursor.hide()
        app.activate()
        // Any key or click ends it.
        NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { _ in exit(0) }
        withExtendedLifetime(windows) { app.run() }
        exit(0)
    }
}

struct PatternGrid: View {
    var flat = false
    var patches = TestPattern.patches

    var body: some View {
        let cols = Array(repeating: GridItem(.flexible(), spacing: 10), count: 4)
        GeometryReader { g in
            LazyVGrid(columns: cols, spacing: 10) {
                ForEach(patches, id: \.name) { p in
                    Color(.sRGB, red: flat ? 1 : p.r, green: flat ? 1 : p.g, blue: flat ? 1 : p.b)
                        .frame(height: (g.size.height - 40) / 3)
                        .overlay(alignment: .topLeading) {
                            Text(flat ? "" : p.name).font(.system(size: 11)).foregroundStyle(Color(white: 0.5)).padding(4)
                        }
                }
            }
            .padding(10)
        }
        .background(.black)
    }
}

/// Smooth ramps and white text on black: banding shows up as steps in the ramps, and blotches or coloured
/// fringes around the text point at the signal or the monitor's processing rather than the content.
struct GradientTest: View {
    var body: some View {
        VStack(spacing: 0) {
            ramp([.black, .white])
            ramp([.black, Color(.sRGB, white: 0.25)])
            ramp([.black, Color(.sRGB, red: 1, green: 0, blue: 0)])
            ramp([.black, Color(.sRGB, red: 0, green: 1, blue: 0)])
            ramp([.black, Color(.sRGB, red: 0, green: 0, blue: 1)])
            ZStack {
                Color.black
                VStack(alignment: .leading, spacing: 10) {
                    Text("White text on black. Look for blotches or colour fringes around the letters.").font(.system(size: 28))
                    Text("The quick brown fox jumps over the lazy dog 0123456789").font(.system(size: 15))
                    Text("Small text: The quick brown fox jumps over the lazy dog 0123456789").font(.system(size: 11))
                }
                .foregroundStyle(.white)
            }
        }
        .ignoresSafeArea()
    }

    private func ramp(_ colors: [Color]) -> some View {
        LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing)
    }
}
