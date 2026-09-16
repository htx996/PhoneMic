import PhoneMicCore
import SwiftUI
import UIKit

// 视觉方向：Apple 原生（iOS 系统应用语言）
// 结构、状态机与交互与原实现一致；主操作保持清晰的麦克风/停止按钮。

struct PhoneMicView: View {
    @StateObject private var model = PhoneMicIOSModel()
    @State private var showsSettings = false

    var body: some View {
        NavigationStack {
            PhoneMicHome(model: model)
                .navigationTitle("PhoneMic")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showsSettings = true
                        } label: {
                            Image(systemName: "gearshape")
                        }
                        .accessibilityLabel("设置")
                    }
                }
        }
        .sheet(isPresented: $showsSettings) {
            PhoneMicSettingsView(model: model)
        }
    }
}

private struct PhoneMicHome: View {
    @ObservedObject var model: PhoneMicIOSModel

    var body: some View {
        let state = PhoneMicViewState(model: model)

        ZStack {
            PhoneMicThemeStyleApplier(preference: model.themePreference)
                .frame(width: 0, height: 0)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 26) {
                    PairingSection(model: model, state: state)

                    TransportButton(model: model, state: state, size: 178)
                        .padding(.top, 12)

                    StatusBlock(state: state)

                    InfoCard(state: state)

                    if !state.detailText.isEmpty {
                        Text(state.detailText)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 4)
                    }
                }
                .frame(maxWidth: 480)
                .padding(.horizontal, 20)
                .padding(.bottom, 32)
                .frame(maxWidth: .infinity)
            }
        }
        .background(Color(uiColor: .systemGroupedBackground))
    }
}

// MARK: - Transport button

private struct TransportButton: View {
    @ObservedObject var model: PhoneMicIOSModel
    let state: PhoneMicViewState
    let size: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: PhoneMicDisplayRefresh.interval, paused: reduceMotion)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            let wave = (sin(time * Double.pi * 2 * 0.45) + 1) / 2
            let isLive = state.phase == .sending

            Button {
                model.toggle()
            } label: {
                ZStack {
                    if isLive && !reduceMotion {
                        ForEach(0..<3, id: \.self) { index in
                            RippleRing(
                                progress: (wave + Double(index) / 3.0).truncatingRemainder(dividingBy: 1),
                                tint: state.accentColor
                            )
                            .frame(width: size, height: size)
                        }
                    }

                    Image(systemName: state.buttonSystemImage)
                        .font(.system(size: size * 0.34, weight: .semibold))
                        .frame(width: size, height: size)
                }
            }
            .phoneMicSystemButtonStyle(prominent: true)
            .buttonBorderShape(.circle)
            .tint(state.accentColor)
            .accessibilityLabel(state.buttonTitle)
        }
    }
}

/// 向外扩散的声波环，仅在发送中显示。
private struct RippleRing: View {
    let progress: Double
    let tint: Color

    var body: some View {
        Circle()
            .strokeBorder(tint.opacity(max(0, 0.42 * (1 - progress))), lineWidth: 2)
            .scaleEffect(1 + CGFloat(progress) * 0.85)
    }
}

private struct StatusBlock: View {
    let state: PhoneMicViewState

