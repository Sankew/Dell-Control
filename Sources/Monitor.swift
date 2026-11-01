import Foundation
import Observation

/// Cached monitor state for the UI. Runs on the main actor; the DDC actor does the slow I/O.
@Observable
final class Monitor {
    static let shared = Monitor()

    // VCP codes this Dell reports in its capabilities string.
    static let brightness: UInt8 = 0x10, contrast: UInt8 = 0x12, volume: UInt8 = 0x62, sharpness: UInt8 = 0x87
    static let preset: UInt8 = 0x14, red: UInt8 = 0x16, green: UInt8 = 0x18, blue: UInt8 = 0x1A
    static let customColor = 12  // 0x14 = 0x0C is the Dell's "Custom Color" mode, the only one that applies RGB gains
    static let presets: [(Int, String)] = [(5, "Standard (6500K)"), (1, "sRGB"), (8, "9300K"), (11, "User 1"), (12, "Custom Color")]
    /// Profiles bundled in the app, by tone curve: matched to the MacBook, then steeper ones that hide the IPS panel's raised blacks.
    static let toneCurves = [("Accurate", "Dell S2725QC Custom Color D65 G2.2"), ("More", "Dell S2725QC Custom Color D65 E2.3"),
                             ("Most", "Dell S2725QC Custom Color D65 E2.4")]

    let ddc = DDC()
    private(set) var value: [UInt8: Int] = [:]
    private(set) var maxValue: [UInt8: Int] = [:]
    private(set) var connected = true
    var toneCurve = UserDefaults.standard.integer(forKey: "toneCurve") {
        didSet { UserDefaults.standard.set(toneCurve, forKey: "toneCurve"); profiled = nil; matchProfile() }
    }
    @ObservationIgnored private var unsent: [UInt8: Int] = [:]
    @ObservationIgnored private var writer: Task<Void, Never>?
    @ObservationIgnored private var writing: Set<UInt8> = []
    @ObservationIgnored private var profiled: (preset: Int, curve: Int)?

    func refresh(_ codes: [UInt8] = [brightness, volume, contrast, sharpness, preset, red, green, blue]) async {
        var any = false
        for code in codes {
            guard let r = await ddc.read(code) else { continue }
            any = true
            // Don't apply a read for a control still being written, or its slider would snap back.
            if !writing.contains(code) { value[code] = r.cur; maxValue[code] = r.max }
        }
        connected = any
        matchProfile()
    }

    /// The slider path: also tells brightness-following to keep the user's change as an offset.
    func userSet(_ code: UInt8, _ v: Int) {
        set(code, v)
        if code == Self.brightness { BrightnessFollow.shared.noteManual(value[code] ?? v) }
    }

    /// Slider drags only send the latest value per control.
    func set(_ code: UInt8, _ v: Int) {
        let v = min(max(v, 0), maxValue[code] ?? 100)
        guard value[code] != v else { return }
        value[code] = v
        unsent[code] = v
        writing.insert(code)
        guard writer == nil else { return }
        writer = Task {
            while let (c, v) = unsent.first {
                unsent[c] = nil
                _ = await ddc.write(c, v)
            }
            writing = []
            writer = nil
        }
    }

    func setPreset(_ v: Int) {
        set(Self.preset, v)
        matchProfile()
        Task {
            try? await Task.sleep(for: .seconds(1))
            await refresh()  // a mode change can move brightness and gains
        }
    }

    func reconnect() {
        Task {
            await ddc.reset()
            try? await Task.sleep(for: .seconds(2))
            await refresh()
        }
    }

    /// Gives macOS the colour profile that describes the Dell's current mode, the way BenQ's "M-Book" mode pairs one.
    /// sRGB mode clamps the panel to sRGB; every other mode shows the native, wider gamut.
    private func matchProfile() {
        guard let p = value[Self.preset], profiled.map({ $0 != (p, toneCurve) }) ?? true else { return }
        let curve = Self.toneCurves[min(max(toneCurve, 0), Self.toneCurves.count - 1)].1
        let url = p == 1 ? URL.homeDirectory.appending(path: "Library/ColorSync/Profiles/Dell S2725QC sRGB (Dell official).icc")
                         : Bundle.main.url(forResource: curve, withExtension: "icc")
        if let url, Displays.assignProfile(url) { profiled = (p, toneCurve) }
    }
}
