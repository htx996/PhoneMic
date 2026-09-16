import PhoneMicCore
import SwiftUI
import UIKit

struct PhoneMicView: View {
    @StateObject private var model = PhoneMicIOSModel()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsSettings = false

    var body: some View {
        TimelineView(.animation(minimumInterval: PhoneMicDisplayRefresh.interval, paused: reduceMotion)) { timeline in
            GeometryReader { proxy in
                let state = PhoneMicViewState(model: model)

                ZStack {
                    PhoneMicThemeStyleApplier(preference: model.themePreference)
                        .frame(width: 0, height: 0)

                    PhoneMicBackground(state: state)
                        .ignoresSafeArea()

                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 18) {
                            MinimalStatusHome(
                                model: model,
                                state: state,
                                displayTime: timeline.date.timeIntervalSinceReferenceDate,
                                settingsAction: { showsSettings = true }
                            )
                        }
                        .frame(maxWidth: 440)
                        .frame(minHeight: max(0, proxy.size.height - proxy.safeAreaInsets.top - proxy.safeAreaInsets.bottom))
                        .padding(.horizontal, 22)
                        .padding(.vertical, 20)
                        .frame(maxWidth: .infinity)
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
        }
        .sheet(isPresented: $showsSettings) {
            PhoneMicSettingsView(model: model)
        }
    }
}

private struct MinimalStatusHome: View {
    @ObservedObject var model: PhoneMicIOSModel
    let state: PhoneMicViewState
    let displayTime: TimeInterval
    let settingsAction: () -> Void

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: 28) {
                content
            }
        } else {
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        VStack(spacing: 18) {
            PhoneMicTopBar(state: state, settingsAction: settingsAction)
                .padding(.top, 8)

            PairingArea(model: model, state: state)

            Spacer(minLength: 24)

            PrimaryMicButton(state: state, displayTime: displayTime, size: 228) {
                model.toggle()
            }

            VStack(spacing: 8) {
                Text(state.statusTitle)
                    .font(.system(.title2, design: .rounded).weight(.bold))
                Text(state.statusSubtitle)
                    .font(.system(.callout, design: .rounded).weight(.medium))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }

            Spacer(minLength: 24)

            ConnectionSummaryCard(state: state, style: .prominent)
                .padding(.bottom, 8)
        }
    }
}

private struct PhoneMicTopBar: View {
    let state: PhoneMicViewState
    let settingsAction: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: state.micIcon)
                .font(.system(size: 34, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(state.accentColor)
                .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 3) {
                Text("PhoneMic")
                    .font(.system(.title2, design: .rounded).weight(.bold))
                Text(state.headline)
                    .font(.system(.subheadline, design: .rounded).weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button(action: settingsAction) {
                Image(systemName: "ellipsis")
                    .font(.system(size: 19, weight: .bold))
                    .frame(width: 42, height: 42)
                    .contentShape(Circle())
                    .liquidGlassSurface(cornerRadius: 21, tint: state.accentColor.opacity(0.08), isCircle: true, interactive: true)
            }
            .buttonStyle(PhoneMicBouncyButtonStyle(scale: 0.90))
            .foregroundStyle(.primary)
            .accessibilityLabel("设置")
        }
    }
}

private struct PairingArea: View {
    @ObservedObject var model: PhoneMicIOSModel
    let state: PhoneMicViewState

    var body: some View {
        VStack(spacing: 12) {
            if let request = model.pendingPairingRequest {
                PairingPanel(
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
                PairingPanel(
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
                DiscoveryPanel(mac: mac, state: state) {
                    model.pairWithMac(mac)
                }
            }
        }
    }
}

private struct PairingPanel: View {
    let title: String
    let subtitle: String
    let code: String
    let state: PhoneMicViewState
    let primaryTitle: String?
    let primaryAction: (() -> Void)?
    let secondaryTitle: String?
    let secondaryAction: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "macbook.and.iphone")
                    .font(.title2)
                    .foregroundStyle(state.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(code)
                    .font(.system(.title3, design: .rounded).weight(.bold))
                    .monospacedDigit()
            }

            if primaryTitle != nil || secondaryTitle != nil {
                HStack(spacing: 10) {
                    if let secondaryTitle, let secondaryAction {
                        Button(secondaryTitle, action: secondaryAction)
                            .buttonStyle(.bordered)
                    }
                    if let primaryTitle, let primaryAction {
                        Button(primaryTitle, action: primaryAction)
                            .buttonStyle(.borderedProminent)
                    }
                }
                .controlSize(.large)
            }
        }
        .padding(16)
        .liquidGlassSurface(cornerRadius: 24, tint: state.accentColor.opacity(0.12))
    }
}

