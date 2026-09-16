import AppKit
import PhoneMicCore
import SwiftUI

struct MacStatusView: View {
    @ObservedObject var model: MacAppModel
    @State private var advancedControlsExpanded = false
    private let panelCornerRadius: CGFloat = 28

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: panelCornerRadius, style: .continuous)
                .fill(.regularMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: panelCornerRadius, style: .continuous)
                        .stroke(Color.primary.opacity(0.10), lineWidth: 0.75)
                )

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 14) {
                    header

                    Divider()

                    if let request = model.pendingPairingRequest {
                        pendingPairingPanel(request)
                    }

                    devicePairingSection

                    metricRow(title: "状态", value: model.connectionState.displayName)
                    metricRow(title: "iPhone", value: model.connectedDeviceName ?? "等待中")
                    metricRow(title: "连接", value: localizedValue(model.connectionDescription))

                    HStack {
                        Text("连接方式")
                            .foregroundStyle(.secondary)
                        Spacer()
                        PhoneMicSegmentedControl(
                            selection: $model.connectionMode,
                            options: PhoneMicConnectionMode.allCases,
                            title: \.displayName
                        )
                        .frame(width: 128)
                    }
                    .font(.system(size: 13))

                    metricRow(title: "USB", value: model.usbProxyDescription)
                    metricRow(title: "输出", value: localizedValue(model.outputDescription))
                    metricRow(title: "虚拟麦克风", value: localizedValue(model.virtualMicrophoneDescription))
                    metricRow(title: "系统输入", value: localizedValue(model.systemInputDescription))
                    metricRow(title: "延迟", value: model.latencyDescription)
                    metricRow(title: "缓冲", value: localizedValue(model.bufferDescription))
                    metricRow(title: "数据包", value: "\(model.transportStats.packetsReceived)")
                    metricRow(title: "丢序", value: "\(model.transportStats.sequenceGaps)")

                    HStack {
                        Text("模式")
                            .foregroundStyle(.secondary)
                        Spacer()
                        PhoneMicSegmentedControl(
                            selection: $model.processingMode,
                            options: AudioProcessingMode.allCases,
                            title: \.displayName
                        )
                        .frame(width: 128)
                    }
                    .font(.system(size: 13))

                    HStack {
                        Text("传输档位")
                            .foregroundStyle(.secondary)
                        Spacer()
                        PhoneMicSegmentedControl(
                            selection: $model.latencyMode,
                            options: PhoneMicLatencyMode.allCases,
                            title: \.displayName
                        )
                        .frame(width: 174)
                    }
                    .font(.system(size: 13))

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("麦克风增益")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("+\(Int(model.outputGainDecibels.rounded())) dB")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }

                        Slider(
                            value: $model.outputGainDecibels,
                            in: 0...12,
                            step: 1
                        )
                        .accessibilityLabel("麦克风增益")
                        .accessibilityValue("+\(Int(model.outputGainDecibels.rounded())) decibels")
                    }

                    PhoneMicSwitch(title: "扬声器监听", isOn: $model.speakerMonitoringEnabled)

                    advancedControls

                    HStack(spacing: 10) {
                        Button(model.calibrationState.displayName) {
                            model.startAutoCalibration()
                        }
                        .buttonStyle(.neutralPhoneMicButton)
                        .disabled({
                            if case .running = model.calibrationState { return true }
                            return false
                        }())

                        Button("恢复原输入") {
                            model.restorePreviousInputDevice()
                        }
                        .buttonStyle(.neutralPhoneMicButton)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("人声处理")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        metricRow(title: "输入 RMS", value: String(format: "%.5f", model.processingSnapshot.inputRMS))
                        metricRow(title: "输出峰值", value: String(format: "%.3f", model.processingSnapshot.outputPeak))
                        metricRow(title: "自动增益", value: String(format: "%.1fx", model.processingSnapshot.automaticGain))
                        metricRow(title: "限幅", value: "\(model.processingSnapshot.limiterHits)")
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("电平")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        LightweightLevelMeter(level: model.level, isConnected: model.isConnected)
                        .accessibilityLabel("输入电平")
                        .accessibilityValue("\(Int(model.level * 100)) percent")
                    }

                    HStack {
                        PhoneMicSwitch(title: "自动重连", isOn: $model.autoReconnect)

                        Spacer()

                        Button(model.isConnected ? "断开" : "重连") {
                            model.toggleConnection()
                        }
                        .buttonStyle(model.isConnected ? .destructivePhoneMicButton : .neutralPhoneMicButton)
                    }

                    Divider()

                    HStack {
                        Spacer()
                        Button("检查更新") {
                            model.checkForUpdates()
                        }
                        .buttonStyle(.neutralPhoneMicButton(size: .small))
                        Spacer()
                    }
                }
                .padding(18)
            }
            .scrollIndicators(.automatic)
        }
        .clipShape(RoundedRectangle(cornerRadius: panelCornerRadius, style: .continuous))
        .frame(maxHeight: 760)
    }

    private var advancedControls: some View {
        DisclosureGroup("高级设置", isExpanded: $advancedControlsExpanded) {
            VStack(alignment: .leading, spacing: 9) {
                tuningSlider(
                    title: "虚拟输出",
                    value: $model.blackHoleOutputBoostDecibels,
                    range: 0...14,
                    step: 0.5,
                    valueText: String(format: "+%.1f dB", model.blackHoleOutputBoostDecibels)
                )
                tuningSlider(
                    title: "监听音量",
                    value: $model.monitorOutputVolume,
                    range: 0...1,
                    step: 0.05,
                    valueText: "\(Int((model.monitorOutputVolume * 100).rounded()))%"
                )
                tuningSlider(
                    title: "人声目标",
                    value: $model.voiceTargetRMS,
                    range: 0.035...0.12,
                    step: 0.005,
                    valueText: String(format: "%.1f%%", model.voiceTargetRMS * 100)
                )
                tuningSlider(
                    title: "自动增益上限",
                    value: $model.automaticGainLimit,
                    range: 1...4,
                    step: 0.1,
                    valueText: String(format: "%.1fx", model.automaticGainLimit)
                )
                tuningSlider(
                    title: "噪声门保留",
                    value: $model.noiseGateFloor,
                    range: 0...0.5,
                    step: 0.02,
                    valueText: "\(Int((model.noiseGateFloor * 100).rounded()))%"
                )
                tuningSlider(
                    title: "处理限幅",
                    value: $model.limiterCeiling,
                    range: 0.70...0.98,
                    step: 0.01,
                    valueText: "\(Int((model.limiterCeiling * 100).rounded()))%"
                )
                tuningSlider(
                    title: "最终限幅",
                    value: $model.finalLimiterCeiling,
                    range: 0.70...0.98,
                    step: 0.01,
                    valueText: "\(Int((model.finalLimiterCeiling * 100).rounded()))%"
                )
                tuningSlider(
                    title: "离线判定",
                    value: $model.streamTimeoutSeconds,
                    range: 1...8,
                    step: 0.5,
                    valueText: String(format: "%.1f 秒", model.streamTimeoutSeconds)
                )
                tuningSlider(
                    title: "预缓冲",
                    value: $model.prebufferMilliseconds,
                    range: 5...80,
                    step: 5,
                    valueText: "\(Int(model.prebufferMilliseconds.rounded())) ms"
                )
            }
            .padding(.top, 8)
        }
        .font(.system(size: 13))
    }

    private func tuningSlider(
        title: String,
        value: Binding<Float>,
        range: ClosedRange<Float>,
        step: Float,
        valueText: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(valueText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, step: step)
                .accessibilityLabel(title)
                .accessibilityValue(valueText)
        }
    }

    private var devicePairingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !model.pairedDiscoveredDevices.isEmpty {
                HStack {
                    Text("设备")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Picker("设备", selection: $model.selectedDeviceID) {
                        ForEach(model.pairedDiscoveredDevices) { device in
                            Text(device.name)
                                .tag(Optional(device.id))
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: 190)
                }
            }

            ForEach(model.unpairedDiscoveredDevices) { device in
                HStack {
                    Image(systemName: "iphone")
                        .foregroundStyle(.secondary)
                    Text(device.name)
                        .lineLimit(1)
                    Spacer()
                    Button("配对") {
                        model.pair(device)
                    }
                    .buttonStyle(PhoneMicActionButtonStyle(appearance: .accent, size: .small))
                }
            }

            if model.selectedDeviceID != nil {
                HStack {
                    Spacer()
                    Button("忘记此 iPhone") {
                        model.forgetSelectedDevice()
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .font(.system(size: 13))
    }

    private func pendingPairingPanel(_ request: PhoneMicPendingPairing) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "iphone")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("iPhone 请求配对")
                        .font(.system(size: 13, weight: .semibold))
                    Text(request.deviceName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Text(request.pairingCode)
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .monospacedDigit()
            }

            HStack(spacing: 8) {
                Button("拒绝") {
                    model.rejectPendingPairing()
                }
                .buttonStyle(.neutralPhoneMicButton(size: .small))

                Button("信任") {
                    model.approvePendingPairing()
                }
                .buttonStyle(PhoneMicActionButtonStyle(appearance: .accent, size: .small))
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.07))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .font(.system(size: 13))
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: model.isConnected ? "mic.circle.fill" : "mic.slash.circle")
                .font(.system(size: 30))
                .foregroundStyle(model.isConnected ? .green : .secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text("PhoneMic")
                    .font(.headline)
                Text(model.isConnected ? "正在发送到 Mac" : "等待 iPhone")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("退出 PhoneMic")
        }
    }

    private func metricRow(title: String, value: String) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .monospacedDigit()
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.system(size: 13))
    }

    private func localizedValue(_ value: String) -> String {
        var result = value
        result = result.replacingOccurrences(of: "Waiting", with: "等待中")
        result = result.replacingOccurrences(of: "Starting", with: "正在启动")
        result = result.replacingOccurrences(of: "Discovered", with: "已发现")
        result = result.replacingOccurrences(of: "Default Output", with: "默认输出")
        result = result.replacingOccurrences(of: "not installed", with: "未安装")
        result = result.replacingOccurrences(of: "installed", with: "已安装")
        result = result.replacingOccurrences(of: "selected", with: "已选择")
        result = result.replacingOccurrences(of: "missing", with: "缺失")
        result = result.replacingOccurrences(of: "input is", with: "当前输入为")
        result = result.replacingOccurrences(of: "pre ", with: "预缓冲 ")
        return result
    }

}

