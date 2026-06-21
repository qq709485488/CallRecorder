import Foundation

/// 语音备忘录管理器
final class TRVoiceMemoManager {
    static let shared = TRVoiceMemoManager()

    struct VoiceMemo {
        let id: UUID
        let url: URL
        let title: String
        let createdAt: Date
        let duration: TimeInterval
        let fileSize: Int64
        var isFavorite: Bool
        var tags: [String]
        var notes: String?
    }

    private(set) var memos: [VoiceMemo] = []
    private let fileManager = FileManager.default

    private init() {
        loadMemos()
    }

    func startRecording() throws {
        let info = try TRAudioRecorder.shared.startSystemAudioRecording()
        let memo = VoiceMemo(
            id: UUID(),
            url: info.url,
            title: "语音备忘录 \(DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .short))",
            createdAt: info.startTime,
            duration: 0,
            fileSize: 0,
            isFavorite: false,
            tags: [],
            notes: nil
        )
        memos.append(memo)
    }

    func stopRecording() {
        TRAudioRecorder.shared.stopRecording()
        saveMemos()
    }

    func deleteMemo(_ memo: VoiceMemo) {
        try? fileManager.removeItem(at: memo.url)
        memos.removeAll { $0.id == memo.id }
        saveMemos()
    }

    func renameMemo(_ memo: VoiceMemo, title: String) {
        if let idx = memos.firstIndex(where: { $0.id == memo.id }) {
            memos[idx] = VoiceMemo(
                id: memo.id, url: memo.url, title: title,
                createdAt: memo.createdAt, duration: memo.duration,
                fileSize: memo.fileSize, isFavorite: memo.isFavorite,
                tags: memo.tags, notes: memo.notes
            )
        }
    }

    func toggleFavorite(_ memo: VoiceMemo) {
        if let idx = memos.firstIndex(where: { $0.id == memo.id }) {
            memos[idx] = VoiceMemo(
                id: memo.id, url: memo.url, title: memo.title,
                createdAt: memo.createdAt, duration: memo.duration,
                fileSize: memo.fileSize, isFavorite: !memo.isFavorite,
                tags: memo.tags, notes: memo.notes
            )
        }
    }

    func search(_ query: String) -> [VoiceMemo] {
        guard !query.isEmpty else { return memos }
        return memos.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    private func loadMemos() {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        let voiceMemosDir = docs.appendingPathComponent("VoiceMemos")
        try? fileManager.createDirectory(at: voiceMemosDir, withIntermediateDirectories: true)

        guard let files = try? fileManager.contentsOfDirectory(
            at: voiceMemosDir,
            includingPropertiesForKeys: [.fileSizeKey, .creationDateKey]
        ) else { return }

        memos = files.compactMap { url in
            guard let attrs = try? fileManager.attributesOfItem(atPath: url.path),
                  let date = attrs[.creationDate] as? Date else { return nil }
            return VoiceMemo(
                id: UUID(), url: url,
                title: url.deletingPathExtension().lastPathComponent,
                createdAt: date, duration: 0,
                fileSize: (attrs[.size] as? Int64) ?? 0,
                isFavorite: false, tags: [], notes: nil
            )
        }
    }

    private func saveMemos() {
        UserDefaults.standard.set(memos.count, forKey: "voiceMemoCount")
    }
}