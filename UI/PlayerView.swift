import SwiftUI
import AVFoundation

/// 播放器视图
struct PlayerView: View {
    let recording: RecordingEntity

    @State private var isPlaying = false
    @State private var currentTime: TimeInterval = 0
    @State private var duration: TimeInterval = 0
    @State private var speed: TRAudioPlayer.PlaybackSpeed = .normal
    @State private var waveformSamples: [Float] = []
    @State private var showDeleteAlert = false
    @Environment(\.dismiss) private var dismiss

    private let player = TRAudioPlayer.shared

    var body: some View {
        NavigationView {
            VStack(spacing: 24) {
                // 标题
                VStack(spacing: 4) {
                    Text(recording.contactName ?? recording.phoneNumber ?? recording.fileName ?? "未知")
                        .font(.title2)
                        .fontWeight(.bold)
                    if let date = recording.createdAt {
                        Text(formatFullDate(date))
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.top)

                // 波形图
                WaveformView(samples: waveformSamples, currentProgress: duration > 0 ? currentTime / duration : 0)
                    .frame(height: 80)
                    .padding(.horizontal)

                // 进度条
                VStack(spacing: 4) {
                    Slider(value: $currentTime, in: 0...max(duration, 0.01)) { editing in
                        if !editing {
                            player.seek(to: currentTime)
                        }
                    }
                    HStack {
                        Text(formatTime(currentTime))
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(formatTime(duration))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal)

                // 播放控制
                HStack(spacing: 32) {
                    Button(action: {
                        player.skipBackward(15)
                    }) {
                        Image(systemName: "gobackward.15")
                            .font(.title2)
                    }

                    Button(action: {
                        player.skipBackward(5)
                    }) {
                        Image(systemName: "gobackward.5")
                            .font(.title2)
                    }

                    Button(action: togglePlayback) {
                        Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 56))
                            .foregroundColor(.blue)
                    }

                    Button(action: {
                        player.skipForward(5)
                    }) {
                        Image(systemName: "goforward.5")
                            .font(.title2)
                    }

                    Button(action: {
                        player.skipForward(15)
                    }) {
                        Image(systemName: "goforward.15")
                            .font(.title2)
                    }
                }

                // 速度选择
                HStack(spacing: 12) {
                    ForEach(TRAudioPlayer.PlaybackSpeed.allCases, id: \.rawValue) { s in
                        Button(action: {
                            speed = s
                            player.setSpeed(s)
                        }) {
                            Text(s.label)
                                .font(.caption)
                                .fontWeight(speed == s ? .bold : .regular)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(speed == s ? Color.blue.opacity(0.12) : Color.clear)
                                .foregroundColor(speed == s ? .blue : .primary)
                                .cornerRadius(8)
                        }
                    }
                }

                // 底部操作
                HStack(spacing: 40) {
                    Button(action: {
                        RecordingRepository.shared.toggleFavorite(recording)
                    }) {
                        Image(systemName: recording.isFavorite ? "star.fill" : "star")
                            .font(.title3)
                            .foregroundColor(recording.isFavorite ? .yellow : .secondary)
                    }

                    Button(action: {
                        shareRecording()
                    }) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.title3)
                    }

                    Button(action: {
                        playLooped()
                    }) {
                        Image(systemName: player.isLooping ? "repeat.1" : "repeat")
                            .font(.title3)
                            .foregroundColor(player.isLooping ? .blue : .secondary)
                    }

                    Button(action: { showDeleteAlert = true }) {
                        Image(systemName: "trash")
                            .font(.title3)
                            .foregroundColor(.red)
                    }
                }

                Spacer()

                // 信息
                if let notes = recording.notes, !notes.isEmpty {
                    Text(notes)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.horizontal)
                }
            }
            .navigationTitle("播放")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("完成") { dismiss() }
                }
            }
            .onAppear {
                loadAndPlay()
            }
            .onDisappear {
                player.stop()
            }
            .onChange(of: player.state) { newState in
                isPlaying = newState == .playing
            }
            .alert("确认删除", isPresented: $showDeleteAlert) {
                Button("取消", role: .cancel) {}
                Button("删除", role: .destructive) {
                    RecordingRepository.shared.delete(recording)
                    player.stop()
                    dismiss()
                }
            } message: {
                Text("此录音将被永久删除，无法恢复。")
            }
        }
    }

    private func loadAndPlay() {
        guard let path = recording.filePath else { return }
        let url = URL(fileURLWithPath: path)
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: path) {
            waveformSamples = player.generateWaveformSamples(url: url)
            player.onProgressUpdate = { time, dur in
                currentTime = time
                duration = dur
            }
            player.onStateChange = { state in
                isPlaying = state == .playing
            }
            player.onPlaybackComplete = {
                isPlaying = false
                currentTime = 0
            }
            try? player.play(url: url)
            isPlaying = true
            duration = player.duration
        }
    }

    private func togglePlayback() {
        if isPlaying {
            player.pause()
        } else {
            if player.state == .paused {
                player.resume()
            } else {
                loadAndPlay()
            }
        }
    }

    private func playLooped() {
        player.toggleLoop()
    }

    private func shareRecording() {
        guard let path = recording.filePath else { return }
        let url = URL(fileURLWithPath: path)
        let activityVC = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let rootVC = windowScene.windows.first?.rootViewController {
            rootVC.present(activityVC, animated: true)
        }
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return String(format: "%d:%02d", m, s)
    }

    private func formatFullDate(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return fmt.string(from: date)
    }
}

/// 波形图视图
struct WaveformView: View {
    let samples: [Float]
    let currentProgress: Double

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 1) {
                ForEach(0..<samples.count, id: \.self) { index in
                    let progress = Double(index) / Double(max(samples.count - 1, 1))
                    let isPlayed = progress <= currentProgress
                    RoundedRectangle(cornerRadius: 1)
                        .fill(isPlayed ? Color.blue : Color(.systemGray4))
                        .frame(width: max(1, geometry.size.width / CGFloat(samples.count) - 1))
                        .frame(height: max(2, CGFloat(samples[index]) * geometry.size.height))
                }
            }
            .frame(maxHeight: .infinity, alignment: .center)
        }
    }
}