    var body: some View {
        VStack(spacing: 6) {
            Text(state.statusTitle)
                .font(.title2.weight(.bold))

            Text(state.statusSubtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }
}

// MARK: - Pairing

private struct PairingSection: View {
    @ObservedObject var model: PhoneMicIOSModel
    let state: PhoneMicViewState

    var body: some View {
        VStack(spacing: 12) {
            if let request = model.pendingPairingRequest {
                PairingCard(
                    title: "配对请求",
                    subtitle: request.macName,
                    code: request.pairingCode,
                    state: state,
                    primaryTitle: "信任",
                    primaryAction: { model.approvePairing() },
                    secondaryTitle: "拒绝",
                    secondaryAction: { model.rejectPairing() }
                )
            }

            if let request = model.pendingOutgoingPairing {
                PairingCard(
                    title: "等待 Mac 确认",
                    subtitle: request.macName,
                    code: request.pairingCode,
                    state: state,
                    primaryTitle: nil,
                    primaryAction: nil,
                    secondaryTitle: nil,
                    secondaryAction: nil
                )
            } else if let mac = model.discoveredMacs.first(where: { !$0.isPaired }), !model.isStreaming {
                DiscoveryCard(mac: mac, state: state) {
                    model.pairWithMac(mac)
                }
            }
        }
    }
}

private struct PairingCard: View {
    let title: String
    let subtitle: String
    let code: String
    let state: PhoneMicViewState
    let primaryTitle: String?
    let primaryAction: (() -> Void)?
    let secondaryTitle: String?
    let secondaryAction: (() -> Void)?

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "macbook.and.iphone")
                    .font(.title2)
                    .foregroundStyle(state.accentColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Text(code)
                    .font(.title3.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(state.accentColor)
            }

            if primaryTitle != nil || secondaryTitle != nil {
                HStack(spacing: 12) {
                    if let secondaryTitle, let secondaryAction {
                        Button(secondaryTitle, action: secondaryAction)
                            .phoneMicSystemButtonStyle()
                            .frame(maxWidth: .infinity)
                    }
                    if let primaryTitle, let primaryAction {
                        Button(primaryTitle, action: primaryAction)
                            .phoneMicSystemButtonStyle(prominent: true)
                            .frame(maxWidth: .infinity)
                    }
                }
                .controlSize(.large)
            }
        }
        .padding(16)
        .card()
    }
}

private struct DiscoveryCard: View {
    let mac: PhoneMicDiscoveredMac
    let state: PhoneMicViewState
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "macmini")
                .font(.title2)
                .foregroundStyle(state.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text("发现 Mac")
                    .font(.headline)
                Text(mac.name)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button("信任", action: action)
                .phoneMicSystemButtonStyle(prominent: true)
                .controlSize(.large)
        }
        .padding(16)
        .card()
    }
}

// MARK: - Info

private struct InfoCard: View {
    let state: PhoneMicViewState

    var body: some View {
        VStack(spacing: 0) {
            InfoRow(label: "连接方式", value: state.transportValue, systemImage: state.transportIcon)
            rowDivider
            InfoRow(label: "Mac", value: state.clientValue, systemImage: "macmini")
            rowDivider
            InfoRow(label: "输入", value: state.inputLabel, systemImage: "mic")
            rowDivider
            InfoRow(label: "数据包", value: state.packetValue, systemImage: "arrow.up.arrow.down")
        }
        .card()
    }

    private var rowDivider: some View {
        Rectangle()
            .fill(Color(uiColor: .separator))
            .frame(height: 0.5)
            .padding(.leading, 16)
    }
}

private struct InfoRow: View {
    let label: String
    let value: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 12) {
            Label(label, systemImage: systemImage)
                .font(.body)

            Spacer(minLength: 12)

            Text(value)
                .font(.body)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

private extension View {
    func card() -> some View {
        background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
    }

    @ViewBuilder
    func phoneMicSystemButtonStyle(prominent: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            if prominent {
                self.buttonStyle(.glassProminent)
            } else {
                self.buttonStyle(.glass)
            }
        } else {
            if prominent {
                self.buttonStyle(.borderedProminent)
            } else {
                self.buttonStyle(.bordered)
            }
        }
    }
}

// MARK: - Settings

private struct PhoneMicSettingsView: View {
    @ObservedObject var model: PhoneMicIOSModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                PhoneMicThemeStyleApplier(preference: model.themePreference)
                    .frame(width: 0, height: 0)

