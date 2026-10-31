// Sony "PC Remote" over USB through ImageCaptureCore's raw PTP passthrough, no extra software.
// The camera must be in PC Remote mode. Opcodes and property codes are the ones libgphoto2 uses for Sony.
//
// Build: swiftc -swift-version 5 Tools/sony-remote.swift -o build/sony-remote
// Use:   sony-remote info                   connect and list the camera's settable properties
//        sony-remote shoot <folder>         take one picture and download it
//        sony-remote props                  print every setting's current value
//        sony-remote set <prop-hex> <value> <bytes 1|2|4>   change a setting (e.g. shutter, ISO)
import Foundation
import ImageCaptureCore

enum Op: UInt16 {
    case getObjectInfo = 0x1008, getObject = 0x1009
    case sdioConnect = 0x9201, sdioExtDeviceInfo = 0x9202, setControlA = 0x9205, setControlB = 0x9207, allPropData = 0x9209
}
let shotHandle: UInt32 = 0xFFFF_C001  // where a Sony keeps the picture just taken

final class Remote: NSObject, ICDeviceBrowserDelegate, ICCameraDeviceDelegate {
    let browser = ICDeviceBrowser()
    var camera: ICCameraDevice?
    var tid: UInt32 = 0
    let job: (Remote) -> Void

    init(job: @escaping (Remote) -> Void) {
        self.job = job
        super.init()
        browser.delegate = self
        browser.browsedDeviceTypeMask = ICDeviceTypeMask(rawValue: ICDeviceTypeMask.camera.rawValue | ICDeviceLocationTypeMask.local.rawValue)!
        browser.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { if self.camera == nil { print("no camera found"); exit(1) } }
    }

