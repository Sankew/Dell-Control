// Measures a photo of both screens showing `DellControl pattern` and compares the Dell against the MacBook.
// The MacBook (factory-calibrated, D65) is the reference: the camera's own colour errors hit both screens alike.
//
// swift Tools/analyze-photo.swift photo.(dng|heic|jpg) "dell:x,y x,y x,y x,y" "mac:x,y x,y x,y x,y" [preview.png]
// Corners are pixel positions in the photo as it opens in Preview: top-left, top-right, bottom-right, bottom-left
// of each screen's picture area. Prints per-patch linear values, tint and gamma per grey level, as JSON too.
// FLAT=<photo of `DellControl pattern flat`, same framing and exposure> divides out vignetting and screen unevenness.
import AppKit
import CoreImage

let args = CommandLine.arguments
guard args.count >= 4 else { print("usage: analyze-photo <photo> \"dell:TL TR BR BL\" \"mac:TL TR BR BL\" [preview.png]"); exit(2) }
let url = URL(fileURLWithPath: args[1])

// Linear-light decode. RAW goes through CIRAWFilter with its tone curve off; anything else is linearised from its profile.
func decode(_ url: URL) -> CIImage {
    if let raw = CIRAWFilter(imageURL: url) { raw.boostAmount = 0; raw.isGamutMappingEnabled = false; return raw.outputImage! }
    return CIImage(contentsOf: url, options: [.applyOrientationProperty: true])!
}
let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
let ctx = CIContext(options: [.workingColorSpace: linear])
let image = decode(url)
let ext = image.extent
let W = Int(ext.width), H = Int(ext.height)
func pixels(_ img: CIImage) -> [Float] {
    var px = [Float](repeating: 0, count: W * H * 4)
    ctx.render(img, toBitmap: &px, rowBytes: W * 16, bounds: ext, format: .RGBAf, colorSpace: linear)  // row 0 = top
    return px
}
var px = pixels(image)
let flatPx = ProcessInfo.processInfo.environment["FLAT"].map { pixels(decode(URL(fileURLWithPath: $0))) }

let names = ["100%", "85%", "70%", "55%", "40%", "25%", "12%", "5%", "red", "green", "blue", "yellow"]
let greyLevels: [Double] = [1, 0.85, 0.7, 0.55, 0.4, 0.25, 0.12, 0.05]

struct Screen { let name: String; let c: [CGPoint] }
func parse(_ s: String) -> Screen {
    let parts = s.split(separator: ":", maxSplits: 1)
    let pts = parts[1].split(separator: " ").map { p -> CGPoint in let v = p.split(separator: ",").map { Double($0)! }; return CGPoint(x: v[0], y: v[1]) }
    precondition(pts.count == 4, "need 4 corners")
    return Screen(name: String(parts[0]), c: pts)
}
let screens = [parse(args[2]), parse(args[3])]

/// Maps (u, v) in 0...1 across the screen to a photo pixel, bilinearly between the four corners (handles mild tilt).
func map(_ s: Screen, _ u: Double, _ v: Double) -> CGPoint {
    let top = CGPoint(x: s.c[0].x + (s.c[1].x - s.c[0].x) * u, y: s.c[0].y + (s.c[1].y - s.c[0].y) * u)
    let bot = CGPoint(x: s.c[3].x + (s.c[2].x - s.c[3].x) * u, y: s.c[3].y + (s.c[2].y - s.c[3].y) * u)
    return CGPoint(x: top.x + (bot.x - top.x) * v, y: top.y + (bot.y - top.y) * v)
}

/// Centre 40% of patch i in the 4x3 grid, as (u0, v0, u1, v1).
func patchBox(_ i: Int) -> (Double, Double, Double, Double) {
    let col = Double(i % 4), row = Double(i / 4)
    let cu = (col + 0.5) / 4, cv = (row + 0.5) / 3
    return (cu - 0.05, cv - 0.065, cu + 0.05, cv + 0.065)
}

