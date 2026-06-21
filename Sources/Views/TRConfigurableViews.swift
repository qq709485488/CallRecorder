import SwiftUI

// MARK: - Configurable Views (设置项组件)

/// 布尔开关设置项
struct ConfigurableBooleanView: View {
    let icon: String?
    let title: String
    let description: String?
    @Binding var value: Bool
    
    init(icon: String? = nil, title: String, description: String? = nil, value: Binding<Bool>) {
        self.icon = icon
        self.title = title
        self.description = description
        self._value = value
    }
    
    var body: some View {
        HStack {
            if let icon = icon {
                Image(systemName: icon)
                    .frame(width: 30)
                    .foregroundColor(.accentColor)
            }
            VStack(alignment: .leading) {
                Text(title)
                if let desc = description {
                    Text(desc)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
            Toggle("", isOn: $value)
                .labelsHidden()
        }
        .padding(.vertical, 4)
    }
}

/// 子菜单导航设置项
struct ConfigurableSubmenuView: View {
    let icon: String?
    let title: String
    let value: String
    let destination: AnyView
    
    init<D: View>(icon: String? = nil, title: String, value: String, @ViewBuilder destination: () -> D) {
        self.icon = icon
        self.title = title
        self.value = value
        self.destination = AnyView(destination())
    }
    
    var body: some View {
        NavigationLink {
            destination
        } label: {
            HStack {
                if let icon = icon {
                    Image(systemName: icon)
                        .frame(width: 30)
                        .foregroundColor(.accentColor)
                }
                Text(title)
                Spacer()
                Text(value)
                    .foregroundColor(.secondary)
            }
        }
    }
}

/// 快捷查看设置项
struct ConfigurableQuickLookView: View {
    let icon: String?
    let title: String
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack {
                if let icon = icon {
                    Image(systemName: icon)
                        .frame(width: 30)
                        .foregroundColor(.accentColor)
                }
                Text(title)
                    .foregroundColor(.primary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

/// 分享链接设置项
struct ConfigurableShareLinkView: View {
    let icon: String?
    let title: String
    let url: URL
    
    var body: some View {
        ShareLink(item: url) {
            HStack {
                if let icon = icon {
                    Image(systemName: icon)
                        .frame(width: 30)
                        .foregroundColor(.accentColor)
                }
                Text(title)
                    .foregroundColor(.primary)
                Spacer()
                Image(systemName: "square.and.arrow.up")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
}

/// 信息链接设置项
struct ConfigurableInformativeLinkView: View {
    let icon: String?
    let title: String
    let value: String
    let url: URL
    
    var body: some View {
        Link(destination: url) {
            HStack {
                if let icon = icon {
                    Image(systemName: icon)
                        .frame(width: 30)
                        .foregroundColor(.accentColor)
                }
                Text(title)
                    .foregroundColor(.primary)
                Spacer()
                Text(value)
                    .foregroundColor(.secondary)
                Image(systemName: "arrow.up.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
}

/// 菜单视图
struct ConfigurableMenuView: View {
    let icon: String?
    let title: String
    let options: [String]
    @Binding var selection: String
    
    var body: some View {
        HStack {
            if let icon = icon {
                Image(systemName: icon)
                    .frame(width: 30)
                    .foregroundColor(.accentColor)
            }
            Text(title)
            Spacer()
            Picker("", selection: $selection) {
                ForEach(options, id: \.self) { option in
                    Text(option).tag(option)
                }
            }
            .pickerStyle(.menu)
        }
    }
}

/// 设置区域标题
struct ConfigurableViewSectionHeader: View {
    let title: String
    
    var body: some View {
        Text(title)
            .font(.footnote)
            .foregroundColor(.secondary)
            .textCase(.uppercase)
    }
}

/// 步进滑块
struct StepSlider: View {
    let title: String
    let range: ClosedRange<Double>
    let step: Double
    @Binding var value: Double
    let format: String
    
    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: format, value))
                    .foregroundColor(.secondary)
            }
            Slider(value: $value, in: range, step: step)
        }
    }
}