import UIKit
import CoreTelephony
import Contacts

/// 通话监听器 - 检测通话状态变化，触发自动录音
final class TRCallMonitor: NSObject {
    static let shared = TRCallMonitor()

    enum CallState {
        case idle
        case dialing
        case incoming
        case connected
        case disconnected
    }

    enum CallDirection {
        case incoming
        case outgoing
        case unknown
    }

    struct ActiveCall {
        var phoneNumber: String
        var contactName: String?
        var direction: CallDirection
        var startTime: Date
        var state: CallState
    }

    // MARK: - 属性
    private let callCenter = CTCallCenter()
    private let contactStore = CNContactStore()
    private var currentCall: ActiveCall?
    private var autoRecordEnabled = true
    private var blacklist: Set<String> = []
    private var whitelist: Set<String> = []
    private var filterMode: RecordFilterMode = .all

    enum RecordFilterMode: String, CaseIterable {
        case all = "all"
        case incomingOnly = "incomingOnly"
        case outgoingOnly = "outgoingOnly"
        case whitelistOnly = "whitelistOnly"
        case blacklistExclude = "blacklistExclude"
    }

    var onCallStateChanged: ((CallState, ActiveCall?) -> Void)?
    var onAutoRecordTriggered: ((ActiveCall) -> Void)?
    var onCallEnded: ((ActiveCall) -> Void)?

    private var isRecordingCall = false

    private override init() {
        super.init()
    }

    // MARK: - 监听控制
    func startMonitoring() {
        callCenter.callEventHandler = { [weak self] call in
            self?.handleCallEvent(call)
        }
        print("[TRApp] 通话监听已启动")
    }

    func stopMonitoring() {
        callCenter.callEventHandler = nil
        print("[TRApp] 通话监听已停止")
    }

    // MARK: - 配置
    func setAutoRecord(_ enabled: Bool) {
        autoRecordEnabled = enabled
    }

    func setFilterMode(_ mode: RecordFilterMode) {
        filterMode = mode
    }

    func addToWhitelist(_ number: String) {
        whitelist.insert(normalizeNumber(number))
    }

    func addToBlacklist(_ number: String) {
        blacklist.insert(normalizeNumber(number))
    }

    func removeFromWhitelist(_ number: String) {
        whitelist.remove(normalizeNumber(number))
    }

    func removeFromBlacklist(_ number: String) {
        blacklist.remove(normalizeNumber(number))
    }

    // MARK: - 通话事件处理
    private func handleCallEvent(_ call: CTCall) {
        let number = call.callID ?? "未知号码"
        let normalized = normalizeNumber(number)

        switch call.callState {
        case CTCallStateDialing:
            handleDialing(number: normalized)
        case CTCallStateIncoming:
            handleIncoming(number: normalized)
        case CTCallStateConnected:
            handleConnected(number: normalized)
        case CTCallStateDisconnected:
            handleDisconnected()
        default:
            break
        }
    }

    private func handleDialing(number: String) {
        let call = ActiveCall(
            phoneNumber: number,
            contactName: lookupContact(for: number),
            direction: .outgoing,
            startTime: Date(),
            state: .dialing
        )
        currentCall = call
        onCallStateChanged?(.dialing, call)
    }

    private func handleIncoming(number: String) {
        let call = ActiveCall(
            phoneNumber: number,
            contactName: lookupContact(for: number),
            direction: .incoming,
            startTime: Date(),
            state: .incoming
        )
        currentCall = call
        onCallStateChanged?(.incoming, call)
    }

    private func handleConnected(number: String) {
        guard var call = currentCall else { return }
        call.state = .connected
        call.startTime = Date()
        currentCall = call
        onCallStateChanged?(.connected, call)

        // 判断是否应该自动录音
        if shouldAutoRecord(call) {
            isRecordingCall = true
            onAutoRecordTriggered?(call)
            print("[TRApp] 自动录音触发: \(call.phoneNumber)")
        }
    }

    private func handleDisconnected() {
        guard let call = currentCall else { return }
        var endedCall = call
        endedCall.state = .disconnected
        onCallStateChanged?(.disconnected, endedCall)
        onCallEnded?(endedCall)

        if isRecordingCall {
            isRecordingCall = false
            TRAudioRecorder.shared.stopRecording()
        }

        currentCall = nil
    }

    // MARK: - 录音判断
    private func shouldAutoRecord(_ call: ActiveCall) -> Bool {
        guard autoRecordEnabled else { return false }

        let number = normalizeNumber(call.phoneNumber)

        switch filterMode {
        case .all:
            return true
        case .incomingOnly:
            return call.direction == .incoming
        case .outgoingOnly:
            return call.direction == .outgoing
        case .whitelistOnly:
            return whitelist.contains(number)
        case .blacklistExclude:
            return !blacklist.contains(number)
        }
    }

    // MARK: - 联系人查找
    private func lookupContact(for phoneNumber: String) -> String? {
        let keys: [CNKeyDescriptor] = [CNContactGivenNameKey as CNKeyDescriptor, CNContactFamilyNameKey as CNKeyDescriptor]
        let request = CNContactFetchRequest(keysToFetch: keys)
        var contactName: String?

        try? contactStore.enumerateContacts(with: request) { contact, stop in
            for phone in contact.phoneNumbers {
                let normalized = normalizeNumber(phone.value.stringValue)
                if normalized == normalizeNumber(phoneNumber) {
                    contactName = "\(contact.familyName)\(contact.givenName)"
                    if contactName?.isEmpty == true {
                        contactName = contact.organizationName
                    }
                    stop.pointee = true
                }
            }
        }
        return contactName
    }

    // MARK: - 工具方法
    private func normalizeNumber(_ number: String) -> String {
        number.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
    }

    func getCurrentCall() -> ActiveCall? { currentCall }
    func getCurrentCallState() -> CallState { currentCall?.state ?? .idle }
}