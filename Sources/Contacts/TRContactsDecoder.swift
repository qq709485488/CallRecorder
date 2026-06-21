import Foundation
import Contacts

/// 通讯录解码器 - 将电话号码匹配为联系人姓名
class TRContactsDecoder: ObservableObject {
    static let shared = TRContactsDecoder()
    
    @Published var contacts: [TRContact] = []
    @Published var isAuthorized = false
    
    private let store = CNContactStore()
    private var nameCache: [String: String] = [:]
    
    init() {
        Task { await requestAccess() }
    }
    
    func requestAccess() async {
        do {
            isAuthorized = try await store.requestAccess(for: .contacts)
            if isAuthorized { await loadContacts() }
        } catch {
            isAuthorized = false
        }
    }
    
    func loadContacts() async {
        let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactPhoneNumbersKey] as [CNKeyDescriptor]
        let request = CNContactFetchRequest(keysToFetch: keys)
        
        var results: [TRContact] = []
        do {
            try store.enumerateContacts(with: request) { contact, _ in
                let name = "\(contact.familyName)\(contact.givenName)"
                for phone in contact.phoneNumbers {
                    let normalized = Self.normalizePhone(phone.value.stringValue)
                    let trContact = TRContact(
                        id: contact.identifier,
                        name: name.isEmpty ? phone.value.stringValue : name,
                        phoneNumber: normalized
                    )
                    results.append(trContact)
                    self.nameCache[normalized] = trContact.name
                }
            }
        } catch {
            print("Failed to load contacts: \(error)")
        }
        
        await MainActor.run { self.contacts = results }
    }
    
    func nameForPhone(_ phone: String) -> String? {
        let normalized = Self.normalizePhone(phone)
        return nameCache[normalized]
    }
    
    static func normalizePhone(_ phone: String) -> String {
        let cleaned = phone.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
        if cleaned.count > 10 {
            return String(cleaned.suffix(10))
        }
        return cleaned
    }
}

struct TRContact: Identifiable {
    let id: String
    let name: String
    let phoneNumber: String
}