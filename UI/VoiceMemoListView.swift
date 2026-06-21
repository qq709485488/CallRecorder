import SwiftUI

/// 语音备忘录列表
struct VoiceMemoListView: View {
    @State private var memos: [TRVoiceMemoManager.VoiceMemo] = []
    @State private var isRecording = false
    @State private var searchText = ""

    var filteredMemos: [TRVoiceMemoManager.VoiceMemo] {
        if searchText.isEmpty { return memos }
        return memos.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        VStack(spacing: 0) {
            // 录音按钮
            VStack(spacing: 8) {
                Button(action: {
                    if isRecording {
                        TRVoiceMemoManager.shared.stopRecording()
                    } else {
                        try? TRVoiceMemoManager.shared.startRecording()
                    }
                    isRecording.toggle()
                }) {
                    ZStack {
                        Circle()
                            .fill(isRecording ? Color.red : Color.blue)
                            .frame(width: 64, height: 64)
                        if isRecording {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(.white)
                                .frame(width: 20, height: 20)
                        } else {
                            Image(systemName: "mic.fill")
                                .font(.title2)
                                .foregroundColor(.white)
                        }
                    }
                }
                Text(isRecording ? "点击停止" : "点击开始录音")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 16)

            if filteredMemos.isEmpty {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "mic.slash")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary)
                    Text("暂无语音备忘录")
                        .font(.headline)
                        .foregroundColor(.secondary)
                }
                Spacer()
            } else {
                List {
                    ForEach(filteredMemos, id: \.id) { memo in
                        VoiceMemoRow(memo: memo)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    TRVoiceMemoManager.shared.deleteMemo(memo)
                                    memos = TRVoiceMemoManager.shared.memos
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                    }
                }
                .listStyle(.plain)
            }
        }
        .searchable(text: $searchText, prompt: "搜索备忘录")
        .navigationTitle("语音备忘录")
        .onAppear {
            memos = TRVoiceMemoManager.shared.memos
        }
    }
}

struct VoiceMemoRow: View {
    let memo: TRVoiceMemoManager.VoiceMemo

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: memo.isFavorite ? "star.fill" : "waveform")
                .font(.title3)
                .foregroundColor(memo.isFavorite ? .yellow : .blue)
                .frame(width: 36, height: 36)
                .background(Color.blue.opacity(0.12))
                .cornerRadius(8)

            VStack(alignment: .leading, spacing: 4) {
                Text(memo.title)
                    .font(.body)
                    .fontWeight(.medium)
                HStack {
                    Text(formatDuration(memo.duration))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(formatFileSize(memo.fileSize))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(formatDate(memo.createdAt))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func formatDuration(_ seconds: Double) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return String(format: "%d:%02d", m, s)
    }

    private func formatFileSize(_ bytes: Int64) -> String {
        ByteCountFormatter().string(fromByteCount: bytes)
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