import Foundation

/// Strict, bounded Unicode SCSU decoding (UTS #6 revision 4). No platform ICU
/// dependency or locale-dependent interpretation of source bytes.
public enum SCSUDecoder {
    public enum Failure: Error, Sendable, Equatable { case truncated, reserved, invalidUnicode, limitExceeded }
    public static func decode(_ data: Data, maximumUTF16Units: Int = 65_536) throws -> String {
        guard maximumUTF16Units >= 0, data.count <= 1_048_576 else { throw Failure.limitExceeded }
        let bytes = Array(data)
        let fixed = [0, 0x80, 0x100, 0x300, 0x2000, 0x2080, 0x2100, 0x3000]
        var windows = [0x80, 0xc0, 0x400, 0x600, 0x900, 0x3040, 0x30a0, 0xff00]
        var at = 0, active = 0, unicode = false, units: [UInt16] = []
        func byte() throws -> Int {
            guard at < bytes.count else { throw Failure.truncated }
            defer { at += 1 }; return Int(bytes[at])
        }
        func append(_ value: Int) throws {
            guard (0...0x10ffff).contains(value) else { throw Failure.invalidUnicode }
            let count = value <= 0xffff ? 1 : 2
            guard count <= maximumUTF16Units - units.count else { throw Failure.limitExceeded }
            if count == 1 { units.append(UInt16(value)) }
            else {
                units.append(UInt16(0xd800 + ((value - 0x10000) >> 10)))
                units.append(UInt16(0xdc00 + ((value - 0x10000) & 0x3ff)))
            }
        }
        func define(_ index: Int) throws -> Int {
            switch index {
            case 1...0x67: return index * 0x80
            case 0x68...0xa7: return index * 0x80 + 0xac00
            case 0xf9...0xff: return [0xc0, 0x250, 0x370, 0x530, 0x3040, 0x30a0, 0xff60][index - 0xf9]
            default: throw Failure.reserved
            }
        }
        func extended() throws {
            let high = try byte(), low = try byte()
            active = high >> 5
            windows[active] = 0x10000 + (((high & 31) * 256 + low) * 128)
            unicode = false
        }
        while at < bytes.count {
            try Task.checkCancellation()
            let value = try byte()
            if unicode {
                switch value {
                case 0xe0...0xe7: active = value - 0xe0; unicode = false
                case 0xe8...0xef:
                    active = value - 0xe8; windows[active] = try define(byte()); unicode = false
                case 0xf0: try append(byte() * 256 + byte())
                case 0xf1: try extended()
                case 0xf2: throw Failure.reserved
                default: try append(value * 256 + byte())
                }
            } else {
                switch value {
                case 0, 9, 10, 13, 0x20...0x7f: try append(value)
                case 1...8:
                    let quoted = try byte(), index = value - 1
                    try append(quoted < 128 ? fixed[index] + quoted : windows[index] + quoted - 128)
                case 0x0b: try extended()
                case 0x0c: throw Failure.reserved
                case 0x0e: try append(byte() * 256 + byte())
                case 0x0f: unicode = true
                case 0x10...0x17: active = value - 0x10
                case 0x18...0x1f: active = value - 0x18; windows[active] = try define(byte())
                default: try append(windows[active] + value - 128)
                }
            }
        }
        let result = String(decoding: units, as: UTF16.self)
        guard Array(result.utf16) == units else { throw Failure.invalidUnicode }
        return result
    }
}
