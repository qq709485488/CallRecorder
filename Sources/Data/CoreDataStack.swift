import CoreData
import UIKit

/// CoreData 栈
final class CoreDataStack {
    static let shared = CoreDataStack()

    private let modelName = "CallRecorder"

    private init() {}

    lazy var persistentContainer: NSPersistentContainer = {
        let container = NSPersistentContainer(name: modelName)
        container.loadPersistentStores { _, error in
            if let error = error {
                fatalError("[TRApp] CoreData 加载失败: \(error)")
            }
        }
        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        return container
    }()

    var viewContext: NSManagedObjectContext {
        persistentContainer.viewContext
    }

    func saveContext() {
        let context = viewContext
        guard context.hasChanges else { return }
        do {
            try context.save()
        } catch {
            print("[TRApp] CoreData 保存失败: \(error)")
        }
    }

    func backgroundContext() -> NSManagedObjectContext {
        persistentContainer.newBackgroundContext()
    }
}