import Foundation
import CryptoKit

/// 与 Android 端一致：topic 指纹用 SHA-256（CryptoKit）。
private enum SHA256Shim {
    static func hash(data: Data) -> [UInt8] {
        return Array(SHA256.hash(data: data))
    }
}

enum Prefs {
    private static let d = UserDefaults.standard
    static func getRole() -> String? { d.string(forKey: "role") }
    static func setRole(_ v: String) { d.set(v, forKey: "role") }
    static func getCode() -> String { d.string(forKey: "code") ?? "" }
    static func setCode(_ v: String) { d.set(v, forKey: "code") }
    static func isSharing() -> Bool { d.bool(forKey: "sharing") }
    static func setSharing(_ v: Bool) { d.set(v, forKey: "sharing") }
    static func getLastUpload() -> String? { d.string(forKey: "lastUpload") }
    static func setLastUpload(_ v: String) { d.set(v, forKey: "lastUpload") }
}

/// 官方 MQTT 客户端（Network.framework，TLS 直连 broker.emqx.io:8883）
protocol MqttDelegate: AnyObject {
    func mqttDidChange(_ connected: Bool)
    func mqttDidReceive(topic: String, payload: String)
}

final class MqttClient {
    private let host = "broker.emqx.io"
    private let port: UInt16 = 8883
    private let keepalive: UInt16 = 60
    private let queue = DispatchQueue(label: "mqtt")
    private var conn: NWConnection?
    private var buffer = Data()
    private var connected = false
    private var running = false
    private var retry = 2
    private var timer: DispatchSourceTimer?
    private var subs: [String] = []
    private let clientId: String
    weak var delegate: MqttDelegate?

    init(clientId: String) { self.clientId = clientId }

    func start() {
        queue.async {
            guard !self.running else { return }
            self.running = true
            self.connect()
        }
    }
    func stop() {
        queue.async {
            self.running = false
            self.teardown()
        }
    }
    func subscribe(_ topic: String) {
        queue.async {
            if !self.subs.contains(topic) { self.subs.append(topic) }
            if self.connected { self.sendSubscribe(topic) }
        }
    }
    func publish(_ topic: String, _ payload: String, retain: Bool) {
        queue.async {
            guard self.connected, let c = self.conn else { return }
            var body = Data()
            body.append(self.utf8(topic))
            body.append(payload.data(using: .utf8) ?? Data())
            c.send(content: self.packet(type: 0x30 | (retain ? 1 : 0), body: body),
                   completion: .contentProcessed { _ in })
        }
    }
    var isConnected: Bool { connected }

    // MARK: - 连接
    private func connect() {
        let tls = NWProtocolTLS.Options()
        let params = NWParameters(tls: tls, tcp: .init())
        let c = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: params)
        conn = c
        c.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                self.sendConnect()
                self.receive()
            case .failed, .cancelled:
                self.reconnect()
            default:
                break
            }
        }
        c.start(queue: queue)
    }

    private func sendConnect() {
        var b = Data()
        b.append(utf8("MQTT"))
        b.append(contentsOf: [4, 0x02, UInt8(keepalive >> 8), UInt8(keepalive & 0xFF)])
        b.append(utf8(clientId))
        send(packet(type: 0x10, body: b))
    }

    private func receive() {
        conn?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, err in
            guard let self = self else { return }
            if let d = data, !d.isEmpty {
                self.buffer.append(d)
                self.parse()
            }
            if err == nil && !done { self.receive() }
            else { self.reconnect() }
        }
    }

    private func parse() {
        while buffer.count >= 2 {
            let type = buffer[buffer.startIndex]
            var len = 0, mul = 1, idx = buffer.startIndex + 1, ok = true
            while true {
                guard idx < buffer.endIndex else { return }
                let b = buffer[idx]
                len += Int(b & 0x7F) * mul
                mul *= 128
                idx += 1
                if (b & 0x80) == 0 { break }
                if mul > 128 * 128 * 128 { ok = false; break }
            }
            if !ok { reconnect(); return }
            let start = buffer.startIndex
            let total = idx - start + len
            guard buffer.count >= total else { return }
            let body = buffer.subdata(in: idx..<(idx + len))
            buffer.removeSubrange(start..<(idx + len))
            let t = type & 0xF0
            if t == 0x20 {
                connected = true
                delegate?.mqttDidChange(true)
                for s in subs { sendSubscribe(s) }
                startPing()
            } else if t == 0x30 {
                var p = body
                guard p.count >= 2 else { continue }
                let tl = Int(p[0]) << 8 | Int(p[1])
                guard p.count >= 2 + tl else { continue }
                let topic = String(data: p.subdata(in: 2..<(2 + tl)), encoding: .utf8) ?? ""
                let payload = String(data: p.subdata(in: (2 + tl)..<p.count), encoding: .utf8) ?? ""
                delegate?.mqttDidReceive(topic: topic, payload: payload)
            }
        }
    }

    private func sendSubscribe(_ topic: String) {
        var b = Data()
        b.append(contentsOf: [0, 1])       // 报文标识符（必须在 topic 前）
        b.append(utf8(topic))
        b.append(0)                        // QoS0
        send(packet(type: 0x82, body: b))
    }

    private func startPing() {
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 25, repeating: 25)
        t.setEventHandler { [weak self] in
            guard let self = self else { return }
            if self.connected { self.send(self.packet(type: 0xC0, body: Data())) }
        }
        t.resume()
        timer = t
    }

    private func send(_ p: Data) {
        conn?.send(content: p, completion: .contentProcessed { _ in })
    }

    private func reconnect() {
        guard running else { return }
        teardown()
        let delay = retry
        retry = min(retry * 2, 30)
        queue.asyncAfter(deadline: .now() + .seconds(delay)) { [weak self] in
            guard let self = self, self.running else { return }
            self.connect()
        }
    }

    private func teardown() {
        connected = false
        delegate?.mqttDidChange(false)
        conn?.cancel()
        conn = nil
        buffer = Data()
        timer?.cancel()
        timer = nil
    }

    // MARK: - 编码
    private func packet(type: UInt8, body: Data) -> Data {
        var d = Data([type])
        d.append(varint(body.count))
        d.append(body)
        return d
    }
    private func utf8(_ s: String) -> Data {
        let b = s.data(using: .utf8) ?? Data()
        var d = Data([UInt8(b.count >> 8), UInt8(b.count & 0xFF)])
        d.append(b)
        return d
    }
    private func varint(_ n: Int) -> Data {
        var x = n
        var out = Data()
        repeat {
            var b = UInt8(x & 0x7F)
            x >>= 7
            if x > 0 { b |= 0x80 }
            out.append(b)
        } while x > 0
        return out
    }
}
