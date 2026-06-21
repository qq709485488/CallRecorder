import Foundation
import UIKit

/// iCloud 备份服务
final class TRBackupService {
    static let shared = TRBackupService()

    private let fileManager = FileManager.default
    private var isBackingUp = false

    var onBackupProgress: ((Double) -> Void)?
    var onBackupComplete: (() -> Void)?
    var onBackupError: ((Error) -> Void)?

    private init() {}

    func performBackgroundBackup() {
        guard !isBackingUp else { return }
        isBackingUp = true

        DispatchQueue.global(qos: .background).async { [weak self] in
            self?.backupRecordings()
            self?.isBackingUp = false
        }
    }

    private func backupRecordings() {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        let recordingsDir = docs.appendingPathComponent("Recordings")

        guard let files = try? fileManager.contentsOfDirectory(
            at: recordingsDir,
            includingPropertiesForKeys: [.fileSizeKey]
        ) else { return }

        let total = files.count
        for (index, file) in files.enumerated() {
            // 复制到 iCloud 容器
            if let iCloudURL = fileManager.url(forUbiquityContainerIdentifier: "iCloud.wiki.qaq.trapp") {
                let destURL = iCloudURL.appendingPathComponent("Recordings").appendingPathComponent(file.lastPathComponent)
                try? fileManager.createDirectory(at: destURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                if !fileManager.fileExists(atPath: destURL.path) {
                    try? fileManager.copyItem(at: file, to: destURL)
                }
            }
            DispatchQueue.main.async {
                self.onBackupProgress?(Double(index + 1) / Double(total))
            }
        }
        DispatchQueue.main.async {
            self.onBackupComplete?()
        }
    }

    func restoreFromCloud() async throws -> [URL] {
        guard let iCloudURL = fileManager.url(forUbiquityContainerIdentifier: "iCloud.wiki.qaq.trapp") else {
            throw NSError(domain: "TRBackup", code: -1, userInfo: [NSLocalizedDescriptionKey: "iCloud 不可用"])
        }

        let cloudRecordings = iCloudURL.appendingPathComponent("Recordings")
        let files = try fileManager.contentsOfDirectory(at: cloudRecordings, includingPropertiesForKeys: nil)

        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        let localDir = docs.appendingPathComponent("Recordings")

        var restored: [URL] = []
        for file in files {
            let dest = localDir.appendingPathComponent(file.lastPathComponent)
            if !fileManager.fileExists(atPath: dest.path) {
                try fileManager.copyItem(at: file, to: dest)
                restored.append(dest)
            }
        }
        return restored
    }
}