import UIKit
import AVFoundation

/// 音频格式转换器
final class TRAudioFormatConverter {
    static let shared = TRAudioFormatConverter()

    private init() {}

    func convert(inputURL: URL, to format: TRAudioRecorder.AudioFormat) async throws -> URL {
        let outputURL = inputURL.deletingPathExtension()
            .appendingPathExtension(format.rawValue)

        let asset = AVAsset(url: inputURL)
        let exporter = AVAssetExportSession(asset: asset, presetName: presetName(for: format))!
        exporter.outputURL = outputURL
        exporter.outputFileType = fileType(for: format)
        exporter.shouldOptimizeForNetworkUse = true

        await exporter.export()
        return outputURL
    }

    private func presetName(for format: TRAudioRecorder.AudioFormat) -> String {
        switch format {
        case .m4a: return AVAssetExportPresetAppleM4A
        case .wav: return AVAssetExportPresetPassthrough
        case .mp3: return AVAssetExportPresetPassthrough
        }
    }

    private func fileType(for format: TRAudioRecorder.AudioFormat) -> AVFileType {
        switch format {
        case .m4a: return .m4a
        case .wav: return .wav
        case .mp3: return .mp3
        }
    }
}