private struct LightweightLevelMeter: View {
    let level: Float
    let isConnected: Bool

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.secondary.opacity(0.18))
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isConnected ? Color.green : Color.secondary.opacity(0.35))
                    .opacity(isConnected ? 0.92 : 1)
                    .frame(width: max(4, proxy.size.width * CGFloat(level)))
            }
        }
        .frame(height: 8)
    }
}

private struct PhoneMicSegmentedControl<Value: CaseIterable & Equatable & Identifiable>: View {
    @Binding var selection: Value
    let options: Value.AllCases
    let title: KeyPath<Value, String>

    private var optionArray: [Value] {
        Array(options)
    }

    var body: some View {
        HStack(spacing: 1) {
            ForEach(optionArray) { option in
                Button {
                    selection = option
                } label: {
                    Text(option[keyPath: title])
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .frame(maxWidth: .infinity, minHeight: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(selection == option ? .primary : .secondary)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(selection == option ? Color.primary.opacity(0.12) : Color.clear)
                )
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .animation(.snappy(duration: 0.12), value: String(describing: selection.id))
    }
}

private struct PhoneMicSwitch: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack(spacing: 10) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)

                ZStack(alignment: isOn ? .trailing : .leading) {
                    Capsule()
                        .fill(isOn ? Color.green : Color.secondary.opacity(0.30))
                        .overlay(
                            Capsule()
                                .stroke(Color.white.opacity(isOn ? 0.18 : 0.12), lineWidth: 1)
                        )

                    Circle()
                        .fill(Color.white.opacity(0.96))
                        .shadow(color: .black.opacity(0.25), radius: 2, x: 0, y: 1)
                        .padding(2)
                }
                .frame(width: 42, height: 24)
                .animation(.snappy(duration: 0.16), value: isOn)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "开启" : "关闭")
    }
}

