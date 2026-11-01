import CryptoKit
import Foundation

/// Identifies the exact build of game_plugin. Function addresses are only valid for the build they
/// were found in, so when FM is patched the features that use them switch off, rather than run the
/// wrong code and show wrong answers.
public enum GameBuild {
    public static func fingerprint(pluginPath: String) -> String? {
        guard let file = try? Data(contentsOf: URL(fileURLWithPath: pluginPath), options: .alwaysMapped), file.count > 8 else { return nil }
        func u32be(_ offset: Int) -> Int { Int(file.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self).bigEndian }) }
        var range = 0..<file.count
        if u32be(0) == 0xcafe_babe {
            for i in 0..<u32be(4) where u32be(8 + i * 20) == 0x0100_000c {  // CPU_TYPE_ARM64
                let offset = u32be(8 + i * 20 + 8), size = u32be(8 + i * 20 + 12)
                range = offset..<(offset + size)
            }
        }
        let digest = SHA256.hash(data: file[(file.startIndex + range.lowerBound)..<(file.startIndex + range.upperBound)])
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
