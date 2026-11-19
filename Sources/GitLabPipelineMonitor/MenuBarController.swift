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

    init(state: AppState, settings: AppSettings) {
        self.state = state
        self.settings = settings
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        configureButton()
        configurePopover()
        // 面板高度变了要立刻把弹窗窗口撑到同样大小，否则内容会被裁掉
        settings.onPanelHeightChange = { [weak self] height in
            self?.syncPanelSize(height: height)
        }
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

    private func syncPanelSize(height explicitHeight: Int? = nil) {
        let width = CGFloat(settings.panelWidth)
        let height = CGFloat(PanelMetrics.clamp(explicitHeight ?? settings.panelHeight, screen: panelScreen))
        let size = NSSize(width: width, height: height)
        let window = popover.isShown ? popover.contentViewController?.view.window : nil
        // 弹窗窗口比内容大一圈阴影留白，改尺寸时得把这圈留白算进去，
        // 直接把窗口设成 contentSize 会把内容裁掉一圈
        let margin = window.map {
            CGSize(width: max(0, $0.frame.width - popover.contentSize.width),
                   height: max(0, $0.frame.height - popover.contentSize.height))
        } ?? .zero
        let top = window?.frame.maxY
        popover.contentSize = size
        guard let window, let top else { return }
        var frame = window.frame
        var changed = false
        // 面板挂在菜单栏下面：顶边必须钉住，底边往下长。
        // AppKit 自己改 contentSize 时不一定保证顶边不动，这里显式钉回去。
        if abs(frame.maxY - top) > 0.5 {
            frame.origin.y = top - frame.height
            changed = true
        }
        let expected = NSSize(width: size.width + margin.width, height: size.height + margin.height)
        if abs(frame.width - expected.width) > 0.5 || abs(frame.height - expected.height) > 0.5 {
            // AppKit 没跟上（老系统上 contentSize 不一定立刻改窗口），手动撑到同样大小
            frame.size = expected
            frame.origin.y = top - expected.height
            changed = true
        }
        if changed {
            if let visible = panelScreen?.visibleFrame, frame.minY < visible.minY {
                frame.origin.y = visible.minY
            }
            window.setFrame(frame, display: true)
        }
    }

    /// 面板挂在哪块屏上（状态栏所在屏）
    private var panelScreen: NSScreen? {
        statusItem.button?.window?.screen ?? NSScreen.main
    }

    /// 诊断用：打印弹窗窗口边框
    func printPanelFrame(_ label: String) {
        guard let window = popover.contentViewController?.view.window else {
            print("[\(label)] 没有窗口")
            return
        }
        let f = window.frame
        print("[\(label)] contentSize=\(Int(popover.contentSize.width))x\(Int(popover.contentSize.height)) "
            + "frame=(\(Int(f.origin.x)),\(Int(f.origin.y)) \(Int(f.width))x\(Int(f.height)))")
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