private struct DiscoveryPanel: View {
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
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("信任", action: action)
                .buttonStyle(.borderedProminent)
        }
        .padding(16)
        .liquidGlassSurface(cornerRadius: 24, tint: state.accentColor.opacity(0.12))
    }
}

private struct PrimaryMicButton: View {
    let state: PhoneMicViewState
    let displayTime: TimeInterval
    let size: CGFloat
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let pulse = reduceMotion ? 0 : (sin(displayTime * Double.pi * 2 * 1.05) + 1) / 2
        let activePulse = state.phase == .ready ? 0 : pulse

        Button(action: action) {
            ZStack {
                Circle()
                    .fill(state.accentColor.opacity(0.14))
                    .frame(width: size * 1.12, height: size * 1.12)
                    .blur(radius: 22)
                    .scaleEffect(1 + activePulse * 0.035)

                Circle()
                    .strokeBorder(state.accentColor.opacity(0.22 + activePulse * 0.16), lineWidth: 1)
                    .frame(width: size, height: size)
                    .scaleEffect(1 + activePulse * 0.018)

                VStack(spacing: 14) {
                    Image(systemName: state.micIcon)
                        .font(.system(size: size * 0.32, weight: .semibold))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(state.accentColor)

                    Text(state.buttonTitle)
                        .font(.system(.title3, design: .rounded).weight(.bold))
                }
                .frame(width: size, height: size)
                .liquidGlassSurface(cornerRadius: size / 2, tint: state.accentColor.opacity(0.14), isCircle: true, interactive: true)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(PhoneMicBouncyButtonStyle(scale: 0.955))
        .accessibilityLabel(state.buttonTitle)
    }
}

private enum ConnectionSummaryStyle {
    case compact
    case prominent
}

private struct ConnectionSummaryCard: View {
    let state: PhoneMicViewState
    let style: ConnectionSummaryStyle

    var body: some View {
        VStack(spacing: style == .compact ? 10 : 14) {
            HStack {
                SummaryItem(title: "连接方式", value: state.transportValue, icon: state.transportIcon)
                Divider()
                SummaryItem(title: "Mac", value: state.clientValue, icon: "macmini")
            }

            if style == .prominent {
                HStack(spacing: 8) {
                    Circle()
                        .fill(state.accentColor)
                        .frame(width: 8, height: 8)
                    Text(state.headline)
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Text(state.inputLabel)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .liquidGlassSurface(cornerRadius: 24, tint: state.accentColor.opacity(0.10))
    }
}

private struct SummaryItem: View {
    let title: String
    let value: String
    let icon: String

    var body: some View {
        VStack(spacing: 6) {
            Label(title, systemImage: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value)
                .font(.system(.headline, design: .rounded).weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity)
    }
}

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

    @Namespace private var glassNamespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var pressedOption: Option?

    var body: some View {
        Group {
            if #available(iOS 26.0, *) {
                liquidGlassControl
            } else {
                fallbackControl
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 62)
    }

    @available(iOS 26.0, *)
    private var liquidGlassControl: some View {
        ZStack {
            liquidGlassSurfaces

            HStack(spacing: 0) {
                ForEach(options) { option in
                    segmentButton(for: option)
                }
            }
            .padding(4)
        }
        .scaleEffect(pressedOption == nil || reduceMotion ? 1 : 0.985)
        .animation(.interactiveSpring(response: 0.34, dampingFraction: 0.78, blendDuration: 0.06), value: selection)
        .animation(.interactiveSpring(response: 0.22, dampingFraction: 0.72, blendDuration: 0.04), value: pressedOption)
    }

    @available(iOS 26.0, *)
    private var liquidGlassSurfaces: some View {
        GlassEffectContainer(spacing: 28) {
            ZStack {
                Capsule()
                    .fill(.clear)
                    .frame(maxWidth: .infinity)
                    .frame(height: 62)
                    .glassEffect(.regular.interactive(pressedOption != nil), in: .capsule)
                    .glassEffectID("settings-choice-background", in: glassNamespace)

                HStack(spacing: 0) {
                    ForEach(options) { option in
                        ZStack {
                            if selection == option {
                                Capsule()
                                    .fill(.clear)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 54)
                                    .glassEffect(.regular.tint(selectionGlassTint).interactive(pressedOption == option), in: .capsule)
                                    .glassEffectID("settings-choice-selection", in: glassNamespace)
                                    .glassEffectTransition(.matchedGeometry)
                                    .scaleEffect(pressedOption == option && !reduceMotion ? 0.965 : 1)
                                    .transition(.identity)
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 54)
                    }
                }
                .padding(4)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 62)
        }
        .allowsHitTesting(false)
    }

    @available(iOS 26.0, *)
    private func segmentButton(for option: Option) -> some View {
        Button {
            select(option)
        } label: {
            Text(title(option))
                .font(.system(size: 17, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .foregroundStyle(selection == option ? Color.blue : inactiveTitleColor)
                .frame(maxWidth: .infinity, minHeight: 54)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in pressedOption = option }
                .onEnded { _ in pressedOption = nil }
        )
        .accessibilityAddTraits(selection == option ? .isSelected : [])
    }

    private var fallbackControl: some View {
        ZStack {
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay {
                    Capsule()
                        .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.06), lineWidth: 1)
                }

            HStack(spacing: 0) {
                ForEach(options) { option in
                    Button {
                        select(option)
                    } label: {
                        ZStack {
                            if selection == option {
                                Capsule()
                                    .fill(.thinMaterial)
                                    .padding(4)
                            }

                            Text(title(option))
                                .font(.system(size: 17, weight: .semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.82)
                                .foregroundStyle(selection == option ? Color.blue : inactiveTitleColor)
                        }
                        .frame(maxWidth: .infinity, minHeight: 54)
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selection == option ? .isSelected : [])
                }
            }
            .padding(4)
        }
    }

    private func select(_ option: Option) {
        if reduceMotion {
            selection = option
        } else {
            withAnimation(.interactiveSpring(response: 0.34, dampingFraction: 0.78, blendDuration: 0.06)) {
                selection = option
            }
        }
    }

    private var inactiveTitleColor: Color {
        colorScheme == .dark ? .white : .black
    }

    private var selectionGlassTint: Color {
        colorScheme == .dark ? .white.opacity(0.12) : .black.opacity(0.08)
    }
}

private struct PhoneMicBouncyButtonStyle: ButtonStyle {
    let scale: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.58, blendDuration: 0.02), value: configuration.isPressed)
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

private struct PhoneMicBackground: View {
    let state: PhoneMicViewState
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        LinearGradient(
            colors: backgroundColors,
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay(alignment: .topTrailing) {
            Circle()
                .fill(state.accentColor.opacity(colorScheme == .dark ? 0.18 : 0.16))
                .frame(width: 260, height: 260)
                .blur(radius: 54)
                .offset(x: 80, y: -90)
        }
    }

    private var backgroundColors: [Color] {
        if colorScheme == .dark {
            return [
                Color(red: 0.08, green: 0.09, blue: 0.11),
                Color(red: 0.12, green: 0.13, blue: 0.16),
            ]
        }

        return [
            Color(uiColor: .systemGroupedBackground),
            Color(uiColor: .secondarySystemGroupedBackground),
        ]
    }
}

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

    @MainActor
    init(model: PhoneMicIOSModel) {
        clientText = model.clientText
        transportText = model.latestStatus?.transport.displayName ?? model.transportText
        inputMode = model.inputMode
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
            return .blue
        case .waiting:
            return .orange
        case .sending:
            return .green
        }
    }

