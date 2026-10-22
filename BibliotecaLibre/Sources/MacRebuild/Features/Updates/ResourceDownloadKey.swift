import Foundation
import MachO

/// The private build injects the distribution key into a Mach-O section.
/// This avoids putting the key in Git or UI; it is still extractable from the app.
enum ResourceDownloadKey {
    static var value: String? {
        guard let header = _dyld_get_image_header(0) else { return nil }
        let header64 = UnsafeRawPointer(header).assumingMemoryBound(to: mach_header_64.self)
        var size: UInt = 0
        guard let bytes = getsectiondata(header64, "__TEXT", "__lxkey", &size), size == 30 else { return nil }
        return validated(Data(bytes: bytes, count: Int(size)))
    }

    static func validated(_ data: Data) -> String? {
        guard data.count == 30, data.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
