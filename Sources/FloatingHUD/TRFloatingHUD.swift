import UIKit

/// 悬浮球 - 全局悬浮操作窗口
final class TRFloatingHUD: NSObject {
    static let shared = TRFloatingHUD()

    private var hudWindow: UIWindow?
    private var hudView: UIView?
    private var statusLabel: UILabel?
    private var isVisible = false
    private let hudSize: CGFloat = 56

    private override init() {
        super.init()
    }

    func setup() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(recordingStateChanged),
            name: NSNotification.Name("recording-did-start"),
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(recordingStateChanged),
            name: NSNotification.Name("recording-did-stop"),
            object: nil
        )
    }

    func show() {
        guard !isVisible else { return }
        isVisible = true

        let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
        let window = UIWindow(windowScene: scene!)
        window.windowLevel = .alert + 1
        window.backgroundColor = .clear
        window.frame = CGRect(
            x: UIScreen.main.bounds.width - hudSize - 16,
            y: UIScreen.main.bounds.height / 2,
            width: hudSize,
            height: hudSize
        )
        window.isUserInteractionEnabled = true

        let view = UIView(frame: window.bounds)
        view.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.85)
        view.layer.cornerRadius = hudSize / 2
        view.layer.shadowColor = UIColor.black.cgColor
        view.layer.shadowOffset = CGSize(width: 0, height: 2)
        view.layer.shadowRadius = 4
        view.layer.shadowOpacity = 0.3
        view.clipsToBounds = false

        // 状态图标
        let label = UILabel(frame: view.bounds)
        label.text = "●"
        label.textColor = .white
        label.textAlignment = .center
        label.font = .systemFont(ofSize: 20, weight: .bold)
        view.addSubview(label)
        statusLabel = label

        // 手势
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        view.addGestureRecognizer(pan)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        view.addGestureRecognizer(tap)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap))
        doubleTap.numberOfTapsRequired = 2
        view.addGestureRecognizer(doubleTap)
        tap.require(toFail: doubleTap)

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress))
        view.addGestureRecognizer(longPress)

        window.addSubview(view)
        window.makeKeyAndVisible()

        hudWindow = window
        hudView = view

        updateRecordingState()
    }

    func hide() {
        hudWindow?.isHidden = true
        hudWindow = nil
        hudView = nil
        statusLabel = nil
        isVisible = false
    }

    // MARK: - 手势
    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard let window = hudWindow else { return }
        let translation = gesture.translation(in: window)
        window.center = CGPoint(
            x: window.center.x + translation.x,
            y: window.center.y + translation.y
        )
        gesture.setTranslation(.zero, in: window)

        if gesture.state == .ended {
            snapToEdge()
        }
    }

    private func snapToEdge() {
        guard let window = hudWindow else { return }
        let screenWidth = UIScreen.main.bounds.width
        let center = window.center
        let targetX: CGFloat

        if center.x > screenWidth / 2 {
            targetX = screenWidth - hudSize / 2 - 16
        } else {
            targetX = hudSize / 2 + 16
        }

        UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.7, initialSpringVelocity: 0) {
            window.center = CGPoint(x: targetX, y: window.center.y)
        }
    }

    @objc private func handleTap() {
        if TRAudioRecorder.shared.isRecording {
            TRAudioRecorder.shared.stopRecording()
        } else {
            // 开始语音备忘录录音
            try? TRVoiceMemoManager.shared.startRecording()
        }
        updateRecordingState()
    }

    @objc private func handleDoubleTap() {
        // 打开主应用
        if let url = URL(string: "trapp://") {
            UIApplication.shared.open(url)
        }
    }

    @objc private func handleLongPress() {
        // 显示快捷菜单
        let alert = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: "开始系统音频录制", style: .default) { _ in
            try? TRAudioRecorder.shared.startSystemAudioRecording()
            self.updateRecordingState()
        })
        alert.addAction(UIAlertAction(title: "打开应用", style: .default) { _ in
            if let url = URL(string: "trapp://") {
                UIApplication.shared.open(url)
            }
        })
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        hudWindow?.rootViewController?.present(alert, animated: true)
    }

    @objc private func recordingStateChanged() {
        updateRecordingState()
    }

    private func updateRecordingState() {
        if TRAudioRecorder.shared.isRecording {
            statusLabel?.text = "⬤"
            statusLabel?.textColor = .red
            // 脉冲动画
            UIView.animate(withDuration: 0.5, delay: 0, options: [.autoreverse, .repeat]) {
                self.statusLabel?.alpha = 0.5
            }
        } else {
            statusLabel?.text = "●"
            statusLabel?.textColor = .white
            statusLabel?.layer.removeAllAnimations()
            statusLabel?.alpha = 1.0
        }
    }
}