import Foundation

enum TopicUtils {
    /// 与 Android Topics.code 一致：仅保留 ASCII 字母数字并转小写。
    static func sanitize(_ raw: String) -> String {
        var out = ""
        for ch in raw.lowercased() {
            let c = ch
            if (c >= "a" && c <= "z") || (c >= "0" && c <= "9") {
                out.append(c)
            }
        }
        return out
    }

    /// SHA-256 前 8 字节的 16 位 hex（与 Java Crypto.topicFingerprint 一致）。
    static func fingerprint(_ code: String) -> String {
        let digest = SHA256.hash(data: Data(code.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    static func loc(_ code: String) -> String {
        return "fl/\(fingerprint(code))/loc"
    }
}
