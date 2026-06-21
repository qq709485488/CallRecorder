import UIKit
import BackgroundTasks
import CoreData

@main
class AppDelegate: UIResponder, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        // 初始化所有核心服务
        TRNotificationCenter.shared.setup()
        TRAudioSessionManager.shared.setup()
        TRBackgroundTaskManager.shared.registerBackgroundTasks()
        TRCallMonitor.shared.startMonitoring()
        TRFloatingHUD.shared.setup()

        print("[TRApp] 纯净版启动完成，全功能已激活")
        return true
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        // 进入后台时启动保活策略
        TRBackgroundTaskManager.shared.startAllKeepAliveStrategies()
        TRNotificationCenter.shared.post(name: "daemon.launched")
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        // 回到前台时停止部分保活策略
        TRBackgroundTaskManager.shared.stopSilentAudioKeepAlive()
    }

    func applicationWillTerminate(_ application: UIApplication) {
        TRBackgroundTaskManager.shared.stopAllKeepAliveStrategies()
        TRCallMonitor.shared.stopMonitoring()
        CoreDataStack.shared.saveContext()
    }

    // MARK: - UISceneSession
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        return UISceneConfiguration(
            name: "Default Configuration",
            sessionRole: connectingSceneSession.role
        )
    }
}