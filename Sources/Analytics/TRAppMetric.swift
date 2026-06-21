import Foundation
import UIKit

/// 应用统计 - 设备信息和使用统计
class TRAppMetric: ObservableObject {
    static let shared = TRAppMetric()
    
    @Published var recordingCount: Int = 0
    @Published var totalDuration: TimeInterval = 0
    @Published var storageUsed: Int64 = 0
    
    var deviceInfo: TRDeviceInfo {
        TRDeviceInfo(
            model: UIDevice.current.model,
            systemName: UIDevice.current.systemName,
            systemVersion: UIDevice.current.systemVersion,
            deviceName: UIDevice.current.name,
            identifierForVendor: UIDevice.current.identifierForVendor?.uuidString ?? "unknown"
        )
    }
    
    func updateStats(recordings: [TRRecording]) {
        recordingCount = recordings.count
        totalDuration = recordings.reduce(0) { $0 + $1.duration }
        storageUsed = recordings.reduce(0) { $0 + $1.fileSize }
    }
}

struct TRDeviceInfo {
    let model: String
    let systemName: String
    let systemVersion: String
    let deviceName: String
    let identifierForVendor: String
}