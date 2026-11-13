import AppKit

enum MenuBarIcon {
    /// GitLab 的流水线图就是三个节点相连，用 SF Symbol 的同名图形最贴切
    static let symbolName = "point.3.connected.trianglepath.dotted"

    static func base() -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        if let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: AppInfo.name)?
            .withSymbolConfiguration(config) {
            symbol.isTemplate = true
            return symbol
        }
        return fallback()
    }

    /// 万一符号不可用（极老的系统或字体缺失），手画一个三点连线
    private static func fallback() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            NSColor.black.setStroke()
            NSColor.black.setFill()
            let path = NSBezierPath()
            path.lineWidth = 1.4
            let points = [NSPoint(x: 5, y: 13), NSPoint(x: 13, y: 13), NSPoint(x: 9, y: 4)]
            path.move(to: points[0])
            path.line(to: points[2])
            path.move(to: points[1])
            path.line(to: points[2])
            path.stroke()
            for point in points {
                let circle = NSBezierPath(ovalIn: NSRect(x: point.x - 2.2, y: point.y - 2.2, width: 4.4, height: 4.4))
                circle.fill()
            }
            _ = rect
            return true
        }
        image.isTemplate = true
        return image
    }
}