private struct PhoneMicActionButtonStyle: ButtonStyle {
    enum Appearance {
        case neutral
        case accent
        case destructive

        var background: Color {
            switch self {
            case .neutral:
                return Color.primary.opacity(0.10)
            case .accent:
                return .green
            case .destructive:
                return .red
            }
        }

        var pressedBackground: Color {
            switch self {
            case .neutral:
                return Color.primary.opacity(0.16)
            case .accent:
                return .green.opacity(0.72)
            case .destructive:
                return .red.opacity(0.72)
            }
        }

        var foreground: Color {
            switch self {
            case .neutral:
                return .primary
            case .accent, .destructive:
                return .white
            }
        }

        var stroke: Color {
            switch self {
            case .neutral:
                return Color.primary.opacity(0.16)
            case .accent, .destructive:
                return Color.white.opacity(0.16)
            }
        }
    }

    enum Size {
        case regular
        case small

        var horizontalPadding: CGFloat {
            switch self {
            case .regular: return 14
            case .small: return 10
            }
        }

        var verticalPadding: CGFloat {
            switch self {
            case .regular: return 6
            case .small: return 4
            }
        }

        var font: Font {
            switch self {
            case .regular: return .system(size: 13, weight: .semibold)
            case .small: return .system(size: 12, weight: .semibold)
            }
        }
    }

    let appearance: Appearance
    var size: Size = .regular

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(size.font)
            .foregroundStyle(appearance.foreground)
            .padding(.horizontal, size.horizontalPadding)
            .padding(.vertical, size.verticalPadding)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(configuration.isPressed ? appearance.pressedBackground : appearance.background)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(appearance.stroke, lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.snappy(duration: 0.12), value: configuration.isPressed)
    }
}

private extension ButtonStyle where Self == PhoneMicActionButtonStyle {
    static var neutralPhoneMicButton: PhoneMicActionButtonStyle {
        PhoneMicActionButtonStyle(appearance: .neutral)
    }

    static func neutralPhoneMicButton(size: PhoneMicActionButtonStyle.Size) -> PhoneMicActionButtonStyle {
        PhoneMicActionButtonStyle(appearance: .neutral, size: size)
    }

    static var destructivePhoneMicButton: PhoneMicActionButtonStyle {
        PhoneMicActionButtonStyle(appearance: .destructive)
    }
}
