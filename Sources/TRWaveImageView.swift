import SwiftUI

/// 波形图视图 - 录音波形可视化
struct WaveImageView: View {
    let samples: [Float]
    let color: Color
    let lineWidth: CGFloat
    
    init(samples: [Float], color: Color = .accentColor, lineWidth: CGFloat = 2) {
        self.samples = samples
        self.color = color
        self.lineWidth = lineWidth
    }
    
    var body: some View {
        GeometryReader { geometry in
            if samples.isEmpty {
                Color.clear
            } else {
                Path { path in
                    let width = geometry.size.width
                    let height = geometry.size.height
                    let midY = height / 2
                    let step = width / CGFloat(max(samples.count - 1, 1))
                    
                    for (index, sample) in samples.enumerated() {
                        let x = CGFloat(index) * step
                        let amplitude = max(min(CGFloat(sample), 1), -1)
                        let y = midY - (amplitude * midY)
                        
                        if index == 0 {
                            path.move(to: CGPoint(x: x, y: y))
                        } else {
                            path.addLine(to: CGPoint(x: x, y: y))
                        }
                    }
                }
                .stroke(color, lineWidth: lineWidth)
            }
        }
    }
}

/// 带颜色渐变的波形图
struct AccentWaveImageView: View {
    let samples: [Float]
    @State private var animateGradient = false
    
    var body: some View {
        ZStack {
            WaveImageView(samples: samples, color: .blue, lineWidth: 3)
                .blur(radius: 2)
            
            LinearGradient(
                colors: [.blue, .purple, .pink],
                startPoint: animateGradient ? .leading : .trailing,
                endPoint: animateGradient ? .trailing : .leading
            )
            .mask(
                WaveImageView(samples: samples, color: .white, lineWidth: 2)
            )
        }
        .onAppear {
            withAnimation(.linear(duration: 3).repeatForever(autoreverses: true)) {
                animateGradient = true
            }
        }
    }
}

/// 魔幻色彩视图 - 背景效果
struct MagicColorsView: View {
    @State private var animate = false
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Circle()
                    .fill(Color.blue.opacity(0.3))
                    .frame(width: geometry.size.width * 0.6)
                    .offset(x: animate ? 50 : -50, y: animate ? -30 : 30)
                    .blur(radius: 40)
                
                Circle()
                    .fill(Color.purple.opacity(0.3))
                    .frame(width: geometry.size.width * 0.5)
                    .offset(x: animate ? -30 : 30, y: animate ? 40 : -40)
                    .blur(radius: 40)
                
                Circle()
                    .fill(Color.pink.opacity(0.2))
                    .frame(width: geometry.size.width * 0.4)
                    .offset(x: animate ? 20 : -20, y: animate ? -20 : 20)
                    .blur(radius: 30)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 5).repeatForever(autoreverses: true)) {
                animate = true
            }
        }
    }
}