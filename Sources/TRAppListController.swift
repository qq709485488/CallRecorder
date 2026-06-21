import SwiftUI

/// 应用列表视图 - 用于管理录音应用设置
struct AppListController: View {
    @State private var selectedApps: [String] = []
    
    var body: some View {
        List {
            Section {
                ConfigurableBooleanView(
                    icon: "phone.fill",
                    title: "Phone",
                    description: "Record phone calls",
                    value: Binding(
                        get: { selectedApps.contains("com.apple.mobilephone") },
                        set: { if $0 { selectedApps.append("com.apple.mobilephone") } else { selectedApps.removeAll { $0 == "com.apple.mobilephone" } } }
                    )
                )
                
                ConfigurableBooleanView(
                    icon: "message.fill",
                    title: "Messages",
                    description: "Record voice messages",
                    value: Binding(
                        get: { selectedApps.contains("com.apple.MobileSMS") },
                        set: { if $0 { selectedApps.append("com.apple.MobileSMS") } else { selectedApps.removeAll { $0 == "com.apple.MobileSMS" } } }
                    )
                )
                
                ConfigurableBooleanView(
                    icon: "mic.fill",
                    title: "Voice Memos",
                    description: "Record voice memos",
                    value: Binding(
                        get: { selectedApps.contains("voice-memo") },
                        set: { if $0 { selectedApps.append("voice-memo") } else { selectedApps.removeAll { $0 == "voice-memo" } } }
                    )
                )
                
                ConfigurableBooleanView(
                    icon: "speaker.wave.3.fill",
                    title: "System Audio",
                    description: "Record system audio output",
                    value: Binding(
                        get: { selectedApps.contains("system-audio") },
                        set: { if $0 { selectedApps.append("system-audio") } else { selectedApps.removeAll { $0 == "system-audio" } } }
                    )
                )
            }
        }
        .navigationTitle("App Recording")
    }
}

/// 应用单元格视图
struct AppCellView: View {
    let appName: String
    let icon: String
    let isEnabled: Bool
    
    var body: some View {
        HStack {
            Image(systemName: icon)
                .font(.title2)
                .frame(width: 40)
                .foregroundColor(isEnabled ? .accentColor : .gray)
            
            Text(appName)
            
            Spacer()
            
            Image(systemName: isEnabled ? "checkmark.circle.fill" : "circle")
                .foregroundColor(isEnabled ? .green : .gray)
        }
        .padding(.vertical, 4)
    }
}

/// 应用列表视图组件
struct AppListView: View {
    let apps: [(name: String, icon: String, enabled: Bool)]
    
    var body: some View {
        ForEach(apps, id: \.name) { app in
            AppCellView(appName: app.name, icon: app.icon, isEnabled: app.enabled)
        }
    }
}