    /// Sends one PTP command and waits for its answer. Returns (data-in, response code).
    func send(_ op: Op, _ params: [UInt32] = [], out: Data? = nil) -> (Data, UInt16) {
        tid += 1
        var c = Data()
        func put<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { c.append(contentsOf: $0) } }
        put(UInt32(12 + 4 * params.count)); put(UInt16(1)); put(op.rawValue); put(tid)
        params.forEach { put($0) }
        let done = DispatchSemaphore(value: 0)
        var result = (Data(), UInt16(0))
        camera!.requestSendPTPCommand(c, outData: out) { data, response, error in
            let code = response.count >= 8 ? UInt16(response[6]) | UInt16(response[7]) << 8 : 0
            if let error { print("PTP \(String(format: "0x%04X", op.rawValue)) error: \(error)") }
            result = (data, code)
            done.signal()
        }
        if done.wait(timeout: .now() + 20) == .timedOut { print("PTP \(String(format: "0x%04X", op.rawValue)) timed out"); exit(6) }
        return result
    }

    /// Sony's three-step handshake that turns on remote control.
    func connect() {
        _ = send(.sdioConnect, [1, 0, 0])
        _ = send(.sdioConnect, [2, 0, 0])
        var (info, code) = send(.sdioExtDeviceInfo, [0x12C])  // protocol 3.00 (newer bodies)
        if code != 0x2001 { (info, code) = send(.sdioExtDeviceInfo, [0xC8]) }  // 2.00
        _ = send(.sdioConnect, [3, 0, 0])
        print("remote control: \(code == 0x2001 ? "on" : String(format: "failed 0x%04X", code)), \(info.count) bytes of device info")
    }

    /// Value-only setting change (SetControlDeviceA), little-endian in `bytes` bytes.
    func set(_ prop: UInt16, _ value: Int64, bytes: Int) -> UInt16 {
        var d = Data()
        withUnsafeBytes(of: value.littleEndian) { d.append(contentsOf: $0.prefix(bytes)) }
        return send(.setControlA, [UInt32(prop)], out: d).1
    }

    /// Button press (SetControlDeviceB): 2 = down, 1 = up.
    func button(_ prop: UInt16, _ state: UInt16) {
        var d = Data()
        withUnsafeBytes(of: state.littleEndian) { d.append(contentsOf: $0) }
        _ = send(.setControlB, [UInt32(prop)], out: d)
    }

    func shoot(into folder: URL) {
        button(0xD2C1, 2)  // half-press (focus; manual focus just passes through)
        usleep(300_000)
        button(0xD2C2, 2)  // full press
        usleep(200_000)
        button(0xD2C2, 1)
        button(0xD2C1, 1)
        // Wait until the camera says the new picture is ready to read.
        for _ in 0..<60 {
            let (info, code) = send(.getObjectInfo, [shotHandle])
            if code == 0x2001, info.count > 52 {
                let name = ptpString(info, at: 52) ?? "shot.arw"
                let (file, c2) = send(.getObject, [shotHandle])
                guard c2 == 0x2001, !file.isEmpty else { print(String(format: "download failed 0x%04X", c2)); exit(5) }
                let url = folder.appending(path: name)
                try! file.write(to: url)
                print("saved: \(url.path) (\(file.count / 1024) KB)")
                return
            }
            usleep(500_000)
        }
        print("no picture came back"); exit(4)
    }

    /// Decodes GetAllDevicePropData: a count, then one Sony property description after another.
    func props() -> [UInt16: (value: Int64, type: UInt16, writable: Bool)] {
        let (d, _) = send(.allPropData)
        var out: [UInt16: (Int64, UInt16, Bool)] = [:]
        func u(_ o: Int, _ n: Int) -> Int64 { (0..<n).reduce(0) { $0 | Int64(d[o + $1]) << (8 * Int64($1)) } }
        func size(_ t: UInt16) -> Int? { [1: 1, 2: 1, 3: 2, 4: 2, 5: 4, 6: 4, 7: 8, 8: 8][Int(t)] }
        func skipValue(_ o: inout Int, _ t: UInt16) -> Int64? {
            if t == 0xFFFF { let n = Int(d[o]); o += 1 + 2 * n; return nil }
            guard let n = size(t) else { return nil }
            defer { o += n }
            return u(o, n)
        }
        func looksLikeCode(_ o: Int) -> Bool { o + 2 <= d.count && [0x5, 0xD].contains(Int(u(o, 2)) >> 12) }
        let count = Int(u(0, 4))
        var o = 8
        for _ in 0..<count {
            guard o + 6 <= d.count else { break }
            let code = UInt16(u(o, 2)), type = UInt16(u(o + 2, 2)), getset = d[o + 4]
            o += 6
            _ = skipValue(&o, type)
            let cur = skipValue(&o, type) ?? 0
            let form = d[o]; o += 1
            if form == 1 { for _ in 0..<3 { _ = skipValue(&o, type) } }
            if form == 2 {
                // Newer bodies send two lists (values allowed now, then all values); older ones send one.
                for pass in 0..<2 {
                    if pass == 1 && looksLikeCode(o) { break }
                    let n = Int(u(o, 2)); o += 2
                    for _ in 0..<n { _ = skipValue(&o, type) }
                }
            }
            out[code] = (cur, type, getset != 0)
        }
        return out
    }

    func ptpString(_ d: Data, at offset: Int) -> String? {
        guard offset < d.count else { return nil }
        let n = Int(d[offset]); guard n > 0, offset + 1 + n * 2 <= d.count else { return nil }
        let units = (0..<n).map { UInt16(d[offset + 1 + $0 * 2]) | UInt16(d[offset + 2 + $0 * 2]) << 8 }
        return String(decoding: units.filter { $0 != 0 }, as: UTF16.self)
    }

    // MARK: ImageCaptureCore plumbing

    func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        guard let cam = device as? ICCameraDevice, camera == nil else { return }
        camera = cam; cam.delegate = self
        cam.requestOpenSession()
    }
    func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {}
    func didRemove(_ device: ICDevice) { print("camera disconnected"); exit(1) }
    func device(_ device: ICDevice, didOpenSessionWithError error: Error?) { if let error { print("open failed: \(error)"); exit(1) } }
    func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {}
    func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {
        // PTP calls block on a semaphore, so run the job off the main thread that delivers their callbacks.
        DispatchQueue.global().async { self.job(self); exit(0) }
    }
    func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {}
    func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?, for item: ICCameraItem, error: Error?) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable: Any]?, for item: ICCameraItem, error: Error?) {}
    func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {}
    func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {}
    func deviceDidBecomeReady(_ device: ICDevice) {}
    func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {}
    func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {}
}

let a = CommandLine.arguments
let remote: Remote
switch a.count > 1 ? a[1] : "" {
case "info":
    remote = Remote { r in r.connect(); let (d, code) = r.send(.allPropData); print(String(format: "all-properties: 0x%04X, %d bytes", code, d.count)) }
case "props":
    remote = Remote { r in
        r.connect()
        for (k, v) in r.props().sorted(by: { $0.key < $1.key }) {
            print(String(format: "0x%04X = %lld (0x%llX) type %d %@", k, v.value, v.value, v.type, v.writable ? "settable" : ""))
        }
    }
case "shoot" where a.count == 3:
    let folder = URL(fileURLWithPath: a[2])
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    remote = Remote { r in r.connect(); r.shoot(into: folder) }
case "set" where a.count == 5:
    let prop = UInt16(a[2].replacingOccurrences(of: "0x", with: ""), radix: 16)!, v = Int64(a[3])!, n = Int(a[4])!
    remote = Remote { r in r.connect(); print(String(format: "set 0x%04X = %lld: 0x%04X", prop, v, r.set(prop, v, bytes: n))) }
default:
    print("usage: sony-remote info | props | shoot <folder> | set <prop-hex> <value> <bytes>"); exit(2)
}
RunLoop.main.run()
