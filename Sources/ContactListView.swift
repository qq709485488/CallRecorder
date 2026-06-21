import SwiftUI
import Contacts

/// 通讯录列表视图
struct ContactListView: View {
    @StateObject private var decoder = TRContactsDecoder.shared
    @State private var searchText = ""
    
    var filteredContacts: [TRContact] {
        if searchText.isEmpty {
            return decoder.contacts
        }
        return decoder.contacts.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            $0.phoneNumber.contains(searchText)
        }
    }
    
    var body: some View {
        List {
            if !decoder.isAuthorized {
                Section {
                    VStack(spacing: 12) {
                        Image(systemName: "person.crop.circle.badge.exclamationmark")
                            .font(.largeTitle)
                            .foregroundColor(.orange)
                        Text("No Contacts Access")
                            .font(.headline)
                        Text("Please enable contacts access in Settings to display caller names.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                        Button("Open Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity)
                }
            } else {
                ForEach(filteredContacts) { contact in
                    ContactCellView(contact: contact)
                }
            }
        }
        .searchable(text: $searchText, prompt: "Search contacts")
        .navigationTitle("Contacts")
        .onAppear {
            if decoder.contacts.isEmpty {
                Task { await decoder.loadContacts() }
            }
        }
    }
}

/// 联系人列表控制器
struct ContactListController: View {
    var body: some View {
        NavigationView {
            ContactListView()
        }
    }
}

/// 联系人管理控制器
struct ContactListManagerController: View {
    @StateObject private var decoder = TRContactsDecoder.shared
    @State private var showImportSheet = false
    @State private var showExportSheet = false
    
    var body: some View {
        List {
            Section {
                ContactListView()
            } header: {
                HStack {
                    Button("Import") { showImportSheet = true }
                    Spacer()
                    Button("Export") { showExportSheet = true }
                }
            }
        }
        .navigationTitle("Manage Contacts")
    }
}

/// 联系人单元格
struct ContactCellView: View {
    let contact: TRContact
    
    var body: some View {
        HStack {
            Image(systemName: "person.circle.fill")
                .font(.title2)
                .foregroundColor(.blue)
            VStack(alignment: .leading) {
                Text(contact.name)
                    .font(.body)
                Text(contact.phoneNumber)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}