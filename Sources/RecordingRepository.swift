import CoreData
import Foundation

/// 录音实体仓库
final class RecordingRepository {
    static let shared = RecordingRepository()

    private let context = CoreDataStack.shared.viewContext

    private init() {}

    func fetchAll() -> [RecordingEntity] {
        let request: NSFetchRequest<RecordingEntity> = RecordingEntity.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]
        return (try? context.fetch(request)) ?? []
    }

    func fetchFavorites() -> [RecordingEntity] {
        let request: NSFetchRequest<RecordingEntity> = RecordingEntity.fetchRequest()
        request.predicate = NSPredicate(format: "isFavorite == YES")
        request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]
        return (try? context.fetch(request)) ?? []
    }

    func search(_ query: String) -> [RecordingEntity] {
        let request: NSFetchRequest<RecordingEntity> = RecordingEntity.fetchRequest()
        request.predicate = NSPredicate(format: "fileName CONTAINS[cd] %@ OR phoneNumber CONTAINS[cd] %@ OR contactName CONTAINS[cd] %@", query, query, query)
        request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]
        return (try? context.fetch(request)) ?? []
    }

    func create(
        fileName: String,
        filePath: String,
        fileSize: Int64,
        duration: Double,
        format: String,
        callDirection: String?,
        phoneNumber: String?,
        contactName: String?,
        isSystemAudio: Bool
    ) -> RecordingEntity {
        let entity = RecordingEntity(context: context)
        entity.id = UUID()
        entity.fileName = fileName
        entity.filePath = filePath
        entity.fileSize = fileSize
        entity.duration = duration
        entity.format = format
        entity.callDirection = callDirection
        entity.phoneNumber = phoneNumber
        entity.contactName = contactName
        entity.isSystemAudio = isSystemAudio
        entity.isFavorite = false
        entity.isArchived = false
        entity.isUploadedToCloud = false
        entity.createdAt = Date()
        entity.updatedAt = Date()
        CoreDataStack.shared.saveContext()
        return entity
    }

    func delete(_ entity: RecordingEntity) {
        context.delete(entity)
        CoreDataStack.shared.saveContext()
    }

    func toggleFavorite(_ entity: RecordingEntity) {
        entity.isFavorite.toggle()
        CoreDataStack.shared.saveContext()
    }

    func updateNotes(_ entity: RecordingEntity, notes: String) {
        entity.notes = notes
        entity.updatedAt = Date()
        CoreDataStack.shared.saveContext()
    }
}