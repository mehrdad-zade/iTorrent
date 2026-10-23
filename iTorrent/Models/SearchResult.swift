import Foundation

nonisolated struct SearchResult: Identifiable, Hashable, Sendable {
    /// Uppercase hex v1 info hash; also the key used by `DownloadManager`.
    let infoHash: String
    let name: String
    let type: String
    let size: String
    let uploader: String
    let magnet: URL
    let sourceName: String

    var id: String { infoHash }
}

nonisolated enum InfoHash {
    /// Extracts the `btih` hash from a magnet link, normalized to uppercase hex.
    static func from(magnet: String) -> String? {
        guard let range = magnet.range(of: #"btih:([A-Za-z0-9]{32,40})"#, options: .regularExpression) else { return nil }
        let hash = String(magnet[range].dropFirst("btih:".count))
        return hash.count == 40 ? hash.uppercased() : base32ToHex(hash)
    }

    private static func base32ToHex(_ s: String) -> String? {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var bits = 0, value = 0
        var bytes: [UInt8] = []
        for c in s.uppercased() {
            guard let index = alphabet.firstIndex(of: c) else { return nil }
            value = (value << 5) | index
            bits += 5
            if bits >= 8 {
                bytes.append(UInt8((value >> (bits - 8)) & 0xFF))
                bits -= 8
            }
        }
        return bytes.map { String(format: "%02X", $0) }.joined()
    }
}
