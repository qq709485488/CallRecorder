import Foundation
import CoreData

/// CoreData 模型定义（需要在 Xcode 中创建 .xcdatamodeld 文件，这里提供实体定义）
/// 实体名称：RecordingEntity

@objc(RecordingEntity)
public class RecordingEntity: NSManagedObject {}

extension RecordingEntity {
    @NSManaged public var id: UUID?
    @NSManaged public var fileName: String?
    @NSManaged public var filePath: String?
    @NSManaged public var fileSize: Int64
    @NSManaged public var duration: Double
    @NSManaged public var format: String?
    @NSManaged public var sampleRate: Double
    @NSManaged public var callDirection: String?
    @NSManaged public var phoneNumber: String?
    @NSManaged public var contactName: String?
    @NSManaged public var isSystemAudio: Bool
    @NSManaged public var isFavorite: Bool
    @NSManaged public var isArchived: Bool
    @NSManaged public var isUploadedToCloud: Bool
    @NSManaged public var hasTranscript: Bool
    @NSManaged public var transcript: String?
    @NSManaged public var tags: [String]?
    @NSManaged public var notes: String?
    @NSManaged public var location: String?
    @NSManaged public var createdAt: Date?
    @NSManaged public var updatedAt: Date?
}

extension RecordingEntity: Identifiable {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<RecordingEntity> {
        return NSFetchRequest<RecordingEntity>(entityName: "RecordingEntity")
    }
}