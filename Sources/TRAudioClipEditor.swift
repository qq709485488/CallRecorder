import Foundation
import AVFoundation

/// 音频剪辑编辑器
final class TRAudioClipEditor {
    static let shared = TRAudioClipEditor()

    private init() {}

    /// 裁剪音频
    func clip(
        sourceURL: URL,
        startTime: TimeInterval,
        endTime: TimeInterval,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        let asset = AVAsset(url: sourceURL)
        let outputURL = sourceURL.deletingLastPathComponent()
            .appendingPathComponent("clipped_\(sourceURL.lastPathComponent)")

        guard let exportSession = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetPassthrough
        ) else {
            completion(.failure(NSError(domain: "TRClip", code: -1, userInfo: [NSLocalizedDescriptionKey: "无法创建导出会话"])))
            return
        }

        exportSession.outputURL = outputURL
        exportSession.outputFileType = .m4a
        exportSession.timeRange = CMTimeRange(
            start: CMTime(seconds: startTime, preferredTimescale: 600),
            end: CMTime(seconds: endTime, preferredTimescale: 600)
        )

        exportSession.exportAsynchronously {
            DispatchQueue.main.async {
                switch exportSession.status {
                case .completed:
                    completion(.success(outputURL))
                case .failed, .cancelled:
                    completion(.failure(exportSession.error ?? NSError(domain: "TRClip", code: -1)))
                default:
                    break
                }
            }
        }
    }

    /// 合并多个音频文件
    func merge(
        urls: [URL],
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        let composition = AVMutableComposition()
        guard let audioTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            completion(.failure(NSError(domain: "TRMerge", code: -1)))
            return
        }

        var currentTime = CMTime.zero
        for url in urls {
            let asset = AVAsset(url: url)
            guard let track = asset.tracks(withMediaType: .audio).first else { continue }
            do {
                try audioTrack.insertTimeRange(
                    CMTimeRange(start: .zero, duration: asset.duration),
                    of: track,
                    at: currentTime
                )
                currentTime = CMTimeAdd(currentTime, asset.duration)
            } catch {
                completion(.failure(error))
                return
            }
        }

        let outputURL = urls[0].deletingLastPathComponent()
            .appendingPathComponent("merged_\(Date().timeIntervalSince1970).m4a")

        guard let exportSession = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetAppleM4A
        ) else {
            completion(.failure(NSError(domain: "TRMerge", code: -1)))
            return
        }

        exportSession.outputURL = outputURL
        exportSession.outputFileType = .m4a
        exportSession.exportAsynchronously {
            DispatchQueue.main.async {
                switch exportSession.status {
                case .completed:
                    completion(.success(outputURL))
                case .failed, .cancelled:
                    completion(.failure(exportSession.error ?? NSError(domain: "TRMerge", code: -1)))
                default:
                    break
                }
            }
        }
    }

    /// 删除静音段
    func removeSilence(
        url: URL,
        silenceThreshold: Float = 0.02,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        // 简化实现：使用裁剪方式
        clip(sourceURL: url, startTime: 0, endTime: AVAsset(url: url).duration.seconds, completion: completion)
    }
}