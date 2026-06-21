import Foundation
import WidgetKit
import SwiftUI

/// LaunchPadExtension - 桌面小组件
/// 提供快速录音开关和录音状态显示

@available(iOS 16.0, *)
struct RecordingStatusEntry: TimelineEntry {
    let date: Date
    let isRecording: Bool
    let recordingType: String
}

@available(iOS 16.0, *)
struct LaunchPadProvider: TimelineProvider {
    func placeholder(in context: Context) -> RecordingStatusEntry {
        RecordingStatusEntry(date: Date(), isRecording: false, recordingType: "")
    }
    
    func getSnapshot(in context: Context, completion: @escaping (RecordingStatusEntry) -> Void) {
        let entry = RecordingStatusEntry(date: Date(), isRecording: false, recordingType: "")
        completion(entry)
    }
    
    func getTimeline(in context: Context, completion: @escaping (Timeline<RecordingStatusEntry>) -> Void) {
        // 从共享 UserDefaults 读取状态
        let shared = UserDefaults(suiteName: "group.wiki.qaq.trapp")
        let isRecording = shared?.bool(forKey: "isRecording") ?? false
        let type = shared?.string(forKey: "recordingType") ?? ""
        
        let entry = RecordingStatusEntry(date: Date(), isRecording: isRecording, recordingType: type)
        let timeline = Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(60)))
        completion(timeline)
    }
}

@available(iOS 16.0, *)
struct LaunchPadWidgetEntryView: View {
    var entry: LaunchPadProvider.Entry
    
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: entry.isRecording ? "record.circle.fill" : "record.circle")
                .font(.system(size: 30))
                .foregroundColor(entry.isRecording ? .red : .gray)
            
            Text(entry.isRecording ? "Recording" : "Idle")
                .font(.caption)
                .foregroundColor(.secondary)
            
            if entry.isRecording && !entry.recordingType.isEmpty {
                Text(entry.recordingType)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
    }
}

@available(iOS 16.0, *)
struct LaunchPadWidget: Widget {
    let kind = "wiki.qaq.trapp.LaunchPadWidget"
    
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: LaunchPadProvider()) { entry in
            LaunchPadWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("CallRecorder Status")
        .description("Quick view of recording status")
        .supportedFamilies([.systemSmall])
    }
}

@available(iOS 16.0, *)
struct LaunchPadExtension: WidgetBundle {
    var body: some Widget {
        LaunchPadWidget()
    }
}