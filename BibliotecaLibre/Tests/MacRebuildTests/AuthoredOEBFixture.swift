import Foundation
import LibronixCore

/// Independently authored OEB fixture: shared-page articles, hidden text, a
/// table, combining marks and supplementary Unicode. Contains no book payload.
struct AuthoredOEBFixture {
    let root: URL
    let resource: LibraryResource
    init(missingStyle: Bool = false, chapterBody: String? = nil) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("owned-oeb-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        func html(_ body: String) -> Data { Data(("<html><head><meta charset=\"utf-8\"><link rel=\"stylesheet\" href=\"Help.css\"></head><body>" + body + "</body></html>").utf8) }
        var members = [
            "Cover.html":html("<span id=\"a0\"></span><h1>Owned cover</h1><p>No match here.</p>"),
            "Chapter.html":html(chapterBody ?? "<span id=\"a1\"></span><h1>Gamma</h1><p>café a\u{301}rbol 😀 gamma <strong>Delta</strong></p><p class=\"hidden\">InvisibleNeedle</p><table><tr><td>Table</td><td>Gamma</td></tr></table><span id=\"a2\"></span><h2>Second</h2><p>Gamma second</p>"),
            "Tail.html":html("<span id=\"a3\"></span><p>Tail Gamma</p>")]
        if !missingStyle { members["Help.css"] = Data(".hidden { display:none; } h1 { color:navy; } table { border:1px solid gray; }".utf8) }
        let names = ["Cover.html","Chapter.html","Tail.html"]
        var namePool = Data(), fileRecords = Data()
        for (i, name) in names.enumerated() {
            let data = (name + "\0").data(using: .utf16LittleEndian)!
            fileRecords += Self.words([UInt32(namePool.count),UInt32(data.count),[1,0,2][i]]); namePool += data
        }
        members["_file_info.dat"] = Data("LOEF".utf8) + Self.words([0x01000000,12,3,60,0]) + fileRecords + namePool
        var titles = Data(), fragments = Data(), articles = Data()
        for i in 0..<4 {
            let title = ["Cover","Chapter","Second","Tail"][i].appending("\0").data(using: .utf16LittleEndian)!
            let fragment = "a\(i)\0".data(using: .utf16LittleEndian)!
            articles += Self.words([UInt32(i),[0,1,1,2][i],i == 2 ? 1 : .max,[1,3,.max,.max][i],i == 2 ? 2 : 0,
                UInt32(titles.count),UInt32(title.count),UInt32(fragments.count),UInt32(fragment.count)])
            titles += title; fragments += fragment
        }
        members["_article_info.dat"] = Data("LOEA".utf8) + Self.words([0x01000000,12,4,176,UInt32(176 + titles.count),0,3]) + articles + titles + fragments
        let paths = members.keys.sorted(), start = 56 + paths.count * 144
        var directory = Data(), payload = Data()
        for path in paths {
            let data = members[path]!, name = path.data(using: .utf16LittleEndian)!
            directory += Self.le(UInt64(start + payload.count),8) + Self.le(UInt64(data.count),8) + name + Data(repeating: 0, count: 128 - name.count)
            payload += data
        }
        let archive = Data("LEFS".utf8) + Self.words([0x01000000,0,0,12,0,0,20]) + Self.le(UInt64(start),8) + Self.words([4,16,64,UInt32(paths.count)]) + directory + payload
        let url = root.appendingPathComponent("owned.lbxoeb")
        try Self.wrap(archive).write(to: url)
        resource = .init(location: url, title: "Owned OEB", byteCount: Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0),
            format: .libronixOEB, support: .opaqueContainer, provenance: .fileName)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
    private static func words(_ values: [UInt32]) -> Data { values.reduce(into: Data()) { $0 += le(UInt64($1),4) } }
    private static func le(_ value: UInt64, _ count: Int) -> Data { Data((0..<count).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }) }
    private static func wrap(_ payload: Data) -> Data {
        let header = Data("LTES".utf8) + words([0x01010000]) + le(UInt64(payload.count),8)
        var clear = Data(header.prefix(8)) + payload
        while clear.count % 8 != 0 { clear.append(0) }
        var key = [UInt32](repeating: 0, count: 4)
        for (i,c) in "Libronix File".utf8.enumerated() { key[i & 3] = key[i & 3] &* 17 &+ UInt32(c) }
        var output = header
        for at in stride(from: 0, to: clear.count, by: 8) {
            func word(_ offset: Int) -> UInt32 { (0..<4).reduce(0) { $0 | UInt32(clear[offset + $1]) << ($1 * 8) } }
            var a = word(at), b = word(at + 4), sum: UInt32 = 0
            for _ in 0..<8 {
                a = a &+ ((((b << 4) ^ (b >> 5)) &+ b) ^ (sum &+ key[Int(sum & 3)]))
                sum = sum &+ 0x9e3779b9
                b = b &+ ((((a << 4) ^ (a >> 5)) &+ a) ^ (sum &+ key[Int((sum >> 11) & 3)]))
            }
            output += words([a,b])
        }
        return output
    }
}
