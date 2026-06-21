import Foundation
import LocalAuthentication

/// 生物识别认证 - 支持 Face ID / Touch ID
class TRBiometricAuth: ObservableObject {
    static let shared = TRBiometricAuth()
    
    @Published var isLocked = false
    @Published var isAvailable = false
    @Published var biometryType: LABiometryType = .none
    
    private let context = LAContext()
    
    var biometryName: String {
        switch biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return "Biometric"
        }
    }
    
    init() {
        checkAvailability()
    }
    
    func checkAvailability() {
        var error: NSError?
        isAvailable = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
        biometryType = context.biometryType
    }
    
    func authenticate(reason: String = "Unlock to access your recordings") async -> Bool {
        guard isAvailable else { return true }
        
        let context = LAContext()
        context.localizedFallbackTitle = "Use Passcode"
        
        do {
            let success = try await context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: reason
            )
            if success {
                await MainActor.run { self.isLocked = false }
            }
            return success
        } catch {
            print("Biometric auth failed: \(error)")
            return false
        }
    }
    
    func lock() {
        isLocked = true
    }
}