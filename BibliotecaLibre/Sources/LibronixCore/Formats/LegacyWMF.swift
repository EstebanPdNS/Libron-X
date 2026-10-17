import Foundation

/// Extracts a complete SRCCOPY bitmap from a bounded WMF record stream.
/// Original metafile bytes remain attached to the decoded graphic. Vector
/// operations and cropped/composited images are not silently discarded.
public enum LegacyWMF {
    public static func rasterBitmap(_ data: Data) -> Data? {
        guard data.count >= 18, data.count <= 16 * 1024 * 1024 else { return nil }
        func u16(_ i: Int) -> Int { Int(data[i]) | Int(data[i+1]) << 8 }
        func u32(_ i: Int) -> Int { u16(i) | u16(i+2) << 16 }
        guard [1,2].contains(u16(0)), u16(2) == 9, [0x100,0x300].contains(u16(4)) else { return nil }
        let limit = u32(6)*2
        guard limit >= 24, limit <= data.count else { return nil }
        var cursor = 18, records = 0, bitmap: Data?
        // These records change playback state, not the extracted pixel content.
        let state: Set<Int> = [0x0103,0x020b,0x020c,0x020d,0x020e,0x0107,0x0102,
            0x00f7,0x0234,0x0035,0x01f0,0x012d,0x001e,0x0127]
        while cursor <= limit-6, records < 100_000 {
            records += 1
            let bytes = u32(cursor)*2, function = u16(cursor+4)
            guard bytes >= 6, bytes <= limit-cursor else { return nil }
            if function == 0 { return cursor+bytes == limit ? bitmap : nil }
            if function == 0x0b41 || function == 0x0f43 {
                let prefix = function == 0x0b41 ? 26 : 28
                guard bitmap == nil, bytes >= prefix+40, u32(cursor+6) == 0x00cc0020 else { return nil }
                if function == 0x0f43, u16(cursor+10) != 0 { return nil }
                let coords = cursor + (function == 0x0b41 ? 10 : 12)
                let dibStart = cursor+prefix
                guard u32(dibStart) >= 40, u16(coords+4) == 0, u16(coords+6) == 0,
                      u16(coords) == abs(Int(Int32(bitPattern:UInt32(u32(dibStart+8))))),
                      u16(coords+2) == Int(Int32(bitPattern:UInt32(u32(dibStart+4)))) else { return nil }
                bitmap = bmp(Data(data[dibStart..<(cursor+bytes)]))
                guard bitmap != nil else { return nil }
            } else if !state.contains(function) { return nil }
            cursor += bytes
        }
        return nil
    }
    private static func bmp(_ dib: Data) -> Data? {
        guard dib.count >= 40 else { return nil }
        func u16(_ i: Int) -> Int { Int(dib[i]) | Int(dib[i+1]) << 8 }
        func u32(_ i: Int) -> Int { u16(i) | u16(i+2) << 16 }
        let header = u32(0), width = Int(Int32(bitPattern:UInt32(u32(4))))
        let height = abs(Int(Int32(bitPattern:UInt32(u32(8)))))
        let bits = u16(14), compression = u32(16), colors = u32(32)
        guard [40,52,56,108,124].contains(header), header <= dib.count, (1...20000).contains(width),
              (1...20000).contains(height), width*height <= 40_000_000, u16(12) == 1,
              [1,4,8,16,24,32].contains(bits), [0,1,2,3,6].contains(compression) else { return nil }
        let palette = colors > 0 ? colors : bits <= 8 ? 1 << bits : 0
        guard palette <= 65536 else { return nil }
        let masks = header == 40 ? compression == 3 ? 12 : compression == 6 ? 16 : 0 : 0
        let pixels = header+masks+palette*4
        guard pixels <= dib.count else { return nil }
        if compression == 0 || compression == 3 || compression == 6 {
            let rowBytes = ((width*bits+31)/32)*4
            guard rowBytes*height <= dib.count-pixels else { return nil }
        }
        var result = Data([0x42,0x4d])
        func append32(_ n: Int) { for shift in stride(from:0,to:32,by:8) { result.append(UInt8((n >> shift)&255)) } }
        append32(14+dib.count);append32(0);append32(14+pixels);result.append(dib)
        return result
    }
}
