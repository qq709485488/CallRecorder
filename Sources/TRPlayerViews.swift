import SwiftUI
import AVFoundation

/// 播放器选项控制器
struct PlayerOptionController: View {
    @State private var playbackRate: Float = 1.0
    @State private var skipSilence = false
    @State private var enhanceVoice = false
    
    let rates: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0]
    
    var body: some View {
        List {
            Section("Playback Speed") {
                Picker("Speed", selection: $playbackRate) {
                    ForEach(rates, id: \.self) { rate in
                        Text(String(format: "%.2fx", rate)).tag(rate)
                    }
                }
                .pickerStyle(.segmented)
            }
            
            Section("Audio Enhancements") {
                ConfigurableBooleanView(
                    icon: "waveform",
                    title: "Skip Silence",
                    description: "Automatically skip silent parts",
                    value: $skipSilence
                )
                
                ConfigurableBooleanView(
                    icon: "speaker.wave.2",
                    title: "Voice Enhancement",
                    description: "Improve voice clarity",
                    value: $enhanceVoice
                )
            }
        }
        .navigationTitle("Player Options")
    }
}

/// 播放器变速选项
struct PlayerRateCell: View {
    let rate: Float
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack {
                Text(String(format: "%.2fx", rate))
                    .font(.headline)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundColor(.accentColor)
                }
            }
            .padding(.vertical, 4)
        }
        .foregroundColor(.primary)
    }
}

/// 时间范围覆盖视图
struct TimeRangeOverlayView: View {
    let startTime: TimeInterval
    let endTime: TimeInterval
    let totalDuration: TimeInterval
    
    var body: some View {
        GeometryReader { geometry in
            let totalWidth = geometry.size.width
            let startX = totalWidth * CGFloat(startTime / totalDuration)
            let endX = totalWidth * CGFloat(endTime / totalDuration)
            let width = max(endX - startX, 2)
            
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Color.gray.opacity(0.3))
                
                Rectangle()
                    .fill(Color.yellow.opacity(0.5))
                    .frame(width: width)
                    .offset(x: startX)
            }
        }
        .frame(height: 40)
        .cornerRadius(4)
    }
}

/// 圆角背景效果视图
struct RoundedBackgroundEffectView: View {
    let color: Color
    
    var body: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(color)
            .shadow(color: color.opacity(0.3), radius: 5, x: 0, y: 2)
    }
}