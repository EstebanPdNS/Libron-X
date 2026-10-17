import Foundation
import Testing
@testable import LibronixCore

struct LegacyWMFTests {
    static func fixture() -> (Data,Data) {
        var dib = Data()
        func d16(_ n: UInt16) { dib.append(UInt8(truncatingIfNeeded:n));dib.append(UInt8(truncatingIfNeeded:n >> 8)) }
        func d32(_ n: UInt32) { d16(UInt16(truncatingIfNeeded:n));d16(UInt16(truncatingIfNeeded:n >> 16)) }
        d32(40);d32(1);d32(1);d16(1);d16(24);d32(0);d32(4);d32(0);d32(0);d32(0);d32(0)
        dib.append(contentsOf:[0x11,0x22,0x33,0])
        var metafile = Data()
        func w16(_ n: UInt16) { metafile.append(UInt8(truncatingIfNeeded:n));metafile.append(UInt8(truncatingIfNeeded:n >> 8)) }
        func w32(_ n: UInt32) { w16(UInt16(truncatingIfNeeded:n));w16(UInt16(truncatingIfNeeded:n >> 16)) }
        w16(1);w16(9);w16(0x300);w32(47);w16(0);w32(35);w16(0)
        w32(35);w16(0x0b41);w32(0x00cc0020)
        for n: UInt16 in [1,1,0,0,1,1,0,0] { w16(n) }
        metafile.append(dib);w32(3);w16(0)
        return (metafile,dib)
    }
    @Test func completeBitmapKeepsPixelBytesAndReceivesValidFileHeader() throws {
        let (metafile,dib) = Self.fixture()
        let bmp = try #require(LegacyWMF.rasterBitmap(metafile))
        #expect(bmp.prefix(2) == Data([0x42,0x4d]))
        #expect(bmp.dropFirst(14) == dib)
        #expect(bmp[10] == 54 && bmp.count == 58)
    }
    @Test func truncatedOrCompositedMetafilesDoNotPretendToBeCompleteBitmaps() {
        let (metafile,_) = Self.fixture()
        #expect(LegacyWMF.rasterBitmap(Data(metafile.dropLast())) == nil)
        var composite = Data(metafile.dropLast(6))
        composite.append(contentsOf:[5,0,0,0,0x13,2,1,0,1,0,3,0,0,0,0,0])
        composite[6] = UInt8(composite.count/2)
        #expect(LegacyWMF.rasterBitmap(composite) == nil)
    }
}
