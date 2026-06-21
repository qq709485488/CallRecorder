import Foundation

/// 录音记录模型 - 用于新模块之间传递录音数据
struct TRRecording: Identifiable, Codable {
    let id: String
    let fileName: String
    let fileURL: URL
    let fileSize: Int64
    let duration: Double
    let format: String
    let sampleRate: Double
    let callDirection: String
    let phoneNumber: String
    let contactName: String?
    let isSystemAudio: Bool
    let isFavorite: Bool
    let hasTranscript: Bool
    let transcript: String?
    let location: String?
    let createdAt: Date
    
    init(id: String = UUID().uuidString,
         fileName: String,
         fileURL: URL,
         fileSize: Int64 = 0,
         duration: Double = 0,
         format: String = "m4a",
         sampleRate: Double = 44100,
         callDirection: String = "unknown",
         phoneNumber: String = "",
         contactName: String? = nil,
         isSystemAudio: Bool = false,
         isFavorite: Bool = false,
         hasTranscript: Bool = false,
         transcript: String? = nil,
         location: String? = nil,
         createdAt: Date = Date()) {
        self.id = id
        self.fileName = fileName
        self.fileURL = fileURL
        self.fileSize = fileSize
        self.duration = duration
        self.format = format
        self.sampleRate = sampleRate
        self.callDirection = callDirection
        self.phoneNumber = phoneNumber
        self.contactName = contactName
        self.isSystemAudio = isSystemAudio
        self.isFavorite = isFavorite
        self.hasTranscript = hasTranscript
        self.transcript = transcript
        self.location = location
        self.createdAt = createdAt
    }
    
    /// 从 RecordingEntity 转换
    init(from entity: RecordingEntity) {
        self.id = entity.id?.uuidString ?? UUID().uuidString
        self.fileName = entity.fileName ?? "unknown"
        self.fileURL = URL(fileURLWithPath: entity.filePath ?? "")
        self.fileSize = entity.fileSize
        self.duration = entity.duration
        self.format = entity.format ?? "m4a"
        self.sampleRate = entity.sampleRate
        self.callDirection = entity.callDirection ?? "unknown"
        self.phoneNumber = entity.phoneNumber ?? ""
        self.contactName = entity.contactName
        self.isSystemAudio = entity.isSystemAudio
        self.isFavorite = entity.isFavorite
        self.hasTranscript = entity.hasTranscript
        self.transcript = entity.transcript
        self.location = entity.location
        self.createdAt = entity.createdAt ?? Date()
    }
}