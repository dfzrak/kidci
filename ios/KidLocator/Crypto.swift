import Foundation
import CommonCrypto
import CryptoKit

/// 与 Android 端 Crypto.java 逐字节兼容：
/// 密钥 = PBKDF2-HmacSHA256(配对码, "family-locator-v3.1", 10000, 32B)
/// 载荷 = base64(12B nonce || AES-256-GCM 密文 || 16B tag)
final class Crypto {
    static let salt = "family-locator-v3.1"
    static let iterations: UInt32 = 10000
    private let key: SymmetricKey

    init(code: String) throws {
        let saltData = Crypto.salt.data(using: .utf8)!
        let pwData = code.data(using: .utf8)!
        var derived = [UInt8](repeating: 0, count: 32)
        let status: Int32 = pwData.withUnsafeBytes { pwBuf -> Int32 in
            saltData.withUnsafeBytes { saltBuf -> Int32 in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                     pwBuf.bindMemory(to: Int8.self).baseAddress,
                                     pwData.count,
                                     saltBuf.bindMemory(to: UInt8.self).baseAddress,
                                     saltData.count,
                                     CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                                     Crypto.iterations,
                                     &derived, derived.count)
            }
        }
        guard status == kCCSuccess else {
            throw NSError(domain: "Crypto", code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "PBKDF2 失败"])
        }
        key = SymmetricKey(data: Data(derived))
    }

    func encrypt(_ plain: String) -> String? {
        guard let data = plain.data(using: .utf8) else { return nil }
        do {
            let nonce = AES.GCM.Nonce()
            let sealed = try AES.GCM.seal(data, using: key, nonce: nonce)
            guard let combined = sealed.combined else { return nil }
            return combined.base64EncodedString()
        } catch { return nil }
    }

    func decrypt(_ b64: String) -> String? {
        guard let data = Data(base64Encoded: b64), data.count >= 28 else { return nil }
        do {
            let box = try AES.GCM.SealedBox(combined: data)
            let pt = try AES.GCM.open(box, using: key)
            return String(data: pt, encoding: .utf8)
        } catch { return nil }
    }

    // ---- 仅供跨平台向量校验（Mac 构建时 verify_vectors.swift 使用）----
    func keyHexForTest() -> String {
        let raw = key.withUnsafeBytes { Data($0) }
        return raw.map { String(format: "%02x", $0) }.joined()
    }

    func sealFixedNonceForTest(_ plain: String, nonce: Data) -> Data? {
        do {
            let n = try AES.GCM.Nonce(data: nonce)
            let sealed = try AES.GCM.seal(Data(plain.utf8), using: key, nonce: n)
            // 返回 ciphertext||tag（与 Java Cipher.doFinal 输出一致，去掉 nonce）
            let combined = sealed.combined!
            return combined.dropFirst(nonce.count)
        } catch { return nil }
    }
}
