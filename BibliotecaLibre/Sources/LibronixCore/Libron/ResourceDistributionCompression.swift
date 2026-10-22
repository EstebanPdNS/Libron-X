import Foundation
import CLibronxCompression

public enum ResourceDistributionCompression {
    public static func inflate(_ data: Data, expectedBytes: Int) throws -> Data {
        guard expectedBytes >= 0, expectedBytes <= 2_147_483_648 else { throw LibronError.invalid("Resource expansion exceeds limit") }
        var result = Data(count: max(1, expectedBytes)), written = 0
        let capacity = result.count
        let status = data.withUnsafeBytes { input in result.withUnsafeMutableBytes { output in
            libronx_inflate_zlib(input.bindMemory(to: UInt8.self).baseAddress, data.count,
                output.bindMemory(to: UInt8.self).baseAddress, capacity, &written)
        } }
        guard status == 0, written == expectedBytes else { throw LibronError.invalid("Invalid compressed resource") }
        result.count = expectedBytes
        return result
    }
}
