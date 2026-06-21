import Foundation
import UIKit

/// 微信桥接 - 分享录音到微信
class TRWeChatBridge: ObservableObject {
    static let shared = TRWeChatBridge()
    
    @Published var isWeChatInstalled = false
    
    private let wechatScheme = "weixin://"
    
    init() {
        checkWeChatInstalled()
    }
    
    func checkWeChatInstalled() {
        if let url = URL(string: wechatScheme) {
            isWeChatInstalled = UIApplication.shared.canOpenURL(url)
        }
    }
    
    func shareRecording(_ recording: TRRecording, to scene: TRWeChatScene = .session) {
        guard isWeChatInstalled else {
            print("WeChat not installed")
            return
        }
        
        // 通过 UIActivityViewController 分享
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = windowScene.windows.first,
              let rootVC = window.rootViewController else {
            return
        }
        
        let activityVC = UIActivityViewController(
            activityItems: [recording.fileURL],
            applicationActivities: nil
        )
        
        if let popover = activityVC.popoverPresentationController {
            popover.sourceView = rootVC.view
        }
        
        rootVC.present(activityVC, animated: true)
    }
    
    func shareText(_ text: String, to scene: TRWeChatScene = .session) {
        guard isWeChatInstalled else { return }
        
        let encoded = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let urlString = "\(wechatScheme)app/\(scene.rawValue)/send?text=\(encoded)"
        
        if let url = URL(string: urlString) {
            UIApplication.shared.open(url)
        }
    }
}

enum TRWeChatScene: String {
    case session = "message"
    case timeline = "timeline"
    case favorite = "favorite"
}