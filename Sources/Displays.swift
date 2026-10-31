import ColorSync
import CoreGraphics
import Foundation

/// The two screens this app cares about, plus the macOS calls that act on them.
enum Displays {
    static var dell: CGDirectDisplayID? { online().first { CGDisplayIsBuiltin($0) == 0 && CGDisplayVendorNumber($0) == 0x10AC } }
    static var builtin: CGDirectDisplayID? { online().first { CGDisplayIsBuiltin($0) != 0 } }  // nil while the lid is closed

    private static func online() -> [CGDirectDisplayID] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16), n: UInt32 = 0
        CGGetOnlineDisplayList(16, &ids, &n)
        return Array(ids.prefix(Int(n)))
    }

    // MARK: built-in brightness (DisplayServices, private; the same calls MonitorControl uses)

    private typealias GetFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFn = @convention(c) (CGDirectDisplayID, Float) -> Int32
    nonisolated(unsafe) private static let lib = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW)
    private static let getFn = dlsym(lib, "DisplayServicesGetBrightness").map { unsafeBitCast($0, to: GetFn.self) }
    private static let setFn = dlsym(lib, "DisplayServicesSetBrightness").map { unsafeBitCast($0, to: SetFn.self) }

    /// MacBook screen brightness 0...1, or nil when its screen is off.
    static var macBrightness: Double? {
        guard let id = builtin, let getFn else { return nil }
        var f: Float = 0
        return getFn(id, &f) == 0 ? Double(f) : nil
    }

    static func setMacBrightness(_ v: Double) {
        guard let id = builtin, let setFn else { return }
        _ = setFn(id, Float(min(max(v, 0), 1)))
    }

    // MARK: colour profile

    /// Assigns an ICC profile to the Dell for this user, as ColorSync Utility does.
    @discardableResult
    static func assignProfile(_ url: URL) -> Bool {
        guard let id = dell, FileManager.default.fileExists(atPath: url.path),
              let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return false }
        // Literal values of kColorSyncDeviceDefaultProfileID, kColorSyncProfileUserScope and kColorSyncDisplayDeviceClass:
        // the SDK exposes those as mutable globals, which Swift 6 refuses to read.
        let profiles: [String: Any] = ["DeviceDefaultProfileID": url, "ProfileUserScope": kCFPreferencesCurrentUser]
        return ColorSyncDeviceSetCustomProfiles("mntr" as CFString, uuid, profiles as CFDictionary)
    }
}
