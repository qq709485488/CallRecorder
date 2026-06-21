import Foundation

/// 回收站 - 已删除录音恢复
class TRRecycleBin: ObservableObject {
    static let shared = TRRecycleBin()
    
    @Published var deletedItems: [TRRecycleBinItem] = []
    
    private let recycleDir: URL
    private let indexFile: URL
    
    init() {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        recycleDir = base.appendingPathComponent(".trash")
        indexFile = recycleDir.appendingPathComponent("index.json")
        try? FileManager.default.createDirectory(at: recycleDir, withIntermediateDirectories: true)
        loadIndex()
    }
    
    func moveToTrash(_ recording: TRRecording) {
        let fileName = recording.fileName
        let destURL = recycleDir.appendingPathComponent(fileName)
        
        do {
            let sourceURL = recording.fileURL
            try FileManager.default.moveItem(at: sourceURL, to: destURL)
            
            let item = TRRecycleBinItem(
                id: recording.id,
                fileName: fileName,
                originalPath: sourceURL.path,
                deletedAt: Date(),
                duration: recording.duration
            )
            deletedItems.append(item)
            saveIndex()
        } catch {
            print("Failed to move to trash: \(error)")
        }
    }
    
    func restore(_ item: TRRecycleBinItem) -> Bool {
        let sourceURL = recycleDir.appendingPathComponent(item.fileName)
        let destURL = URL(fileURLWithPath: item.originalPath)
        
        do {
            if FileManager.default.fileExists(atPath: destURL.path) {
                try FileManager.default.removeItem(at: destURL)
            }
            try FileManager.default.moveItem(at: sourceURL, to: destURL)
            deletedItems.removeAll { $0.id == item.id }
            saveIndex()
            return true
        } catch {
            print("Failed to restore: \(error)")
            return false
        }
    }
    
    func permanentlyDelete(_ item: TRRecycleBinItem) {
        let fileURL = recycleDir.appendingPathComponent(item.fileName)
        try? FileManager.default.removeItem(at: fileURL)
        deletedItems.removeAll { $0.id == item.id }
        saveIndex()
    }
    
    func emptyTrash() {
        for item in deletedItems {
            let fileURL = recycleDir.appendingPathComponent(item.fileName)
            try? FileManager.default.removeItem(at: fileURL)
        }
        deletedItems.removeAll()
        saveIndex()
    }
    
    func autoCleanup() {
        let cutoff = Date().addingTimeInterval(-30 * 24 * 3600) // 30 days
        let expired = deletedItems.filter { $0.deletedAt < cutoff }
        for item in expired {
            let fileURL = recycleDir.appendingPathComponent(item.fileName)
            try? FileManager.default.removeItem(at: fileURL)
        }
        deletedItems.removeAll { expired.contains($0) }
        saveIndex()
    }
    
    private func saveIndex() {
        if let data = try? JSONEncoder().encode(deletedItems) {
            try? data.write(to: indexFile)
        }
    }
    
    private func loadIndex() {
        if let data = try? Data(contentsOf: indexFile),
           let items = try? JSONDecoder().decode([TRRecycleBinItem].self, from: data) {
            deletedItems = items
        }
    }
}

struct TRRecycleBinItem: Identifiable, Codable, Equatable {
    let id: String
    let fileName: String
    let originalPath: String
    let deletedAt: Date
    let duration: Double
}