import Foundation
import CSCSI

struct TzError: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}

// MARK: - Protocol constants (recovered from UsbConfig.exe / SCSI.dll)
enum Proto {
    static let opRead: UInt8 = 0xEC
    static let opWrite: UInt8 = 0xCE
    static let addrWrite: UInt32 = 0x1000_0000
    static let vendor = "Tzone"
    static let product = "DataLogger"
    static let defaultPassword = "000000"

    static let addrID: UInt32 = 0x0300_0002
    static let addrTime: UInt32 = 0x0300_0006
    static let addrWifi: UInt32 = 0x0300_0020
    static let addrHwExtra: UInt32 = 0x0300_0910
    static let addrHwModel: UInt32 = 0x0300_0911

    /// 12-byte CDB: opcode, 0, address (BE32), length (BE24), 0, 0, 0
    static func cdb(op: UInt8, address: UInt32, length: Int) -> [UInt8] {
        [op, 0,
         UInt8(truncatingIfNeeded: address >> 24), UInt8(truncatingIfNeeded: address >> 16),
         UInt8(truncatingIfNeeded: address >> 8), UInt8(truncatingIfNeeded: address),
         UInt8(truncatingIfNeeded: length >> 16), UInt8(truncatingIfNeeded: length >> 8),
         UInt8(truncatingIfNeeded: length), 0, 0, 0]
    }

    /// Port of GetCmdPackage: fields after "*CMD," up to "#", split on ",".
    static func parse(_ data: [UInt8]) -> [String]? {
        let text = String(decoding: data.map { $0 < 128 ? $0 : 63 }, as: UTF8.self)
        guard let s = text.range(of: "*CMD,"), let e = text.range(of: "#"), s.lowerBound <= e.lowerBound,
              s.upperBound <= e.lowerBound else { return nil }
        return text[s.upperBound..<e.lowerBound].split(separator: ",", omittingEmptySubsequences: false).map(String.init)
    }

    static func frame(_ password: String, _ code: String, _ args: [String]) -> [UInt8] {
        Array(("*" + ([password, code] + args).joined(separator: ",") + "#").utf8)
    }
}

// MARK: - Models
struct DeviceInfo {
    var hardware = ""
    var firmware = ""
    var deviceID = ""
    var isWifiModel = false
}

struct WifiConfig {
    var deviceTimeUTC: Date?
    var ssid = ""
    var password = ""
}

// MARK: - Transport
final class ScsiLink {
    private var dev: OpaquePointer?

    init() throws {
        let n = 256
        var err = [CChar](repeating: 0, count: n)
        var p: OpaquePointer?
        let rc = tz_open(Proto.vendor, Proto.product, &p, &err, n)
        guard rc == 0, let p = p else { throw TzError(String(cString: err)) }
        dev = p
    }

    deinit { close() }

    func close() {
        if let d = dev { tz_close(d); dev = nil }
    }

    private func run(_ cdb: [UInt8], dir: Int32, _ buf: inout [UInt8]) throws {
        guard let d = dev else { throw TzError("Device is closed.") }
        let n = 256
        var err = [CChar](repeating: 0, count: n)
        let count = UInt32(buf.count)
        let rc: Int32 = cdb.withUnsafeBufferPointer { c in
            buf.withUnsafeMutableBufferPointer { b in
                tz_exec(d, c.baseAddress, UInt8(cdb.count), dir, b.baseAddress, count, &err, n)
            }
        }
        if rc != 0 { throw TzError(String(cString: err)) }
    }

    func read(address: UInt32, length: Int) throws -> [String]? {
        var buf = [UInt8](repeating: 0, count: length)
        try run(Proto.cdb(op: Proto.opRead, address: address, length: length), dir: TZ_DIR_IN, &buf)
        return Proto.parse(buf)
    }

    func write(_ payload: [UInt8]) throws {
        var buf = payload
        try run(Proto.cdb(op: Proto.opWrite, address: Proto.addrWrite, length: payload.count), dir: TZ_DIR_OUT, &buf)
    }
}

// MARK: - High level
struct LoggerSession {
    let link: ScsiLink
    var password = Proto.defaultPassword

    func info() throws -> DeviceInfo {
        var i = DeviceInfo()
        guard let p = try link.read(address: Proto.addrHwModel, length: 64), p.count > 1 else {
            throw TzError("The device did not answer the model query.")
        }
        i.hardware = p[1]
        let model = p[1].uppercased().split(separator: "_").first.map(String.init) ?? ""
        i.isWifiModel = ["WF501", "WF501B", "WF502", "WF502B"].contains(model)
        if let last = p.last, last.uppercased().hasPrefix("V") { i.firmware = String(last.dropFirst()) }
        // The Windows tool skips this extra read for the default (type 1) models.
        if i.isWifiModel, let q = try link.read(address: Proto.addrHwExtra, length: 64), q.count > 1 {
            i.hardware += "_" + q[1]
        }
        if let q = try link.read(address: Proto.addrID, length: 25), q.count > 1 { i.deviceID = q[1] }
        return i
    }

    func wifiConfig() throws -> WifiConfig {
        var c = WifiConfig()
        if let p = try link.read(address: Proto.addrTime, length: 50), p.count == 7 {
            let v = p[1...6].compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            if v.count == 6 {
                var cal = Calendar(identifier: .gregorian)
                cal.timeZone = TimeZone(identifier: "UTC")!
                c.deviceTimeUTC = cal.date(from: DateComponents(year: v[0] < 100 ? 2000 + v[0] : v[0],
                                                                month: v[1], day: v[2], hour: v[3], minute: v[4], second: v[5]))
            }
        }
        if let p = try link.read(address: Proto.addrWifi, length: 150), p.count == 3 {
            c.ssid = p[1]; c.password = p[2]
        }
        return c
    }

    /// Mirrors SetDeviceConfig_WF501: alarm limits (003), clock (006), WiFi (020).
    func saveWifi(ssid: String, password wifiPW: String) throws {
        for (name, v) in [("WiFi name", ssid), ("WiFi password", wifiPW)] {
            if v.contains("#") || v.contains(",") { throw TzError("\(name) may not contain '#' or ','.") }
            if !v.allSatisfy({ $0.isASCII }) { throw TzError("\(name) must use plain ASCII characters.") }
            if v.utf8.count > 63 { throw TzError("\(name) must be at most 63 characters.") }
        }
        try link.write(Proto.frame(password, "003", ["125", "-40", "100", "0", "1"]))
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yy,MM,dd,HH,mm,ss"
        try link.write(Proto.frame(password, "006", f.string(from: Date()).components(separatedBy: ",")))
        try link.write(Proto.frame(password, "020", [ssid, wifiPW]))
    }
}
