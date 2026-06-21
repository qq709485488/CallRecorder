import SwiftUI
import AVFoundation
import UserNotifications

// MARK: - Welcome 引导页

struct WelcomeController: View {
    @State private var currentPage = 0
    @Environment(\.dismiss) var dismiss
    
    let pages = [
        WelcomePage(
            icon: "mic.fill",
            title: "Call Recording",
            description: "Automatically record all incoming and outgoing calls."
        ),
        WelcomePage(
            icon: "text.bubble.fill",
            title: "Speech to Text",
            description: "Convert recordings to text with accurate transcription."
        ),
        WelcomePage(
            icon: "cloud.fill",
            title: "Cloud Backup",
            description: "Sync recordings to iCloud for safe keeping."
        ),
        WelcomePage(
            icon: "lock.shield.fill",
            title: "Privacy First",
            description: "All data stored locally. Protected with biometric lock."
        )
    ]
    
    var body: some View {
        VStack {
            TabView(selection: $currentPage) {
                ForEach(pages.indices, id: \.self) { index in
                    WelcomePageView(page: pages[index])
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            
            Button(currentPage < pages.count - 1 ? "Next" : "Get Started") {
                if currentPage < pages.count - 1 {
                    withAnimation { currentPage += 1 }
                } else {
                    UserDefaults.standard.set(true, forKey: "hasSeenWelcome")
                    dismiss()
                }
            }
            .buttonStyle(.borderedProminent)
            .padding(.bottom, 40)
            
            if currentPage < pages.count - 1 {
                Button("Skip") {
                    UserDefaults.standard.set(true, forKey: "hasSeenWelcome")
                    dismiss()
                }
                .foregroundColor(.secondary)
                .padding(.bottom, 20)
            }
        }
        .background(Color(.systemBackground))
    }
}

struct WelcomePage {
    let icon: String
    let title: String
    let description: String
}

struct WelcomePageView: View {
    let page: WelcomePage
    
    var body: some View {
        VStack(spacing: 30) {
            Image(systemName: page.icon)
                .font(.system(size: 80))
                .foregroundColor(.accentColor)
                .padding(.top, 60)
            
            Text(page.title)
                .font(.title)
                .fontWeight(.bold)
            
            Text(page.description)
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
    }
}

// MARK: - Setup 设置向导

struct SetupController: View {
    @Environment(\.dismiss) var dismiss
    @State private var microphoneGranted = false
    @State private var contactsGranted = false
    @State private var notificationsGranted = false
    
    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                Text("Setup Required Permissions")
                    .font(.title2)
                    .fontWeight(.bold)
                
                PermissionRow(
                    icon: "mic.fill",
                    title: "Microphone",
                    description: "Required for recording calls",
                    isGranted: microphoneGranted,
                    action: {
                        await requestMicrophone()
                    }
                )
                
                PermissionRow(
                    icon: "person.2.fill",
                    title: "Contacts",
                    description: "To display caller names",
                    isGranted: contactsGranted,
                    action: {
                        await requestContacts()
                    }
                )
                
                PermissionRow(
                    icon: "bell.fill",
                    title: "Notifications",
                    description: "Recording status alerts",
                    isGranted: notificationsGranted,
                    action: {
                        await requestNotifications()
                    }
                )
                
                Spacer()
                
                Button("Continue") {
                    UserDefaults.standard.set(true, forKey: "hasCompletedSetup")
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!microphoneGranted)
                .padding(.bottom, 30)
            }
            .padding()
            .navigationTitle("Setup")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Later") { dismiss() }
                }
            }
        }
    }
    
    func requestMicrophone() async {
        microphoneGranted = await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }
    
    func requestContacts() async {
        let decoder = TRContactsDecoder.shared
        await decoder.requestAccess()
        contactsGranted = decoder.isAuthorized
    }
    
    func requestNotifications() async {
        do {
            notificationsGranted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            notificationsGranted = false
        }
    }
}

struct PermissionRow: View {
    let icon: String
    let title: String
    let description: String
    let isGranted: Bool
    let action: () async -> Void
    
    var body: some View {
        HStack {
            Image(systemName: icon)
                .font(.title2)
                .frame(width: 40)
            
            VStack(alignment: .leading) {
                Text(title)
                    .font(.headline)
                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            if isGranted {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
            } else {
                Button("Allow") {
                    Task { await action() }
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 8)
    }
}

// MARK: - EULA 用户协议

struct EULAController: View {
    @Environment(\.dismiss) var dismiss
    @State private var agreed = false
    
    let eulaText = """
    END USER LICENSE AGREEMENT
    
    IMPORTANT: PLEASE READ THIS LICENSE CAREFULLY BEFORE USING THIS SOFTWARE.
    
    1. LICENSE
    By using CallRecorder ("the Software"), you agree to be bound by the terms of this agreement.
    
    2. PRIVACY
    All recordings are stored locally on your device. No data is transmitted to any server without your explicit consent.
    
    3. COMPLIANCE
    You are responsible for complying with all applicable laws regarding call recording in your jurisdiction.
    
    4. DISCLAIMER
    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND.
    
    5. LIMITATION OF LIABILITY
    IN NO EVENT SHALL THE AUTHORS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY.
    """
    
    var body: some View {
        VStack {
            ScrollView {
                Text(eulaText)
                    .font(.system(.body, design: .monospaced))
                    .padding()
            }
            
            Toggle("I have read and agree to the terms", isOn: $agreed)
                .padding(.horizontal)
            
            Button("Accept & Continue") {
                UserDefaults.standard.set(true, forKey: "hasAgreedEULA")
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .disabled(!agreed)
            .padding()
        }
        .navigationTitle("License Agreement")
    }
}