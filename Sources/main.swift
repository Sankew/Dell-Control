import AppKit

// Command-line mode, for scripting and testing: "Dell Control.app/Contents/MacOS/DellControl get 10 62"
let args = Array(CommandLine.arguments.dropFirst())
let hex = { (s: String) in UInt8(s.replacingOccurrences(of: "0x", with: ""), radix: 16) }

switch args.first {
case "get":
    let ddc = DDC()
    for code in args.dropFirst().compactMap(hex) {
        if let r = await ddc.read(code) { print(String(format: "VCP 0x%02X = %d (max %d)", code, r.cur, r.max)) }
        else { print(String(format: "VCP 0x%02X: no reply", code)) }
    }
case "set":
    guard args.count == 3, let code = hex(args[1]), let v = Int(args[2]) else { print("usage: set <vcp-hex> <value>"); exit(2) }
    let ok = await DDC().write(code, v)
    print(ok ? "ok" : "write failed"); exit(ok ? 0 : 1)
case "caps":
    print(await DDC().capabilities())
case "pattern":
    let mode = args.dropFirst().first
    TestPattern.run(flat: mode == "flat", dark: mode == "shadows", gradient: mode == "gradient")
case "selftest":
    // The classic MCCS example: "get brightness" is 51 82 01 10 AC on the wire after the 6E address.
    precondition(DDC.packet([0x01, 0x10]) == [0x82, 0x01, 0x10, 0xAC])
    precondition(DDC.parse([0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x32, 0x00, 0x00], vcp: 0x10)! == (50, 100))
    precondition(DDC.parse([0x6E, 0x88, 0x02, 0x01, 0x10, 0x00, 0x00, 0x64, 0x00, 0x32, 0x00, 0x00], vcp: 0x10) == nil)
    // Brightness following: same percentage until calibrated, piecewise-linear after, offset added, clamped.
    precondition(BrightnessFollow.map(0.5, points: [], offset: 0) == 50)
    let pts: [[Double]] = [[0.25, 10], [0.5, 30], [0.75, 60], [1, 100]]
    precondition(BrightnessFollow.map(0.375, points: pts, offset: 0) == 20)
    precondition(BrightnessFollow.map(0.1, points: pts, offset: 0) == 4)
    precondition(BrightnessFollow.map(1, points: pts, offset: 10) == 100)
    precondition(BrightnessFollow.map(0.5, points: pts, offset: -40) == 0)
    precondition(BrightnessFollow.map(0.6, points: [[0.75, 60], [0.25, 10]], offset: 0) == 45)  // unsorted input
    print("selftest ok")
case nil:
    DellControlApp.main()
default:
    print("usage: DellControl [get <vcp>... | set <vcp> <value> | caps | pattern | selftest]"); exit(2)
}
