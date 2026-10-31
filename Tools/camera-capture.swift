// Tethered capture through Apple's ImageCaptureCore: lists cameras, or takes one picture and downloads it.
// Build: swiftc -swift-version 5 Tools/camera-capture.swift -o build/camera-capture
// Use:   build/camera-capture list          |   build/camera-capture shoot <output-folder>
import Foundation
import ImageCaptureCore

final class Tether: NSObject, ICDeviceBrowserDelegate, ICCameraDeviceDelegate, ICCameraDeviceDownloadDelegate {
    let browser = ICDeviceBrowser()
    let shoot: Bool, out: URL
    var camera: ICCameraDevice?
    var known = Set<String>()

    init(shoot: Bool, out: URL) {
        self.shoot = shoot; self.out = out
        super.init()
        browser.delegate = self
        browser.browsedDeviceTypeMask = ICDeviceTypeMask(rawValue: ICDeviceTypeMask.camera.rawValue | ICDeviceLocationTypeMask.local.rawValue)!
        browser.start()
        // No camera within 10 s means nothing usable is connected.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { if self.camera == nil { print("no camera found"); exit(1) } }
    }

    func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        guard let cam = device as? ICCameraDevice, camera == nil else { return }
        camera = cam
        cam.delegate = self
        print("found: \(cam.name ?? "?")")
        cam.requestOpenSession()
    }
    func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {}
    func didRemove(_ device: ICDevice) { print("camera disconnected"); exit(1) }
    func device(_ device: ICDevice, didOpenSessionWithError error: Error?) { if let error { print("open failed: \(error)"); exit(1) } }
    func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {}

    func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {
        known = Set((device.mediaFiles ?? []).compactMap { $0.name })
        print("capabilities: \(device.capabilities.joined(separator: ", "))")
        guard shoot else { exit(0) }
        guard device.capabilities.contains(ICDeviceCapability.cameraDeviceCanTakePicture.rawValue) else {
            print("this camera doesn't accept remote shutter over ImageCaptureCore"); exit(3)
        }
        device.requestTakePicture()
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { print("no new picture arrived"); exit(4) }
    }

    func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {
        guard shoot else { return }
        for case let file as ICCameraFile in items where !known.contains(file.name ?? "") {
            known.insert(file.name ?? "")
            file.requestDownload(options: [.downloadsDirectoryURL: out, .overwrite: true]) { name, error in
                if let error { print("download failed: \(error)"); exit(5) }
                print("saved: \(self.out.appending(path: name ?? "?").path)")
                exit(0)
            }
        }
    }
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
guard a.count >= 2, ["list", "shoot"].contains(a[1]) else { print("usage: camera-capture list | shoot <folder>"); exit(2) }
let out = URL(fileURLWithPath: a.count > 2 ? a[2] : FileManager.default.currentDirectoryPath)
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
let tether = Tether(shoot: a[1] == "shoot", out: out)
RunLoop.main.run()
