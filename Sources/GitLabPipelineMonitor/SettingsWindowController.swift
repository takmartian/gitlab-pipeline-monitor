import AppKit
import SwiftUI
import Combine

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let state: AppState
    private let settings: AppSettings
    private let tabSubject = PassthroughSubject<SettingsTab, Never>()

    init(state: AppState, settings: AppSettings) {
        self.state = state
        self.settings = settings
        let root = SettingsView(tabs: tabSubject)
            .environmentObject(state)
            .environmentObject(settings)
        let hosting = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: hosting)
        window.title = loc("设置")
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 620, height: 480))
        window.contentMinSize = NSSize(width: 520, height: 360)
        window.isReleasedWhenClosed = false
        window.tabbingIdentifier = "settings"
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func select(_ tab: SettingsTab) { tabSubject.send(tab) }

    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
}
