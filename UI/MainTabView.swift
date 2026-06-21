import SwiftUI

/// 主标签页视图
struct MainTabView: View {
    @State private var selectedTab = 0
    @StateObject private var appState = AppState.shared

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationView {
                RecordingsListView()
            }
            .tabItem {
                Image(systemName: "waveform")
                Text("录音")
            }
            .tag(0)

            NavigationView {
                VoiceMemoListView()
            }
            .tabItem {
                Image(systemName: "mic.badge.plus")
                Text("备忘录")
            }
            .tag(1)

            NavigationView {
                SettingsView()
            }
            .tabItem {
                Image(systemName: "gearshape")
                Text("设置")
            }
            .tag(2)
        }
        .accentColor(.blue)
        .onAppear {
            TRFloatingHUD.shared.show()
        }
    }
}

/// 应用全局状态
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var isRecording = false
    @Published var recordingDuration: TimeInterval = 0
    @Published var recordingAmplitude: Float = 0
    @Published var currentCall: TRCallMonitor.ActiveCall?
    @Published var isBackgroundActive = false

    private init() {
        setupObservers()
    }

    private func setupObservers() {
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("recording-did-start"), object: nil, queue: .main
        ) { [weak self] _ in
            self?.isRecording = true
        }
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("recording-did-stop"), object: nil, queue: .main
        ) { [weak self] _ in
            self?.isRecording = false
        }
    }
}