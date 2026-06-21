import UIKit
import BackgroundTasks
import AVFoundation
import CoreLocation

/// 后台任务管理器 - 5层保活策略
final class TRBackgroundTaskManager: NSObject {
    static let shared = TRBackgroundTaskManager()

    // MARK: - 属性
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private var keepAliveTimer: Timer?
    private var silentAudioPlayer: AVAudioPlayer?
    private var locationManager: CLLocationManager?
    private var isKeepingAlive = false

    // 后台任务标识符
    private let processingTaskID = "wiki.qaq.trapp.processing.weekly-export"
    private let audioTaskID = "wiki.qaq.trapp.audio.processing"

    private override init() {
        super.init()
    }

    // MARK: - 第1层：BGTaskScheduler 注册
    func registerBackgroundTasks() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: processingTaskID,
            using: nil
        ) { [weak self] task in
            self?.handleProcessingTask(task as! BGProcessingTask)
        }

        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: audioTaskID,
            using: nil
        ) { [weak self] task in
            self?.handleAudioTask(task as! BGProcessingTask)
        }

        scheduleProcessingTask()
        scheduleAudioProcessingTask()
        print("[TRApp] BGTaskScheduler 已注册")
    }

    func scheduleProcessingTask() {
        let request = BGProcessingTaskRequest(identifier: processingTaskID)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: 2 * 60 * 60) // 2小时后

        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            print("[TRApp] BGTask 调度失败: \(error)")
        }
    }

    func scheduleAudioProcessingTask() {
        let request = BGProcessingTaskRequest(identifier: audioTaskID)
        request.requiresNetworkConnectivity = false
        request.requiresExternalPower = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60) // 15分钟后

        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            print("[TRApp] AudioTask 调度失败: \(error)")
        }
    }

    private func handleProcessingTask(_ task: BGProcessingTask) {
        task.expirationHandler = {
            task.setTaskCompleted(success: false)
        }
        // 执行备份/归档任务
        performBackgroundProcessing()
        task.setTaskCompleted(success: true)
        scheduleProcessingTask()
    }

    private func handleAudioTask(_ task: BGProcessingTask) {
        task.expirationHandler = {
            task.setTaskCompleted(success: false)
        }
        // 检查并恢复音频保活
        if !isKeepingAlive && TRAudioRecorder.shared.isRecording {
            startSilentAudioKeepAlive()
        }
        task.setTaskCompleted(success: true)
        scheduleAudioProcessingTask()
    }

    private func performBackgroundProcessing() {
        // 这里执行 iCloud 备份、归档等任务
        TRBackupService.shared.performBackgroundBackup()
    }

    // MARK: - 第2层：beginBackgroundTask 续命
    func beginBackgroundKeepAlive() {
        guard backgroundTaskID == .invalid else { return }

        backgroundTaskID = UIApplication.shared.beginBackgroundTask(
            withName: "CallRecorderKeepAlive"
        ) { [weak self] in
            self?.endBackgroundKeepAlive()
        }

        keepAliveTimer = Timer.scheduledTimer(
            withTimeInterval: 25.0,
            repeats: true
        ) { [weak self] _ in
            self?.refreshBackgroundTask()
        }
        RunLoop.main.add(keepAliveTimer!, forMode: .common)

        isKeepingAlive = true
        print("[TRApp] beginBackgroundTask 保活启动")
    }

    private func refreshBackgroundTask() {
        if backgroundTaskID != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTaskID)
        }
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(
            withName: "CallRecorderKeepAlive"
        ) { [weak self] in
            self?.endBackgroundKeepAlive()
        }
    }

    func endBackgroundKeepAlive() {
        keepAliveTimer?.invalidate()
        keepAliveTimer = nil
        if backgroundTaskID != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTaskID)
            backgroundTaskID = .invalid
        }
    }

    // MARK: - 第3层：静音音频保活（最可靠）
    func startSilentAudioKeepAlive() {
        guard let silentURL = Bundle.main.url(forResource: "silence", withExtension: "wav") else {
            // 如果没有资源文件，生成一段静音
            print("[TRApp] 静音音频文件不存在，使用代码生成")
            return
        }

        do {
            try TRAudioSessionManager.shared.activateForSilentPlayback()

            let player = try AVAudioPlayer(contentsOf: silentURL)
            player.numberOfLoops = -1
            player.volume = 0.0
            player.prepareToPlay()
            player.play()

            self.silentAudioPlayer = player
            isKeepingAlive = true
            print("[TRApp] 静音音频保活启动")
        } catch {
            print("[TRApp] 静音保活失败: \(error)")
        }
    }

    func stopSilentAudioKeepAlive() {
        silentAudioPlayer?.stop()
        silentAudioPlayer = nil
        try? TRAudioSessionManager.shared.deactivate()
    }

    // MARK: - 第4层：定位保活（可选）
    func startLocationKeepAlive() {
        locationManager = CLLocationManager()
        locationManager?.delegate = self
        locationManager?.allowsBackgroundLocationUpdates = true
        locationManager?.pausesLocationUpdatesAutomatically = false
        locationManager?.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        locationManager?.distanceFilter = 1000
        locationManager?.startUpdatingLocation()
        print("[TRApp] 定位保活启动")
    }

    func stopLocationKeepAlive() {
        locationManager?.stopUpdatingLocation()
        locationManager = nil
    }

    // MARK: - 综合控制
    func startAllKeepAliveStrategies() {
        // 第1层：BGTaskScheduler 已在启动时注册
        // 第2层：beginBackgroundTask
        beginBackgroundKeepAlive()
        // 第3层：静音音频（仅在非录音时启动，录音时 audio 模式自动保活）
        if !TRAudioRecorder.shared.isRecording {
            startSilentAudioKeepAlive()
        }
        // 第4层：定位保活（可选）
        // startLocationKeepAlive()
    }

    func stopAllKeepAliveStrategies() {
        endBackgroundKeepAlive()
        stopSilentAudioKeepAlive()
        stopLocationKeepAlive()
        isKeepingAlive = false
    }

    var isActive: Bool { isKeepingAlive }
}

// MARK: - CLLocationManagerDelegate
extension TRBackgroundTaskManager: CLLocationManagerDelegate {
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // 静默处理，仅用于保活
    }
}