import AppKit

// 菜单栏（accessory）应用：不占 Dock，不抢主窗口。
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let controller = AppController.shared
    app.delegate = controller
    app.setActivationPolicy(.accessory)
    app.run()
}