func sample(_ s: Screen, _ i: Int, from px: [Float]) -> (rgb: [Double], clipped: Bool, box: [CGPoint]) {
    let (u0, v0, u1, v1) = patchBox(i)
    var sum = [0.0, 0.0, 0.0], n = 0.0, clipped = false
    for a in stride(from: u0, through: u1, by: (u1 - u0) / 24) {
        for b in stride(from: v0, through: v1, by: (v1 - v0) / 24) {
            let p = map(s, a, b)
            let x = Int(p.x), y = Int(p.y)
            guard x >= 0, y >= 0, x < W, y < H else { continue }
            let k = (y * W + x) * 4
            for c in 0..<3 { sum[c] += Double(px[k + c]); if px[k + c] > 0.97 { clipped = true } }
            n += 1
        }
    }
    return (sum.map { $0 / max(n, 1) }, clipped, [map(s, u0, v0), map(s, u1, v0), map(s, u1, v1), map(s, u0, v1)])
}

var results: [String: [[Double]]] = [:]
var boxes: [[CGPoint]] = []
for s in screens {
    var rows: [[Double]] = []
    for i in 0..<12 {
        let r = sample(s, i, from: px)
        // Patch ÷ the same spot when white: what's left is the screen's response, not the lens or the viewing angle.
        let flat = flatPx.map { sample(s, i, from: $0).rgb } ?? [1, 1, 1]
        rows.append(zip(r.rgb, flat).map { $0 / $1 })
        boxes.append(r.box)
        if r.clipped && i < 8 { print("WARNING: \(s.name) \(names[i]) is clipped; shoot darker") }
    }
    results[s.name] = rows
}

let dell = results[screens[0].name]!, mac = results[screens[1].name]!
func lum(_ v: [Double]) -> Double { 0.2126 * v[0] + 0.7152 * v[1] + 0.0722 * v[2] }
print(String(format: "%-7@ | %-26@ | %-26@ | %@", "patch", "Dell R/G  B/G   gamma", "Mac  R/G  B/G   gamma", "Dell vs Mac: R/G  B/G  rel.lum"))
for i in 0..<8 {
    let d = dell[i], m = mac[i]
    let dg = i == 0 ? Double.nan : log(lum(d) / lum(dell[0])) / log(greyLevels[i])
    let mg = i == 0 ? Double.nan : log(lum(m) / lum(mac[0])) / log(greyLevels[i])
    let relLum = (lum(d) / lum(dell[0])) / (lum(m) / lum(mac[0]))
    print(String(format: "%-7@ |  %.3f %.3f  %5.2f        |  %.3f %.3f  %5.2f        |  %.3f %.3f  %.3f",
                 names[i], d[0] / d[1], d[2] / d[1], dg, m[0] / m[1], m[2] / m[1], mg,
                 (d[0] / d[1]) / (m[0] / m[1]), (d[2] / d[1]) / (m[2] / m[1]), relLum))
}
print(String(format: "white luminance, Dell ÷ Mac: %.2f (1.00 = equally bright in the photo)", lum(dell[0]) / lum(mac[0])))
for i in 8..<12 {
    let d = dell[i], m = mac[i]
    print(String(format: "%-7@ Dell %.3f %.3f %.3f | Mac %.3f %.3f %.3f (each ÷ own white G)", names[i],
                 d[0] / dell[0][1], d[1] / dell[0][1], d[2] / dell[0][1], m[0] / mac[0][1], m[1] / mac[0][1], m[2] / mac[0][1]))
}
let json = try! JSONSerialization.data(withJSONObject: ["patches": names, "dell": dell, "mac": mac], options: [.prettyPrinted])
print(String(decoding: json, as: UTF8.self))

// Optional preview with the sample boxes drawn, scaled to 2000 px wide, to check the corners landed right.
if args.count >= 5 {
    let scale = 2000 / Double(W)
    let out = NSImage(size: NSSize(width: Double(W) * scale, height: Double(H) * scale))
    let cg = ctx.createCGImage(image, from: ext, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)!
    out.lockFocus()
    NSImage(cgImage: cg, size: out.size).draw(in: NSRect(origin: .zero, size: out.size))
    NSColor.systemPink.setStroke()
    for b in boxes {
        let path = NSBezierPath()
        for (j, p) in b.enumerated() {
            let q = NSPoint(x: p.x * scale, y: (Double(H) - p.y) * scale)
            j == 0 ? path.move(to: q) : path.line(to: q)
        }
        path.close(); path.lineWidth = 2; path.stroke()
    }
    out.unlockFocus()
    let rep = NSBitmapImageRep(data: out.tiffRepresentation!)!
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[4]))
}