                Form {
                    Section("主题设置") {
                        PhoneMicChoiceButtons(
                            options: PhoneMicThemePreference.allCases,
                            selection: $model.themePreference,
                            title: \.displayName
                        )
                        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                        .listRowBackground(Color.clear)
                    }

                    Section("设备名称") {
                        PhoneMicChoiceButtons(
                            options: PhoneMicDeviceNameMode.allCases,
                            selection: $model.deviceNameMode,
                            title: \.displayName
                        )
                        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                        .listRowBackground(Color.clear)

                        if model.deviceNameMode == .automatic {
                            LabeledContent("显示名称", value: model.systemDeviceDisplayName)
                        } else {
                            TextField("设备名称", text: $model.deviceDisplayName)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }

                        LabeledContent("机型", value: model.deviceModelDisplayName)

                        Button("恢复自动名称") {
                            model.deviceNameMode = .automatic
                        }
                    }

                    Section("设备与连接") {
                        Picker("输入", selection: $model.inputMode) {
                            ForEach(MicrophoneInputMode.allCases) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }

                        LabeledContent("连接方式", value: PhoneMicViewState(model: model).transportValue)
                        LabeledContent("Mac", value: PhoneMicViewState(model: model).clientValue)

                        Button("忘记此 Mac", role: .destructive) {
                            model.forgetTrustedMacs()
                        }
                    }

                    Section("关于") {
                        LabeledContent("名称", value: PhoneMicAppInfo.displayName)
                        LabeledContent("版本", value: PhoneMicAppInfo.versionText)
                        Text("音频只在本地网络或 USB 内传输，不录音、不上传云端。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("设置")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") {
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct PhoneMicChoiceButtons<Option: Hashable & Identifiable>: View {
    let options: [Option]
    @Binding var selection: Option
    let title: (Option) -> String

    var body: some View {
        PhoneMicSegmentedControl(
            options: options,
            selection: $selection,
            title: title
        )
        .frame(maxWidth: .infinity)
        .frame(height: 54)
    }
}

private struct PhoneMicSegmentedControl<Option: Hashable & Identifiable>: UIViewRepresentable {
    let options: [Option]
    @Binding var selection: Option
    let title: (Option) -> String

    func makeUIView(context: Context) -> UISegmentedControl {
        let control = UISegmentedControl(items: options.map(title))
        control.addTarget(
            context.coordinator,
            action: #selector(Coordinator.selectionChanged(_:)),
            for: .valueChanged
        )
        applyAppearance(to: control)
        applySelection(to: control)
        return control
    }

    func updateUIView(_ control: UISegmentedControl, context: Context) {
        context.coordinator.options = options
        context.coordinator.selection = $selection

        if control.numberOfSegments != options.count {
            control.removeAllSegments()
            for (index, option) in options.enumerated() {
                control.insertSegment(withTitle: title(option), at: index, animated: false)
            }
        } else {
            for (index, option) in options.enumerated() {
                control.setTitle(title(option), forSegmentAt: index)
            }
        }

        applyAppearance(to: control)
        applySelection(to: control)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(options: options, selection: $selection)
    }

    private func applySelection(to control: UISegmentedControl) {
        control.selectedSegmentIndex = options.firstIndex(of: selection) ?? UISegmentedControl.noSegment
    }

    private func applyAppearance(to control: UISegmentedControl) {
        control.selectedSegmentTintColor = nil
        control.backgroundColor = nil
        control.setTitleTextAttributes(textAttributes(color: .black), for: .normal)
        control.setTitleTextAttributes(textAttributes(color: .systemBlue), for: .selected)
    }

    private func textAttributes(color: UIColor) -> [NSAttributedString.Key: Any] {
        [
            .foregroundColor: color,
            .font: UIFont.systemFont(ofSize: 17, weight: .semibold)
        ]
    }

    final class Coordinator: NSObject {
        var options: [Option]
        var selection: Binding<Option>

        init(options: [Option], selection: Binding<Option>) {
            self.options = options
            self.selection = selection
        }

        @objc
        func selectionChanged(_ sender: UISegmentedControl) {
            guard sender.selectedSegmentIndex >= 0,
                  sender.selectedSegmentIndex < options.count
            else { return }
            selection.wrappedValue = options[sender.selectedSegmentIndex]
        }
    }
}

private struct PhoneMicThemeStyleApplier: UIViewControllerRepresentable {
    let preference: PhoneMicThemePreference

    func makeUIViewController(context: Context) -> UIViewController {
        let controller = UIViewController()
        applyStyle(from: controller)
        return controller
    }

    func updateUIViewController(_ controller: UIViewController, context: Context) {
        applyStyle(from: controller)
    }

    private func applyStyle(from controller: UIViewController) {
        let style = preference.interfaceStyle
        controller.overrideUserInterfaceStyle = style

        DispatchQueue.main.async {
            if let window = controller.view.window {
                window.overrideUserInterfaceStyle = style
            }

            for scene in UIApplication.shared.connectedScenes {
                guard let windowScene = scene as? UIWindowScene else { continue }
                for window in windowScene.windows {
                    window.overrideUserInterfaceStyle = style
                }
            }
        }
    }
}

// MARK: - State

private enum PhoneMicConnectionPhase {
    case ready
    case waiting
    case sending
}

private struct PhoneMicViewState {
    let phase: PhoneMicConnectionPhase
    let clientText: String
    let transportText: String
    let inputMode: MicrophoneInputMode
    let packetCount: UInt64
    let detailText: String

    @MainActor
    init(model: PhoneMicIOSModel) {
        clientText = model.clientText
        transportText = model.latestStatus?.transport.displayName ?? model.transportText
        inputMode = model.inputMode
        packetCount = model.packetCount
        detailText = model.statusText
        if !model.isStreaming {
            phase = .ready
        } else if model.clientText == "Waiting" {
            phase = .waiting
        } else {
            phase = .sending
        }
    }

    var accentColor: Color {
        switch phase {
        case .ready:
            return .accentColor
        case .waiting:
            return .orange
        case .sending:
            return .green
        }
    }

    var statusTitle: String {
        switch phase {
        case .ready:
            return "就绪"
        case .waiting:
            return "等待中"
        case .sending:
            return "发送中"
        }
    }

    var statusSubtitle: String {
        switch phase {
        case .ready:
            return "点击开始发送"
        case .waiting:
            return "等待 Mac 连接"
        case .sending:
            return "点击停止"
        }
    }

    var buttonTitle: String {
        switch phase {
        case .ready:
            return "开始发送"
        case .waiting, .sending:
            return "停止发送"
        }
    }

    var buttonSystemImage: String {
        switch phase {
        case .ready:
            return "mic.fill"
        case .waiting, .sending:
            return "stop.fill"
        }
    }

    var packetValue: String {
        var digits = String(packetCount)
        var grouped = ""

        while digits.count > 3 {
            grouped = "," + String(digits.suffix(3)) + grouped
            digits = String(digits.dropLast(3))
        }

        return digits + grouped
    }

    var inputLabel: String {
        inputMode.displayName
    }

    var clientValue: String {
        clientText == "Waiting" ? "等待中" : clientText
    }

    var transportValue: String {
        normalizedTransport == "USB" ? "有线 USB" : "无线 Wi-Fi"
    }

    var transportIcon: String {
        normalizedTransport == "USB" ? "cable.connector" : "wifi"
    }

    private var normalizedTransport: String {
        if transportText.localizedCaseInsensitiveContains("usb") {
            return "USB"
        }
        if transportText.localizedCaseInsensitiveContains("wi") || transportText.localizedCaseInsensitiveContains("tcp") {
            return "Wi-Fi"
        }
        return transportText.isEmpty ? "Wi-Fi" : transportText
    }
}

private enum PhoneMicAppInfo {
    static var displayName: String {
        value(for: "CFBundleDisplayName") ?? value(for: "CFBundleName") ?? "PhoneMic"
    }

    static var versionText: String {
        let version = value(for: "CFBundleShortVersionString") ?? "0.1.0"
        let build = value(for: "CFBundleVersion") ?? "0"
        return "\(version) (\(build))"
    }

    private static func value(for key: String) -> String? {
        Bundle.main.object(forInfoDictionaryKey: key) as? String
    }
}

private enum PhoneMicDisplayRefresh {
    static var interval: TimeInterval {
        1 / Double(max(UIScreen.main.maximumFramesPerSecond, 60))
    }
}
