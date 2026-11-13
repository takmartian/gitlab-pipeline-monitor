import AppKit

// 生成 .iconset 里的各尺寸 PNG：深色圆角底 + 三节点流水线图（GitLab 配色）
// 用法: swift Tools/make_icon.swift Resources/icon.iconset

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

let orange = NSColor(srgbRed: 0.988, green: 0.427, blue: 0.149, alpha: 1)   // #FC6D26
let yellow = NSColor(srgbRed: 0.988, green: 0.631, blue: 0.129, alpha: 1)   // #FCA121
let red = NSColor(srgbRed: 0.886, green: 0.263, blue: 0.161, alpha: 1)      // #E24329

func draw(_ px: Int) -> NSImage {
    let size = CGFloat(px)
    let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
        let inset = size * 0.035
        let body = NSBezierPath(roundedRect: rect.insetBy(dx: inset, dy: inset),
                                xRadius: size * 0.225, yRadius: size * 0.225)
        if let gradient = NSGradient(starting: NSColor(srgbRed: 0.184, green: 0.204, blue: 0.239, alpha: 1),
                                     ending: NSColor(srgbRed: 0.086, green: 0.094, blue: 0.114, alpha: 1)) {
            gradient.draw(in: body, angle: -90)
        }

        NSColor(white: 1, alpha: 0.10).setStroke()
        let border = NSBezierPath(roundedRect: rect.insetBy(dx: inset + size * 0.006, dy: inset + size * 0.006),
                                  xRadius: size * 0.215, yRadius: size * 0.215)
        border.lineWidth = max(1, size * 0.006)
        border.stroke()

        let a = NSPoint(x: size * 0.29, y: size * 0.685)
        let b = NSPoint(x: size * 0.71, y: size * 0.685)
        let c = NSPoint(x: size * 0.50, y: size * 0.305)

        let link = NSBezierPath()
        link.lineWidth = max(1.5, size * 0.045)
        link.lineCapStyle = .round
        link.move(to: a)
        link.line(to: c)
        link.move(to: b)
        link.line(to: c)
        NSColor(white: 1, alpha: 0.82).setStroke()
        link.stroke()

        func node(_ point: NSPoint, _ radius: CGFloat, _ color: NSColor) {
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: point.x - radius, y: point.y - radius,
                                        width: radius * 2, height: radius * 2)).fill()
            NSColor(white: 1, alpha: 0.9).setStroke()
            let ring = NSBezierPath(ovalIn: NSRect(x: point.x - radius, y: point.y - radius,
                                                   width: radius * 2, height: radius * 2))
            ring.lineWidth = max(1, size * 0.012)
            ring.stroke()
        }

        node(a, size * 0.105, orange)
        node(b, size * 0.105, yellow)
        node(c, size * 0.135, red)
        return true
    }
    return image
}

func writePNG(_ image: NSImage, _ path: String) {
    guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        print("无法生成 PNG: \(path)")
        return
    }
    try? png.write(to: URL(fileURLWithPath: path))
}

let variants: [(Int, String)] = [
    (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
    (64, "icon_64x64.png"), (128, "icon_64x64@2x.png"),
    (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png")
]

for (px, name) in variants {
    writePNG(draw(px), outDir + "/" + name)
}
print("已生成 \(variants.count) 个图标到 \(outDir)")
