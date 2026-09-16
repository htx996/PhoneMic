import AppKit
import Combine
import QuartzCore
import SwiftUI

@MainActor
final class PhoneMicStatusBarController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let statusIndicatorLayer = CALayer()
    private let model: MacAppModel
    private var panel: PhoneMicMenuBarPanel?
    private var panelState = PanelState.closed
    private var localEventMonitor: Any?
    private var globalEventMonitor: Any?
    private var cancellables = Set<AnyCancellable>()

    init(model: MacAppModel) {
        self.model = model
        super.init()
    }

    func install() {
        guard let button = statusItem.button else { return }

        statusItem.length = 30
        button.image = statusImage(isConnected: model.isConnected)
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.wantsLayer = true
        button.target = self
        button.action = #selector(togglePanel(_:))
        button.sendAction(on: [.leftMouseDown])
        button.toolTip = "PhoneMic"
        installStatusIndicator(on: button)
        updateStatusIndicator(isActive: model.isConnected)

        model.$isConnected
            .receive(on: RunLoop.main)
            .sink { [weak self] isConnected in
                guard let self else { return }
                self.statusItem.button?.image = self.statusImage(isConnected: isConnected)
                self.updateStatusIndicator(isActive: isConnected)
            }
            .store(in: &cancellables)
    }

    func invalidate() {
        closePanelImmediately()
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    @objc private func togglePanel(_ sender: NSStatusBarButton) {
        switch panelState {
        case .open:
            closePanel()
        case .closed:
            showPanel(from: sender)
        case .opening, .closing:
            break
        }
    }

    private func showPanel(from button: NSStatusBarButton) {
        guard panelState == .closed else { return }

        let panel = preparePanelIfNeeded()
        panel.position(relativeTo: button)

        self.panel = panel
        panelState = .opening
        installEventMonitors()
        panel.showWithScaleAnimation { [weak self, weak panel] in
            guard let self, let panel, self.panel === panel else { return }
            self.panelState = .open
        }
    }

    private func preparePanelIfNeeded() -> PhoneMicMenuBarPanel {
        if let panel {
            return panel
        }

        let hostingController = NSHostingController(rootView: MacStatusView(model: model).frame(width: PhoneMicMenuBarPanel.width))
        hostingController.view.wantsLayer = true
        hostingController.view.layer?.backgroundColor = NSColor.clear.cgColor
        hostingController.view.frame = NSRect(x: 0, y: 0, width: PhoneMicMenuBarPanel.width, height: 1)

        let fittingSize = hostingController.view.fittingSize
        let panelSize = NSSize(width: PhoneMicMenuBarPanel.width, height: max(1, ceil(fittingSize.height)))
        hostingController.view.frame = NSRect(origin: .zero, size: panelSize)
        hostingController.view.layoutSubtreeIfNeeded()
        hostingController.view.displayIfNeeded()

        let panel = PhoneMicMenuBarPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = hostingController
        panel.setContentSize(panelSize)
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.contentView?.displayIfNeeded()
        self.panel = panel
        return panel
    }

    private func closePanel() {
        guard panelState == .open else { return }
        removeEventMonitors()
        guard let panel else {
            panelState = .closed
            return
        }

        panelState = .closing
        panel.closeWithScaleAnimation { [weak self, weak panel] in
            guard let self, let panel, self.panel === panel else { return }
            self.panelState = .closed
            panel.contentViewController = nil
            self.panel = nil
        }
    }

    private func closePanelImmediately() {
        removeEventMonitors()
        panel?.contentViewController = nil
        panel?.close()
        panel = nil
        panelState = .closed
    }

    private func installEventMonitors() {
        removeEventMonitors()

        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self else { return event }

            if event.type == .keyDown, event.keyCode == 53 {
                closePanel()
                return nil
            }

            if event.type == .leftMouseDown || event.type == .rightMouseDown {
                guard let panel, panel.isVisible else { return event }
                if event.window == panel || eventIsInsideStatusButton(event) {
                    return event
                }
                closePanel()
            }

            return event
        }

        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                self?.closePanel()
            }
        }
    }

    private func removeEventMonitors() {
        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
            self.localEventMonitor = nil
        }

        if let globalEventMonitor {
            NSEvent.removeMonitor(globalEventMonitor)
            self.globalEventMonitor = nil
        }
    }

    private func eventIsInsideStatusButton(_ event: NSEvent) -> Bool {
        guard let button = statusItem.button, let buttonWindow = button.window else {
            return false
        }

        guard event.window == buttonWindow else {
            return false
        }

        let point = button.convert(event.locationInWindow, from: nil)
        return button.bounds.contains(point)
    }

    private func statusImage(isConnected: Bool) -> NSImage? {
        let symbolName = isConnected ? "mic.fill" : "mic.slash"
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "PhoneMic")
        image?.isTemplate = true
        return image
    }

    private func installStatusIndicator(on button: NSStatusBarButton) {
        statusIndicatorLayer.name = "PhoneMicStatusIndicator"
        statusIndicatorLayer.backgroundColor = NSColor(calibratedRed: 1.0, green: 0.62, blue: 0.04, alpha: 1).cgColor
        statusIndicatorLayer.cornerRadius = 2
        statusIndicatorLayer.masksToBounds = true
        statusIndicatorLayer.zPosition = 10

        if statusIndicatorLayer.superlayer == nil {
            button.layer?.addSublayer(statusIndicatorLayer)
        }
        layoutStatusIndicator(in: button)
    }

    private func updateStatusIndicator(isActive: Bool) {
        guard let button = statusItem.button else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layoutStatusIndicator(in: button)
        statusIndicatorLayer.isHidden = !isActive
        statusIndicatorLayer.opacity = isActive ? 1 : 0
        CATransaction.commit()

        if isActive {
            startStatusIndicatorBreathing()
        } else {
            stopStatusIndicatorBreathing()
        }
    }

    private func layoutStatusIndicator(in button: NSStatusBarButton) {
        let size: CGFloat = 4
        let x = max(0, button.bounds.maxX - size - 3)
        let y = max(0, button.bounds.midY - size / 2)
        statusIndicatorLayer.frame = CGRect(x: x, y: y, width: size, height: size)
        statusIndicatorLayer.cornerRadius = size / 2
    }

    private func startStatusIndicatorBreathing() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            stopStatusIndicatorBreathing()
            statusIndicatorLayer.opacity = 1
            return
        }

        if statusIndicatorLayer.animation(forKey: "PhoneMicStatusIndicatorBreathing") != nil {
            return
        }

        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 0.45
        animation.toValue = 1
        animation.duration = 1.35
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(controlPoints: 0.77, 0, 0.175, 1)
        statusIndicatorLayer.add(animation, forKey: "PhoneMicStatusIndicatorBreathing")
    }

    private func stopStatusIndicatorBreathing() {
        statusIndicatorLayer.removeAnimation(forKey: "PhoneMicStatusIndicatorBreathing")
    }
}

