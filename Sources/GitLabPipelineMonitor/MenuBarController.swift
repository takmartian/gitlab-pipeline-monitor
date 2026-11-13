import AppKit
import Combine
import SwiftUI

@MainActor
final class MenuBarController: NSObject, NSPopoverDelegate {
    private let state: AppState
    private let settings: AppSettings
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private var cancellables = Set<AnyCancellable>()

    private static let panelHeight: CGFloat = 560

    init(state: AppState, settings: AppSettings) {
        self.state = state
        self.settings = settings
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        configureButton()
        configurePopover()
        observe()
        updateIcon()
    }

    private func configureButton() {
        guard let button = statusItem.button else { return }
        button.image = MenuBarIcon.base()
        button.imagePosition = .imageLeading
        button.target = self
        button.action = #selector(statusItemClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.toolTip = AppInfo.name
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        let root = PanelView()
            .environmentObject(state)
            .environmentObject(settings)
        popover.contentViewController = NSHostingController(rootView: root)
        syncPanelSize()
    }

    private func syncPanelSize() {
        popover.contentSize = NSSize(width: CGFloat(settings.panelWidth), height: Self.panelHeight)
    }

    // MARK: - 图标

    func updateIcon() {
        guard let button = statusItem.button else { return }
        let aggregate = state.aggregate
        guard settings.showStatusBadge, aggregate != .none else {
            button.attributedTitle = NSAttributedString(string: "")
            return
        }
        let failing = state.failingCount
        let suffix = (settings.showFailureCount && failing > 0) ? " \(failing)" : ""
        let title = NSAttributedString(string: " ●\(suffix)", attributes: [
            .foregroundColor: aggregate.color,
            .font: NSFont.systemFont(ofSize: 11, weight: .bold)
        ])
        button.attributedTitle = title
    }

    // MARK: - 交互

    @objc private func statusItemClicked(_ sender: Any?) {
        let event = NSApp.currentEvent
        let rightClick = event?.type == .rightMouseUp || (event?.modifierFlags.contains(.control) ?? false)
        if rightClick {
            showContextMenu()
            return
        }
        toggle()
    }

    private func showContextMenu() {
        let menu = NSMenu()

        let refresh = NSMenuItem(title: loc("刷新"), action: #selector(menuRefresh), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)

        menu.addItem(.separator())

        let autoTitle = settings.refreshInterval > 0 ? loc("暂停自动刷新") : loc("恢复自动刷新")
        let auto = NSMenuItem(title: autoTitle, action: #selector(menuToggleAutoRefresh), keyEquivalent: "")
        auto.target = self
        auto.state = settings.refreshInterval > 0 ? .on : .off
        menu.addItem(auto)

        let settingsItem = NSMenuItem(title: loc("设置"), action: #selector(menuSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: loc("退出"), action: #selector(menuQuit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func menuRefresh() { state.refresh(force: true) }
    @objc private func menuToggleAutoRefresh() { AppController.shared.toggleAutoRefresh(); updateIcon() }
    @objc private func menuSettings() { AppController.shared.showSettings() }
    @objc private func menuQuit() { NSApp.terminate(nil) }

    // MARK: - 面板

    func open() {
        guard let button = statusItem.button, !popover.isShown else { return }
        syncPanelSize()
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        if settings.refreshOnOpen { state.refresh() }
        updateIcon()
    }

    func close() {
        if popover.isShown { popover.performClose(nil) }
    }

    func toggle() {
        if popover.isShown { close() } else { open() }
    }

    private func observe() {
        state.objectWillChange
            .sink { [weak self] _ in DispatchQueue.main.async { self?.updateIcon() } }
            .store(in: &cancellables)
        settings.objectWillChange
            .sink { [weak self] _ in DispatchQueue.main.async { self?.updateIcon() } }
            .store(in: &cancellables)
        settings.$panelWidth.dropFirst()
            .sink { [weak self] _ in Task { @MainActor in self?.syncPanelSize() } }
            .store(in: &cancellables)
    }

    nonisolated func popoverDidClose(_ notification: Notification) {}
}
