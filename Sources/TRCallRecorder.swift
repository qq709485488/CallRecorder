import Foundation

/// 通话录音管理器 - 管理通话录音记录与自动录音逻辑
final class TRCallRecorder: NSObject {
    static let shared = TRCallRecorder()

    struct CallRecording {
        let id: UUID
        let phoneNumber: String
        let contactName: String?
        let direction: TRCallMonitor.CallDirection
        let fileURL: URL
        let startTime: Date
        let duration: TimeInterval
        let fileSize: Int64
    }

    private(set) var recordings: [CallRecording] = []
    private var currentRecording: CallRecording?

    private let fileManager = FileManager.default

    private override init() {
        super.init()
        setupCallMonitorBinding()
        loadRecordings()
    }

    private func setupCallMonitorBinding() {
        TRCallMonitor.shared.onAutoRecordTriggered = { [weak self] call in
            self?.startRecording(for: call)
        }
        TRCallMonitor.shared.onCallEnded = { [weak self] call in
            self?.finalizeRecording(for: call)
        }
    }

    func startRecording(for call: TRCallMonitor.ActiveCall) {
        do {
            let info = try TRAudioRecorder.shared.startCallRecording(
                phoneNumber: call.phoneNumber,
                direction: call.direction
            )
            let recording = CallRecording(
                id: UUID(),
                phoneNumber: call.phoneNumber,
                contactName: call.contactName,
                direction: call.direction,
                fileURL: info.url,
                startTime: info.startTime,
                duration: 0,
                fileSize: 0
            )
            currentRecording = recording
            recordings.append(recording)
        } catch {
            print("[TRApp] 通话录音启动失败: \(error)")
        }
    }

    func finalizeRecording(for call: TRCallMonitor.ActiveCall) {
        TRAudioRecorder.shared.stopRecording()

        guard var recording = currentRecording else { return }
        if let attrs = try? fileManager.attributesOfItem(atPath: recording.fileURL.path) {
            recording = CallRecording(
                id: recording.id,
                phoneNumber: recording.phoneNumber,
                contactName: recording.contactName,
                direction: recording.direction,
                fileURL: recording.fileURL,
                startTime: recording.startTime,
                duration: TRAudioRecorder.shared.currentDuration,
                fileSize: (attrs[.size] as? Int64) ?? 0
            )
        }
        if let idx = recordings.firstIndex(where: { $0.id == recording.id }) {
            recordings[idx] = recording
        }
        currentRecording = nil
        saveRecordings()
    }

    func deleteRecording(_ recording: CallRecording) {
        try? fileManager.removeItem(at: recording.fileURL)
        recordings.removeAll { $0.id == recording.id }
        saveRecordings()
    }

    private func loadRecordings() {
        // 从本地文件系统加载已有的录音文件
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        let recordingsDir = docs.appendingPathComponent("Recordings")
        guard let files = try? fileManager.contentsOfDirectory(
            at: recordingsDir,
            includingPropertiesForKeys: [.fileSizeKey, .creationDateKey]
        ) else { return }

        // 重新构建录音列表
        recordings = files.compactMap { url in
            guard let attrs = try? fileManager.attributesOfItem(atPath: url.path) else { return nil }
            return CallRecording(
                id: UUID(),
                phoneNumber: "未知",
                contactName: nil,
                direction: .unknown,
                fileURL: url,
                startTime: attrs[.creationDate] as? Date ?? Date(),
                duration: 0,
                fileSize: (attrs[.size] as? Int64) ?? 0
            )
        }
    }

    private func saveRecordings() {
        // 录音文件已存储在文件系统中，这里可以保存元数据到 CoreData/UserDefaults
        UserDefaults.standard.set(recordings.count, forKey: "callRecordingCount")
    }
}