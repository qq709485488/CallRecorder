import SwiftUI
import AVFoundation

/// 录音列表视图
struct RecordingsListView: View {
    @State private var recordings: [RecordingEntity] = []
    @State private var searchText = ""
    @State private var selectedFilter: FilterType = .all
    @State private var showingPlayer = false
    @State private var selectedRecording: RecordingEntity?

    enum FilterType: String, CaseIterable {
        case all = "全部"
        case incoming = "来电"
        case outgoing = "去电"
        case system = "系统音频"
        case favorites = "收藏"
    }

    var filteredRecordings: [RecordingEntity] {
        var results = recordings
        if !searchText.isEmpty {
            results = RecordingRepository.shared.search(searchText)
        }
        switch selectedFilter {
        case .all: break
        case .incoming: results = results.filter { $0.callDirection == "incoming" }
        case .outgoing: results = results.filter { $0.callDirection == "outgoing" }
        case .system: results = results.filter { $0.isSystemAudio }
        case .favorites: results = results.filter { $0.isFavorite }
        }
        return results
    }

    var body: some View {
        VStack(spacing: 0) {
            // 过滤器
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(FilterType.allCases, id: \.self) { filter in
                        Button(action: { selectedFilter = filter }) {
                            Text(filter.rawValue)
                                .font(.subheadline)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(selectedFilter == filter ? Color.blue : Color(.systemGray5))
                                .foregroundColor(selectedFilter == filter ? .white : .primary)
                                .cornerRadius(16)
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }

            if filteredRecordings.isEmpty {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "waveform")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text("暂无录音")
                        .font(.headline)
                        .foregroundColor(.secondary)
                    Text("通话后将自动出现在这里")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                Spacer()
            } else {
                List {
                    ForEach(filteredRecordings, id: \.id) { recording in
                        RecordingRow(recording: recording)
                            .onTapGesture {
                                selectedRecording = recording
                                showingPlayer = true
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    RecordingRepository.shared.delete(recording)
                                    loadRecordings()
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                                Button {
                                    RecordingRepository.shared.toggleFavorite(recording)
                                    loadRecordings()
                                } label: {
                                    Label("收藏", systemImage: recording.isFavorite ? "star.slash" : "star")
                                }
                                .tint(.orange)
                            }
                    }
                }
                .listStyle(.plain)
            }
        }
        .searchable(text: $searchText, prompt: "搜索录音")
        .navigationTitle("录音")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack {
                    Button(action: { loadRecordings() }) {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
        }
        .onAppear { loadRecordings() }
        .sheet(isPresented: $showingPlayer) {
            if let rec = selectedRecording {
                PlayerView(recording: rec)
            }
        }
    }

    private func loadRecordings() {
        recordings = RecordingRepository.shared.fetchAll()
    }
}

/// 录音行
struct RecordingRow: View {
    let recording: RecordingEntity

    var body: some View {
        HStack(spacing: 12) {
            // 方向图标
            Image(systemName: directionIcon)
                .font(.title3)
                .foregroundColor(directionColor)
                .frame(width: 36, height: 36)
                .background(directionColor.opacity(0.12))
                .cornerRadius(8)

            VStack(alignment: .leading, spacing: 4) {
                Text(recording.contactName ?? recording.phoneNumber ?? recording.fileName ?? "未知")
                    .font(.body)
                    .fontWeight(.medium)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Text(formatDuration(recording.duration))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(formatFileSize(recording.fileSize))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    if let date = recording.createdAt {
                        Text(formatDate(date))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            Spacer()

            if recording.isFavorite {
                Image(systemName: "star.fill")
                    .font(.caption)
                    .foregroundColor(.yellow)
            }
        }
        .padding(.vertical, 4)
    }

    private var directionIcon: String {
        switch recording.callDirection {
        case "incoming": return "phone.down.fill"
        case "outgoing": return "phone.up.fill"
        default: return recording.isSystemAudio ? "speaker.wave.2" : "phone"
        }
    }

    private var directionColor: Color {
        switch recording.callDirection {
        case "incoming": return .green
        case "outgoing": return .blue
        default: return .gray
        }
    }

    private func formatDuration(_ seconds: Double) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return String(format: "%d:%02d", m, s)
    }

    private func formatFileSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        return formatter.string(fromByteCount: bytes)
    }

    private func formatDate(_ date: Date) -> String {
        let fmt = DateFormatter()
        if Calendar.current.isDateInToday(date) {
            fmt.dateFormat = "HH:mm"
        } else {
            fmt.dateFormat = "MM-dd HH:mm"
        }
        return fmt.string(from: date)
    }
}