import Foundation
import IOKit

/// DDC/CI over Apple-silicon IOAVService (private API, the same path m1ddc and MonitorControl use).
/// An actor on its own serial queue: the monitor answers garbage if two transactions overlap,
/// and each one blocks for ~100 ms, which must stay off the main thread and the shared thread pool.
actor DDC {
    private typealias CreateFn = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    private typealias I2CFn = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn
    nonisolated(unsafe) private static let lib = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW)
    nonisolated(unsafe) private static let create = unsafeBitCast(dlsym(lib, "IOAVServiceCreateWithService"), to: CreateFn.self)
    nonisolated(unsafe) private static let writeI2C = unsafeBitCast(dlsym(lib, "IOAVServiceWriteI2C"), to: I2CFn.self)
    nonisolated(unsafe) private static let readI2C = unsafeBitCast(dlsym(lib, "IOAVServiceReadI2C"), to: I2CFn.self)

    private let queue = DispatchSerialQueue(label: "ddc")
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }
    private var svc: CFTypeRef?
    /// The serial queue only orders this process; the lock also keeps the app and the command line from talking over each other.
    private let lockFD = open(NSTemporaryDirectory() + "dellcontrol-ddc.lock", O_CREAT | O_RDWR, 0o600)

    private func locked<T>(_ body: () -> T) -> T {
        flock(lockFD, LOCK_EX)
        defer { flock(lockFD, LOCK_UN) }
        return body()
    }

    /// Forget the cached service after sleep/wake or a display change.
    func reset() { svc = nil }

    func write(_ vcp: UInt8, _ value: Int) -> Bool { locked { writeNow(vcp, value) } }
    func read(_ vcp: UInt8) -> (cur: Int, max: Int)? { locked { readNow(vcp) } }
    func capabilities() -> String { locked { readCaps() } }

    private func writeNow(_ vcp: UInt8, _ value: Int) -> Bool {
        let ok = send([0x03, vcp, UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)])
        usleep(60_000)  // the Dell silently drops a command that arrives sooner after a write, even from another process
        return ok
    }

    private func readNow(_ vcp: UInt8) -> (cur: Int, max: Int)? {
        for _ in 0..<4 {
            guard send([0x01, vcp]), let s = service() else { continue }
            usleep(50_000)
            var r = [UInt8](repeating: 0, count: 12)
            if Self.readI2C(s, 0x37, 0x51, &r, 12) == kIOReturnSuccess, let v = Self.parse(r, vcp: vcp) { return v }
            usleep(50_000)
        }
        return nil
    }

    private func readCaps() -> String {
        var out = [UInt8](), off = 0, fails = 0
        while off < 4096 && fails < 6 {
            guard send([0xF3, UInt8(off >> 8), UInt8(off & 0xFF)]), let s = service() else { fails += 1; continue }
            usleep(60_000)
            var r = [UInt8](repeating: 0, count: 40)
            guard Self.readI2C(s, 0x37, 0x51, &r, 40) == kIOReturnSuccess,
                  let i = r.firstIndex(of: 0xE3), i >= 1, i + 2 < r.count else { fails += 1; usleep(50_000); continue }
            let len = Int(r[i - 1] & 0x7F) - 3
            guard Int(r[i + 1]) << 8 | Int(r[i + 2]) == off, len >= 0, i + 3 + len <= r.count else { fails += 1; continue }
            if len == 0 { break }
            out += r[(i + 3)..<(i + 3 + len)]; off += len; fails = 0
            usleep(50_000)
        }
        return String(decoding: out.filter { $0 != 0 }, as: UTF8.self)
    }

    /// Host-to-display packet: length byte, payload, XOR checksum seeded with the destination and source addresses.
    static func packet(_ payload: [UInt8]) -> [UInt8] {
        let p = [UInt8(0x80 | payload.count)] + payload
        return p + [p.reduce(0x6E ^ 0x51) { $0 ^ $1 }]
    }

    /// Parses a "get VCP feature" reply: 6E 88 02 <result> <vcp> <type> <maxH> <maxL> <curH> <curL> <chk>.
    static func parse(_ r: [UInt8], vcp: UInt8) -> (cur: Int, max: Int)? {
        guard let i = r.firstIndex(of: 0x02), i + 7 < r.count, r[i + 1] == 0, r[i + 2] == vcp else { return nil }
        return (Int(r[i + 6]) << 8 | Int(r[i + 7]), Int(r[i + 4]) << 8 | Int(r[i + 5]))
    }

    private func service() -> CFTypeRef? {
        if let svc { return svc }
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceNameMatching("DCPAVServiceProxy"), &it) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(it) }
        var s = IOIteratorNext(it)
        while s != 0 {
            defer { IOObjectRelease(s); s = IOIteratorNext(it) }
            let loc = IORegistryEntryCreateCFProperty(s, "Location" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
            if loc == "External", let found = Self.create(kCFAllocatorDefault, s)?.takeRetainedValue() { svc = found; return found }
        }
        return nil
    }

    private func send(_ payload: [UInt8]) -> Bool {
        var p = Self.packet(payload)
        for attempt in 0..<3 {
            guard let s = service() else { return false }
            if Self.writeI2C(s, 0x37, 0x51, &p, UInt32(p.count)) == kIOReturnSuccess { return true }
            if attempt == 1 { svc = nil }  // monitor replugged or woke from sleep: look the service up again
            usleep(20_000)
        }
        return false
    }
}
