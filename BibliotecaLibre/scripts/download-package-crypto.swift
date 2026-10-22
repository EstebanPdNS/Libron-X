import Foundation
import CryptoKit
let args = CommandLine.arguments
guard args.count == 5, ["seal", "open", "code"].contains(args[1]) else {
    throw NSError(domain: "LibronDownload", code: 1, userInfo: [NSLocalizedDescriptionKey: "Usage: tool seal|open|code KEY INPUT OUTPUT"])
}
let secret = try Data(contentsOf: URL(fileURLWithPath: args[2]))
let key = SymmetricKey(data: SHA256.hash(data: secret))
let input = try Data(contentsOf: URL(fileURLWithPath: args[3]))
let result: Data
if args[1] == "seal" { result = try AES.GCM.seal(input, using: key).combined! }
else if args[1] == "code" {
    let address = String(decoding: input, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    guard let url = URL(string: address), url.scheme == "https", url.host != nil, url.user == nil, url.password == nil,
          secret.count == 30, secret.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }) else {
        throw NSError(domain: "LibronDownload", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid resource key or URL"])
    }
    let payload: [String: Any] = ["version": 2, "url": address, "key": String(decoding: secret, as: UTF8.self)]
    let sealed = try AES.GCM.seal(JSONSerialization.data(withJSONObject: payload), using: key).combined!
    let code = sealed.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    result = Data(("LX2." + code + "\n").utf8)
}
else { result = try AES.GCM.open(AES.GCM.SealedBox(combined: input), using: key) }
try result.write(to: URL(fileURLWithPath: args[4]), options: .atomic)
