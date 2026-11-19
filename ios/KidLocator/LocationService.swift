import Foundation
import CoreLocation

/// 后台定位 + 加密上报。与 Android LocationService 同一套协议：
/// 每 30 秒或移动 10 米上报一次；断网缓存、恢复补发；重启自动恢复。
final class LocationService: NSObject, CLLocationManagerDelegate, MqttDelegate {
    static let shared = LocationService()
    static let minInterval: TimeInterval = 30
    static let minDistance: CLLocationDistance = 10

    private let manager = CLLocationManager()
    private var mqtt: MqttClient?
    private var crypto: Crypto?
    private var topic: String = ""
    private var lastSent: Date = .distantPast
    private var lastLoc: CLLocation?
    private var lastUploadText: String = "--"
    private var queueCount: Int = 0

    private override init() {
        super.init()
    }

    func requestAndStart(completion: @escaping (Bool) -> Void) {
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = LocationService.minDistance
        manager.pausesLocationUpdatesAutomatically = false
        if #available(iOS 9.0, *) {
            manager.allowsBackgroundLocationUpdates = true
        }
        manager.activityType = .fitness
        Prefs.setSharing(true)
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestAlwaysAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            beginPublishing()
            completion(true)
        default:
            completion(false)
        }
    }

    func stop() {
        Prefs.setSharing(false)
        mqtt?.stop()
        mqtt = nil
        manager.stopUpdatingLocation()
        manager.stopMonitoringSignificantLocationChanges()
        manager.delegate = nil
    }

    private func beginPublishing() {
        let code = TopicUtils.sanitize(Prefs.getCode())
        guard code.count >= 1 else { return }
        guard let c = try? Crypto(code: code) else { return }
        crypto = c
        topic = TopicUtils.loc(code)
        mqtt = MqttClient(clientId: "fl-i-" + code + "-" + String(Int.random(in: 100000...999999)))
        mqtt?.delegate = self
        mqtt?.start()
        manager.startUpdatingLocation()
        manager.startMonitoringSignificantLocationChanges()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            beginPublishing()
            Prefs.setSharing(true)
        default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        guard let crypto = crypto, let mqtt = mqtt else { return }
        let moved = lastLoc.map { loc.distance(from: $0) } ?? .infinity
        let elapsed = Date().timeIntervalSince(lastSent)
        guard elapsed >= LocationService.minInterval || moved >= LocationService.minDistance else { return }
        guard elapsed >= 5 else { return }
        lastLoc = loc
        lastSent = Date()
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss"
        lastUploadText = fmt.string(from: Date())
        Prefs.setLastUpload(lastUploadText)
        let json = String(format: "{\"lat\":%.6f,\"lng\":%.6f,\"acc\":%.1f,\"ts\":%.0f}",
                          loc.coordinate.latitude, loc.coordinate.longitude,
                          loc.horizontalAccuracy, loc.timestamp.timeIntervalSince1970 * 1000)
        guard let enc = crypto.encrypt(json) else { return }
        if mqtt.isConnected {
            mqtt.publish(topic, enc, retain: true)
        } else {
            enqueue(enc)
        }
        NotificationCenter.default.post(name: .init("KidStatusUpdate"), object: nil)
    }

    func mqttDidChange(_ connected: Bool) {
        if connected { flushQueue() }
        NotificationCenter.default.post(name: .init("KidStatusUpdate"), object: nil)
    }

    func mqttDidReceive(topic: String, payload: String) { /* 孩子端只发布 */ }

    // MARK: - 离线缓存（UserDefaults 持久化）
    private func enqueue(_ payload: String) {
        var q = UserDefaults.standard.stringArray(forKey: "kidQueue") ?? []
        q.append(payload)
        if q.count > 500 { q.removeFirst(q.count - 500) }
        UserDefaults.standard.set(q, forKey: "kidQueue")
        queueCount = q.count
    }

    private func flushQueue() {
        guard let mqtt = mqtt else { return }
        let q = UserDefaults.standard.stringArray(forKey: "kidQueue") ?? []
        guard !q.isEmpty else { return }
        for p in q { mqtt.publish(topic, p, retain: true) }
        UserDefaults.standard.set([String](), forKey: "kidQueue")
        queueCount = 0
    }

    var statusText: String {
        let sharing = Prefs.isSharing() ? "共享中" : "已停止"
        let conn = mqtt?.isConnected ?? false ? "已连接" : "重连中"
        return "状态：\(sharing)\n中继：\(conn)\n最近上报：\(lastUploadText)\n本地缓存：\(queueCount) 条"
    }
}
