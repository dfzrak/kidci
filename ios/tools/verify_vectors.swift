// 跨平台加密一致性校验（在 macOS 上运行）：
//   swiftc KidLocator/Crypto.swift KidLocator/TopicUtils.swift tools/verify_vectors.swift -o /tmp/verify
//   /tmp/verify ../docs/vectors.json
// 校验对象：Java(Android) 生成的 docs/vectors.json
import Foundation

@main
struct VerifyVectorsMain {
    static func main() {
        do {
            try run()
        } catch {
            fatalError("校验异常: \(error)")
        }
    }

    static func run() throws {
        let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "docs/vectors.json"
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard let j = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            fatalError("vectors.json 解析失败")
        }
        let code = j["code"] as! String
        let keyHex = j["keyHex"] as! String
        let nonceHex = j["nonceHex"] as! String
        let ctTagHex = j["cipherTagHex"] as! String
        let livePayload = j["livePayload"] as! String
        let plainBytes = j["plaintext"] as! [Int]
        let fpExpected = j["topicFingerprint"] as! String
        let expectedPlain = String(data: Data(plainBytes.map { UInt8($0) }), encoding: .utf8)!

        let crypto = try Crypto(code: code)

        // 1. PBKDF2 密钥
        let actualKey = crypto.keyHexForTest()
        guard actualKey == keyHex else {
            fatalError("PBKDF2 不一致!\n  swift=\(actualKey)\n  java =\(keyHex)")
        }
        print("PBKDF2(10000, SHA-256) 一致: OK")

        // 2. topic 指纹
        let fp = TopicUtils.fingerprint(code)
        guard fp == fpExpected else { fatalError("topic 指纹不一致: \(fp) vs \(fpExpected)") }
        print("topic 指纹一致: OK")

        // 3. 固定 nonce 的 AES-256-GCM
        let nonce = fromHex(nonceHex)
        guard let sealed = crypto.sealFixedNonceForTest(expectedPlain, nonce: nonce) else {
            fatalError("加密失败")
        }
        guard toHex(sealed) == ctTagHex else {
            fatalError("AES-GCM 不一致!\n  swift=\(toHex(sealed))\n  java =\(ctTagHex)")
        }
        print("AES-256-GCM 固定向量一致: OK")

        // 4. 解密 Java 随机 nonce 载荷
        guard let dec = crypto.decrypt(livePayload) else { fatalError("livePayload 解密失败") }
        guard dec == expectedPlain else { fatalError("解密内容不符: \(dec)") }
        print("解密 Java 载荷: OK")

        print("ALL VECTORS PASSED —— Swift 与 Android 加密完全兼容")
    }

    static func fromHex(_ s: String) -> Data {
        var d = Data()
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            guard let b = UInt8(s[i..<j], radix: 16) else { fatalError("bad hex: \(s)") }
            d.append(b)
            i = j
        }
        return d
    }

    static func toHex(_ d: Data) -> String {
        return d.map { String(format: "%02x", $0) }.joined()
    }
}
