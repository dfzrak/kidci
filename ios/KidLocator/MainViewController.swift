import UIKit

class MainViewController: UIViewController {
    var codeField: UITextField!
    var statusLabel: UILabel!
    var startButton: UIButton!
    var stopButton: UIButton!

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .white
        title = "位置共享 · 孩子端"
        buildUI()
        if Prefs.getRole() == "child" && Prefs.isSharing() {
            showStatus()
            LocationService.shared.requestAndStart { [weak self] granted in
                DispatchQueue.main.async { self?.showStatus() }
            }
        }
    }

    private func buildUI() {
        codeField = UITextField()
        codeField.placeholder = "配对码（8 位以上字母/数字）"
        codeField.borderStyle = .roundedRect
        codeField.autocorrectionType = .no
        codeField.autocapitalizationType = .none
        codeField.text = Prefs.getCode()

        startButton = UIButton(type: .system)
        startButton.setTitle("开始共享位置", for: .normal)
        startButton.titleLabel?.font = .boldSystemFont(ofSize: 18)
        startButton.addTarget(self, action: #selector(startSharing), for: .touchUpInside)

        stopButton = UIButton(type: .system)
        stopButton.setTitle("停止共享位置", for: .normal)
        stopButton.setTitleColor(.systemRed, for: .normal)
        stopButton.titleLabel?.font = .boldSystemFont(ofSize: 17)
        stopButton.addTarget(self, action: #selector(stopSharing), for: .touchUpInside)

        statusLabel = UILabel()
        statusLabel.numberOfLines = 0
        statusLabel.font = .systemFont(ofSize: 15)

        let tip = UILabel()
        tip.numberOfLines = 0
        tip.font = .systemFont(ofSize: 12)
        tip.textColor = .gray
        tip.text = "· 首次使用请允许「始终允许」定位\n· 后台会持续共享位置（状态栏显示蓝色定位箭头）\n· 配对码是位置钥匙，不要告诉无关的人\n· 停止共享请打开本 App 点击「停止共享位置」"

        let stack = UIStackView(arrangedSubviews: [codeField, startButton, stopButton, statusLabel, tip])
        stack.axis = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24)
        ])
        stopButton.isHidden = true
        statusLabel.text = ""
    }

    @objc func startSharing() {
        let code = codeField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let sanitized = TopicUtils.sanitize(code)
        guard sanitized.count >= 8 else {
            statusLabel.text = "配对码需 8 位以上字母或数字"
            return
        }
        Prefs.setRole("child")
        Prefs.setCode(sanitized)
        LocationService.shared.requestAndStart { [weak self] granted in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if granted {
                    Prefs.setSharing(true)
                    self.showStatus()
                } else {
                    self.statusLabel.text = "定位权限被拒绝：请到 设置→隐私与安全性→定位服务→位置共享 选「始终允许」"
                }
            }
        }
    }

    @objc func stopSharing() {
        LocationService.shared.stop()
        stopButton.isHidden = true
        startButton.isHidden = false
        codeField.isEnabled = true
        statusLabel.text = "已停止共享"
    }

    func showStatus() {
        startButton.isHidden = true
        stopButton.isHidden = false
        codeField.isEnabled = false
        refreshStatus()
        NotificationCenter.default.addObserver(self, selector: #selector(refreshStatus),
                                               name: .init("KidStatusUpdate"), object: nil)
    }

    @objc func refreshStatus() {
        statusLabel.text = LocationService.shared.statusText
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}
