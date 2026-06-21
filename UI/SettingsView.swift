import SwiftUI

/// 设置视图
struct SettingsView: View {
    @AppStorage("autoRecordEnabled") private var autoRecord = true
    @AppStorage("filterMode") private var filterMode = TRCallMonitor.RecordFilterMode.all.rawValue
    @AppStorage("audioFormat") private var audioFormat = TRAudioRecorder.AudioFormat.m4a.rawValue
    @AppStorage("sampleRate") private var sampleRate = 44100.0
    @AppStorage("bitRate") private var bitRate = 128000
    @AppStorage("showFloatingHUD") private var showHUD = true
    @AppStorage("silentAudioKeepAlive") private var silentAudioKeepAlive = true
    @AppStorage("locationKeepAlive") private var locationKeepAlive = false
    @AppStorage("autoBackup") private var autoBackup = true
    @AppStorage("faceIDLock") private var faceIDLock = false
    @AppStorage("darkMode") private var darkMode = false

    @State private var showClearAlert = false

    var body: some View {
        List {
            // 通话录音
            Section("通话录音") {
                Toggle("自动录音", isOn: $autoRecord)
                    .onChange(of: autoRecord) { newValue in
                        TRCallMonitor.shared.setAutoRecord(newValue)
                    }

                Picker("录音过滤", selection: $filterMode) {
                    Text("全部").tag(TRCallMonitor.RecordFilterMode.all.rawValue)
                    Text("仅来电").tag(TRCallMonitor.RecordFilterMode.incomingOnly.rawValue)
                    Text("仅去电").tag(TRCallMonitor.RecordFilterMode.outgoingOnly.rawValue)
                    Text("白名单").tag(TRCallMonitor.RecordFilterMode.whitelistOnly.rawValue)
                    Text("黑名单排除").tag(TRCallMonitor.RecordFilterMode.blacklistExclude.rawValue)
                }
                .onChange(of: filterMode) { newValue in
                    let mode = TRCallMonitor.RecordFilterMode(rawValue: newValue) ?? .all
                    TRCallMonitor.shared.setFilterMode(mode)
                }
            }

            // 音频设置
            Section("音频设置") {
                Picker("音频格式", selection: $audioFormat) {
                    Text("M4A (推荐)").tag(TRAudioRecorder.AudioFormat.m4a.rawValue)
                    Text("WAV (无损)").tag(TRAudioRecorder.AudioFormat.wav.rawValue)
                    Text("MP3").tag(TRAudioRecorder.AudioFormat.mp3.rawValue)
                }
                .onChange(of: audioFormat) { newValue in
                    TRAudioRecorder.shared.config.format = TRAudioRecorder.AudioFormat(rawValue: newValue) ?? .m4a
                }

                HStack {
                    Text("采样率")
                    Spacer()
                    Text("\(Int(sampleRate)) Hz")
                        .foregroundColor(.secondary)
                }

                Slider(value: $sampleRate, in: 8000...48000, step: 8000) { editing in
                    if !editing {
                        TRAudioRecorder.shared.config.sampleRate = sampleRate
                    }
                }

                Picker("比特率", selection: $bitRate) {
                    Text("64 kbps").tag(64000)
                    Text("128 kbps").tag(128000)
                    Text("192 kbps").tag(192000)
                    Text("256 kbps").tag(256000)
                }
                .onChange(of: bitRate) { newValue in
                    TRAudioRecorder.shared.config.bitRate = newValue
                }
            }

            // 后台保活
            Section {
                Toggle("悬浮球", isOn: $showHUD)
                    .onChange(of: showHUD) { newValue in
                        if newValue {
                            TRFloatingHUD.shared.show()
                        } else {
                            TRFloatingHUD.shared.hide()
                        }
                    }

                Toggle("静音音频保活（推荐）", isOn: $silentAudioKeepAlive)

                Toggle("定位保活", isOn: $locationKeepAlive)
                    .onChange(of: locationKeepAlive) { newValue in
                        if newValue {
                            TRBackgroundTaskManager.shared.startLocationKeepAlive()
                        } else {
                            TRBackgroundTaskManager.shared.stopLocationKeepAlive()
                        }
                    }
            } header: {
                Text("后台保活")
            } footer: {
                Text("静音音频保活是最可靠的后台保持方式，不影响系统性能。定位保活会增加电量消耗。")
            }

            // 存储
            Section("存储与备份") {
                Toggle("自动备份到 iCloud", isOn: $autoBackup)

                HStack {
                    Text("本地录音文件")
                    Spacer()
                    Text(calculateStorageUsed())
                        .foregroundColor(.secondary)
                }

                Button("清除所有录音", role: .destructive) {
                    showClearAlert = true
                }
            }

            // 隐私
            Section("隐私") {
                Toggle("面容 ID 锁", isOn: $faceIDLock)

                NavigationLink("白名单管理") {
                    Text("白名单管理 - 开发中")
                }
                NavigationLink("黑名单管理") {
                    Text("黑名单管理 - 开发中")
                }
            }

            // 设置
            Section("关于") {
                HStack {
                    Text("版本")
                    Spacer()
                    Text("2.14 (Build 542)")
                        .foregroundColor(.secondary)
                }

                HStack {
                    Text("应用标识")
                    Spacer()
                    Text("wiki.qaq.trapp")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                HStack {
                    Text("状态")
                    Spacer()
                    Text("全功能已激活")
                        .foregroundColor(.green)
                }
            }
        }
        .navigationTitle("设置")
        .alert("确认清除", isPresented: $showClearAlert) {
            Button("取消", role: .cancel) {}
            Button("清除", role: .destructive) {
                clearAllRecordings()
            }
        } message: {
            Text("将永久删除所有录音文件，无法恢复。")
        }
    }

    private func calculateStorageUsed() -> String {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let recordingsDir = docs.appendingPathComponent("Recordings")
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: recordingsDir, includingPropertiesForKeys: [.fileSizeKey]
        ) else { return "0 MB" }

        let totalSize = files.compactMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize }.reduce(0, +)
        return ByteCountFormatter().string(fromByteCount: Int64(totalSize))
    }

    private func clearAllRecordings() {
        let repo = RecordingRepository.shared
        for recording in repo.fetchAll() {
            repo.delete(recording)
        }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let recordingsDir = docs.appendingPathComponent("Recordings")
        try? FileManager.default.removeItem(at: recordingsDir)
        try? FileManager.default.createDirectory(at: recordingsDir, withIntermediateDirectories: true)
    }
}