    var headline: String {
        switch phase {
        case .ready:
            return "就绪"
        case .waiting:
            return "等待 Mac"
        case .sending:
            return "正在发送"
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

    var micIcon: String {
        switch phase {
        case .ready:
            return "mic.circle"
        case .waiting:
            return "dot.radiowaves.left.and.right"
        case .sending:
            return "mic.circle.fill"
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

    var buttonIcon: String {
        switch phase {
        case .ready:
            return "play.fill"
        case .waiting, .sending:
            return "stop.fill"
        }
    }

    var inputLabel: String {
        inputMode.displayName
    }

    var clientValue: String {
        clientText == "Waiting" ? "等待中" : clientText
    }

    var transportKindTitle: String {
        normalizedTransport == "USB" ? "有线" : "无线"
    }

    var transportDetail: String {
        normalizedTransport
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

private extension View {
    @ViewBuilder
    func liquidGlassSurface(cornerRadius: CGFloat, tint: Color = .clear, isCircle: Bool = false, interactive: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            if isCircle {
                if interactive {
                    self
                        .glassEffect(.regular.tint(tint).interactive(), in: .circle)
                } else {
                    self
                        .glassEffect(.regular.tint(tint), in: .circle)
                }
            } else {
                if interactive {
                    self
                        .glassEffect(.regular.tint(tint).interactive(), in: .rect(cornerRadius: cornerRadius))
                } else {
                    self
                        .glassEffect(.regular.tint(tint), in: .rect(cornerRadius: cornerRadius))
                }
            }
        } else {
            if isCircle {
                self
                    .background(.ultraThinMaterial, in: Circle())
            } else {
                self
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            }
        }
    }

    @ViewBuilder
    func choiceGlassSurface() -> some View {
        if #available(iOS 26.0, *) {
            self
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 23))
        } else {
            self
        }
    }
}

private enum PhoneMicDisplayRefresh {
    static var interval: TimeInterval {
        1 / Double(max(UIScreen.main.maximumFramesPerSecond, 60))
    }
}
