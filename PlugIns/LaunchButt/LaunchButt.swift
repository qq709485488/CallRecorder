import Foundation
import AppIntents

/// LaunchButt - 快捷启动扩展 (App Intent Extension)
/// 提供 Siri 快捷指令集成

@available(iOS 16.0, *)
struct ToggleVoiceMemoIntent: AppIntent {
    static var title: LocalizedStringResource = "Toggle Voice Memo Recording"
    
    func perform() async throws -> some IntentResult {
        // 通过 Darwin Notification 通知主应用
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterPostNotification(center, CFNotificationName("wiki.qaq.trapp.toggle-voice-memo" as CFString), nil, nil, true)
        return .result()
    }
}

@available(iOS 16.0, *)
struct ToggleCallRecordingIntent: AppIntent {
    static var title: LocalizedStringResource = "Toggle Call Recording"
    
    func perform() async throws -> some IntentResult {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterPostNotification(center, CFNotificationName("wiki.qaq.trapp.toggle-call-recording" as CFString), nil, nil, true)
        return .result()
    }
}

@available(iOS 16.0, *)
struct LaunchButtShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ToggleVoiceMemoIntent(),
            phrases: ["Toggle voice memo in \(.applicationName)"],
            shortTitle: "Toggle Voice Memo",
            systemImageName: "mic.fill.badge.plus"
        )
        AppShortcut(
            intent: ToggleCallRecordingIntent(),
            phrases: ["Toggle call recording in \(.applicationName)"],
            shortTitle: "Toggle Call Recording",
            systemImageName: "phone.fill.badge.plus"
        )
    }
}