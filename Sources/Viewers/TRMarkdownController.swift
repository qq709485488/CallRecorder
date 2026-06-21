import SwiftUI

/// Markdown 内容查看器 - 用于显示更新日志、帮助文档
struct MarkdownController: View {
    let content: String
    let title: String
    
    init(content: String, title: String = "Information") {
        self.content = content
        self.title = title
    }
    
    init(fileURL: URL, title: String = "Information") {
        self.content = (try? String(contentsOf: fileURL)) ?? ""
        self.title = title
    }
    
    var body: some View {
        ScrollView {
            Text(content)
                .font(.system(.body, design: .monospaced))
                .padding()
        }
        .navigationTitle(title)
        .background(Color(.systemBackground))
    }
}

/// 纯文本视图控制器
struct TextViewController: View {
    let text: String
    let title: String
    
    var body: some View {
        ScrollView {
            Text(text)
                .font(.body)
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(title)
        .background(Color(.systemBackground))
    }
}

/// Recycle Bin 视图
struct RecycleBinView: View {
    @StateObject private var bin = TRRecycleBin.shared
    @State private var showDeleteConfirmation = false
    
    var body: some View {
        List {
            if bin.deletedItems.isEmpty {
                Section {
                    Text("Trash is empty")
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding()
                }
            } else {
                Section {
                    ForEach(bin.deletedItems) { item in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(item.fileName)
                                    .font(.body)
                                Text("Deleted: \(item.deletedAt.formatted())")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Button("Restore") {
                                _ = bin.restore(item)
                            }
                            .buttonStyle(.bordered)
                            .tint(.green)
                        }
                        .padding(.vertical, 4)
                    }
                    .onDelete { indexSet in
                        for index in indexSet {
                            bin.permanentlyDelete(bin.deletedItems[index])
                        }
                    }
                }
                
                Section {
                    Button("Empty Trash") {
                        showDeleteConfirmation = true
                    }
                    .foregroundColor(.red)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .navigationTitle("Recently Deleted")
        .alert("Empty Trash", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete All", role: .destructive) {
                bin.emptyTrash()
            }
        } message: {
            Text("All items will be permanently deleted. This action cannot be undone.")
        }
    }
}

/// RecycleBin 控制器
struct RecycleBinController: View {
    var body: some View {
        NavigationView {
            RecycleBinView()
        }
    }
}