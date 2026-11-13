import SwiftUI
import Combine

/// 离屏渲染工具：--snapshot / --snaptab / --snapdetail 用它给自己出截图。
/// 没有录屏权限时 screencapture 不可用，这里用 NSHostingView 挂离屏窗口再抓位图。
@MainActor
enum Snapshot {
    private static var mountedWindow: NSWindow?

    /// ImageRenderer 路线：适合纯 SwiftUI 的小图（懒加载容器和 AppKit 控件会渲染成空白）
    static func write<V: View>(_ view: V, to path: String, scale: CGFloat = 2) {
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            NSLog("snapshot 渲染失败: \(path)")
            return
        }
        save(png, to: path)
    }

    /// 真窗口路线：挂载后立刻抓取
    static func writeWindow<V: View>(_ view: V, size: NSSize, to path: String) {
        mount(view, size: size)
        captureMounted(to: path)
    }

    static func mount<V: View>(_ view: V, size: NSSize) {
        mountedWindow?.orderOut(nil)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .windowBackgroundColor
        window.hasShadow = false
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: size.width, height: size.height)
        window.contentView = hosting
        window.orderFront(nil)
        window.display()
        mountedWindow = window
    }

    static func captureMounted(to path: String) {
        guard let window = mountedWindow, let content = window.contentView else {
            NSLog("snapshot 未挂载: \(path)")
            return
        }
        window.display()
        // 首选 cacheDisplay（位置和颜色最准）；抓到全空说明内容已切到 layer，退回 layer 抓取
        var rep = content.bitmapImageRepForCachingDisplay(in: content.bounds)
        if let candidate = rep, isBlank(candidate) { rep = nil }
        if rep == nil { rep = renderLayer(content) }
        guard let rep, let png = rep.representation(using: .png, properties: [:]) else {
            NSLog("snapshot 无法渲染: \(path)")
            return
        }
        save(png, to: path)
    }

    /// 抽样判断是否整张图一个颜色（什么都没画出来）
    private static func isBlank(_ rep: NSBitmapImageRep) -> Bool {
        let width = rep.pixelsWide, height = rep.pixelsHigh
        guard width > 2, height > 2, let first = rep.colorAt(x: 2, y: 2) else { return true }
        var sampled = 0
        for y in stride(from: 2, to: height - 2, by: max(1, height / 40)) {
            for x in stride(from: 2, to: width - 2, by: max(1, width / 40)) {
                guard let color = rep.colorAt(x: x, y: y) else { continue }
                sampled += 1
                if abs(color.redComponent - first.redComponent) > 0.01
                    || abs(color.greenComponent - first.greenComponent) > 0.01
                    || abs(color.blueComponent - first.blueComponent) > 0.01 {
                    return false
                }
            }
        }
        return sampled > 0
    }

    /// 兜底：渲染 layer 树（layer 是左上原点，位图是左下原点，需要翻一次）
    private static func renderLayer(_ view: NSView, scale: CGFloat = 2) -> NSBitmapImageRep? {
        guard let layer = view.layer else { return nil }
        let size = view.bounds.size
        guard size.width > 1, size.height > 1 else { return nil }
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * scale),
            pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        if let ctx = NSGraphicsContext.current?.cgContext {
            ctx.scaleBy(x: scale, y: scale)
            ctx.translateBy(x: 0, y: size.height)
            ctx.scaleBy(x: 1, y: -1)
            layer.render(in: ctx)
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    private static func save(_ png: Data, to path: String) {
        do {
            try png.write(to: URL(fileURLWithPath: path))
            NSLog("snapshot: \(path)")
        } catch {
            NSLog("snapshot 写入失败: \(error.localizedDescription)")
        }
    }

    /// 菜单栏图标预览：模板图标 + 状态点
    static func menuBarPreview(status: AggregateStatus, count: Int?, dark: Bool, to path: String) {
        let view = ZStack {
            Color(nsColor: dark ? .init(white: 0.12, alpha: 1) : .init(white: 0.94, alpha: 1))
            HStack(spacing: 4) {
                Image(nsImage: MenuBarIcon.base())
                    .renderingMode(.template)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(height: 15)
                    .foregroundStyle(dark ? Color.white : Color.black)
                if status != .none {
                    Circle().fill(Color(status.color)).frame(width: 6, height: 6)
                    if let count {
                        Text("\(count)")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(dark ? Color.white : Color.black)
                    }
                }
            }
            .padding(.horizontal, 10)
        }
        .frame(width: 120, height: 26)
        write(view, to: path, scale: 4)
    }
}