private enum PanelState {
    case closed
    case opening
    case open
    case closing
}

private final class PhoneMicMenuBarPanel: NSPanel {
    static let width: CGFloat = 344
    private static let screenPadding: CGFloat = 8
    private static let statusItemSpacing: CGFloat = 7
    private static let openingYOffset: CGFloat = 6
    private static let openDuration: CFTimeInterval = 0.18
    private static let closeDuration: CFTimeInterval = 0.13
    private static let openTiming = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
    private static let closeTiming = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)

    private var expandedFrame = NSRect.zero
    private var panelAnchor = NSPoint(x: 0.5, y: 1)

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override init(
        contentRect: NSRect,
        styleMask style: NSWindow.StyleMask,
        backing backingStoreType: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)

        isFloatingPanel = true
        isReleasedWhenClosed = false
        isOpaque = false
        hasShadow = false
        backgroundColor = .clear
        level = .popUpMenu
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        contentView?.wantsLayer = true
        contentView?.layer?.backgroundColor = NSColor.clear.cgColor
    }

    func prepareCachedSnapshotIfNeeded() {}

    func position(relativeTo button: NSStatusBarButton) {
        guard let buttonWindow = button.window else {
            center()
            expandedFrame = frame
            panelAnchor = NSPoint(x: 0.5, y: 1)
            return
        }

        let buttonRectInWindow = button.convert(button.bounds, to: nil)
        let buttonRectOnScreen = buttonWindow.convertToScreen(buttonRectInWindow)
        let screenFrame = buttonWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? frame
        let size = frame.size

        let proposedX = buttonRectOnScreen.midX - size.width / 2
        let x = min(
            max(proposedX, screenFrame.minX + Self.screenPadding),
            screenFrame.maxX - size.width - Self.screenPadding
        )

        let belowY = buttonRectOnScreen.minY - size.height - Self.statusItemSpacing
        let aboveY = buttonRectOnScreen.maxY + Self.statusItemSpacing
        let y: CGFloat
        let anchorY: CGFloat
        if belowY >= screenFrame.minY + Self.screenPadding {
            y = belowY
            anchorY = buttonRectOnScreen.minY
        } else {
            y = min(aboveY, screenFrame.maxY - size.height - Self.screenPadding)
            anchorY = buttonRectOnScreen.maxY
        }

        expandedFrame = NSRect(origin: NSPoint(x: x, y: y), size: size)
        panelAnchor = NSPoint(
            x: min(1, max(0, (buttonRectOnScreen.midX - expandedFrame.minX) / max(expandedFrame.width, 1))),
            y: anchorY == buttonRectOnScreen.minY ? 1 : 0
        )
        setFrame(expandedFrame, display: false)
    }

    func showWithScaleAnimation(completion: @escaping @MainActor @Sendable () -> Void) {
        contentView?.layer?.removeAllAnimations()
        hasShadow = false
        setFrame(expandedFrame, display: false)
        alphaValue = 1
        prepareContentLayerForAnimation()

        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let contentLayer = contentView?.layer
        else {
            contentView?.layer?.opacity = 1
            contentView?.layer?.transform = CATransform3DIdentity
            orderFrontRegardless()
            completion()
            return
        }

        let startTransform = openingTransform()
        let endTransform = CATransform3DIdentity
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contentLayer.opacity = 0
        contentLayer.transform = startTransform
        CATransaction.commit()

        orderFrontRegardless()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contentLayer.opacity = 1
        contentLayer.transform = endTransform
        CATransaction.commit()

        addLayerAnimation(
            to: contentLayer,
            keyPath: "opacity",
            from: 0,
            to: 1,
            duration: Self.openDuration,
            timingFunction: Self.openTiming
        )
        addLayerAnimation(
            to: contentLayer,
            keyPath: "transform",
            from: startTransform,
            to: endTransform,
            duration: Self.openDuration,
            timingFunction: Self.openTiming
        ) { [weak self] in
            self?.hasShadow = false
            completion()
        }
    }

    func closeWithScaleAnimation(completion: @escaping @MainActor @Sendable () -> Void) {
        guard let contentLayer = contentView?.layer else {
            orderOut(nil)
            completion()
            return
        }

        contentLayer.removeAllAnimations()

        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Self.closeDuration
                context.timingFunction = Self.closeTiming
                animator().alphaValue = 0
            } completionHandler: { [weak self] in
                Task { @MainActor in
                    self?.alphaValue = 1
                    self?.orderOut(nil)
                    completion()
                }
            }
            return
        }

        let startTransform = contentLayer.presentation()?.transform ?? contentLayer.transform
        let endTransform = openingTransform()
        let startOpacity = contentLayer.presentation()?.opacity ?? contentLayer.opacity
        contentLayer.opacity = 0
        contentLayer.transform = endTransform
        addLayerAnimation(
            to: contentLayer,
            keyPath: "opacity",
            from: startOpacity,
            to: 0,
            duration: Self.closeDuration,
            timingFunction: Self.closeTiming
        )
        addLayerAnimation(
            to: contentLayer,
            keyPath: "transform",
            from: startTransform,
            to: endTransform,
            duration: Self.closeDuration,
            timingFunction: Self.closeTiming
        ) { [weak self] in
            self?.contentView?.layer?.opacity = 1
            self?.contentView?.layer?.transform = CATransform3DIdentity
            self?.orderOut(nil)
            completion()
        }
    }

    private func prepareContentLayerForAnimation() {
        guard let contentView else { return }
        contentView.wantsLayer = true
        guard let layer = contentView.layer else { return }

        let oldAnchor = layer.anchorPoint
        guard oldAnchor != panelAnchor else { return }

        let bounds = layer.bounds
        let position = layer.position
        let xOffset = (panelAnchor.x - oldAnchor.x) * bounds.width
        let yOffset = (panelAnchor.y - oldAnchor.y) * bounds.height
        layer.anchorPoint = panelAnchor
        layer.position = CGPoint(x: position.x + xOffset, y: position.y + yOffset)
    }

    private func openingTransform() -> CATransform3D {
        let direction: CGFloat = panelAnchor.y >= 0.5 ? Self.openingYOffset : -Self.openingYOffset
        return CATransform3DMakeTranslation(0, direction, 0)
    }

    private func addLayerAnimation(
        to layer: CALayer,
        keyPath: String,
        from: Any,
        to: Any,
        duration: CFTimeInterval,
        timingFunction: CAMediaTimingFunction,
        completion: (@MainActor @Sendable () -> Void)? = nil
    ) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let completion {
            CATransaction.setCompletionBlock {
                Task { @MainActor in
                    completion()
                }
            }
        }
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = from
        animation.toValue = to
        animation.duration = duration
        animation.timingFunction = timingFunction
        animation.fillMode = .removed
        animation.isRemovedOnCompletion = true
        layer.add(animation, forKey: "phonemic.\(keyPath)")
        CATransaction.commit()
    }
}
