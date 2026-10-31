import Foundation
import Observation

/// Keeps the Dell looking as bright as the MacBook screen, through a by-eye calibration curve plus the user's offset.
@Observable
final class BrightnessFollow {
    static let shared = BrightnessFollow()
    static let calibrationLevels = [0.25, 0.5, 0.75, 1.0]

    var enabled = UserDefaults.standard.bool(forKey: "followMac") {
        didSet { UserDefaults.standard.set(enabled, forKey: "followMac") }
    }
    private(set) var offset = UserDefaults.standard.integer(forKey: "followOffset")
    /// Calibrated [macBrightness 0...1, dellBrightness 0...100] pairs; empty means "same percentage".
    private(set) var points = (UserDefaults.standard.array(forKey: "followPoints") as? [[Double]]) ?? []
    private(set) var macAvailable = false
    private(set) var calibrationStep: Int?  // index into calibrationLevels while calibrating
    @ObservationIgnored private var macBeforeCalibration: Double?
    @ObservationIgnored private var pendingPoints: [[Double]] = []

    func start() {
        Task {
            while true {
                tick()
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private func tick() {
        let mac = Displays.macBrightness
        if macAvailable != (mac != nil) { macAvailable = mac != nil }
        guard enabled, calibrationStep == nil, let mac else { return }
        // Re-applied every tick, so a write the Dell missed (asleep, waking, mode change) is corrected; unchanged values send nothing.
        Monitor.shared.set(Monitor.brightness, Self.map(mac, points: points, offset: offset))
    }

    /// The user moved the Dell's brightness by hand: remember how far from the curve they want it.
    func noteManual(_ dell: Int) {
        guard enabled, calibrationStep == nil, let mac = Displays.macBrightness else { return }
        offset = dell - Self.map(mac, points: points, offset: 0)
        save()
    }

    func resetOffset() {
        offset = 0
        save()
    }

    // MARK: calibration: the app sets the MacBook to each level and the user matches the Dell by eye

    func beginCalibration() {
        macBeforeCalibration = Displays.macBrightness
        pendingPoints = []
        show(step: 0)
        CalibrationOverlay.show()
    }

    func nextCalibrationStep() {
        guard let step = calibrationStep else { return }
        // The real level: the user may nudge the MacBook's keys, or auto-brightness may move it, while matching.
        pendingPoints.append([Displays.macBrightness ?? Self.calibrationLevels[step], Double(Monitor.shared.value[Monitor.brightness] ?? 50)])
        if step + 1 < Self.calibrationLevels.count { return show(step: step + 1) }
        points = pendingPoints
        offset = 0
        save()
        endCalibration()
    }

    func endCalibration() {
        calibrationStep = nil
        CalibrationOverlay.hide()
        if let macBeforeCalibration { Displays.setMacBrightness(macBeforeCalibration) }
    }

    private func show(step: Int) {
        calibrationStep = step
        Displays.setMacBrightness(Self.calibrationLevels[step])
    }

    private func save() {
        UserDefaults.standard.set(offset, forKey: "followOffset")
        UserDefaults.standard.set(points, forKey: "followPoints")
    }

    /// Piecewise-linear curve through (0, 0) and the calibrated points, flat past the last one, plus the offset.
    nonisolated static func map(_ mac: Double, points: [[Double]], offset: Int) -> Int {
        let pts = ([[0, 0]] + (points.isEmpty ? [[1, 100]] : points)).sorted { $0[0] < $1[0] }
        var dell = pts[pts.count - 1][1]
        for (a, b) in zip(pts, pts.dropFirst()) where mac <= b[0] {
            dell = b[0] > a[0] ? a[1] + (mac - a[0]) / (b[0] - a[0]) * (b[1] - a[1]) : b[1]
            break
        }
        return min(max(Int((dell + Double(offset)).rounded()), 0), 100)
    }
}
