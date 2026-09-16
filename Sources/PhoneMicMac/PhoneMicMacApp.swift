import AppKit

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static var retainedDelegate: AppDelegate?

    private let model = MacAppModel()
    private lazy var statusBarController = PhoneMicStatusBarController(model: model)

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        retainedDelegate = delegate
        app.delegate = delegate
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusBarController.install()
        model.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        statusBarController.invalidate()
        model.stop()
    }
}
