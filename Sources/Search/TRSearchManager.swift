import Foundation

/// 搜索管理器 - 在录音文件中搜索
class TRSearchManager: ObservableObject {
    static let shared = TRSearchManager()
    
    @Published var searchResults: [TRRecording] = []
    @Published var isSearching = false
    
    private var allRecordings: [TRRecording] = []
    
    func updateRecordings(_ recordings: [TRRecording]) {
        allRecordings = recordings
    }
    
    func search(query: String) async {
        guard !query.isEmpty else {
            await MainActor.run {
                searchResults = []
                isSearching = false
            }
            return
        }
        
        await MainActor.run { isSearching = true }
        
        let results = allRecordings.filter { recording in
            let searchText = query.lowercased()
            return recording.fileName.lowercased().contains(searchText) ||
                   recording.phoneNumber.contains(searchText) ||
                   recording.contactName?.lowercased().contains(searchText) ?? false ||
                   recording.duration.description.contains(searchText)
        }
        
        await MainActor.run {
            searchResults = results
            isSearching = false
        }
    }
    
    func clearSearch() {
        searchResults = []
        isSearching = false
    }
}