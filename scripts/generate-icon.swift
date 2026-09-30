import AppKit

// 生成 1024x1024 应用图标：Jellyfin 紫色渐变圆角方块 + 白色播放三角
let size = NSSize(width: 1024, height: 1024)
guard let image = NSImage(size: size).copy() as? NSImage else { fatalError() }

image.lockFocus()
guard let ctx = NSGraphicsContext.current?.cgContext else { fatalError() }

// 圆角背景 + 渐变
let bg = NSBezierPath(
    roundedRect: NSRect(x: 32, y: 32, width: 960, height: 960),
    xRadius: 220,
    yRadius: 220
)
ctx.saveGState()
bg.addClip()
let colors = [
    NSColor(red: 0xAA / 255.0, green: 0x5C / 255.0, blue: 0xC3 / 255.0, alpha: 1).cgColor,
    NSColor(red: 0x5B / 255.0, green: 0x7C / 255.0, blue: 0xFF / 255.0, alpha: 1).cgColor,
] as CFArray
let gradient = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: colors,
    locations: [0, 1]
)!
ctx.drawLinearGradient(
    gradient,
    start: CGPoint(x: 128, y: 896),
    end: CGPoint(x: 896, y: 128),
    options: []
)
ctx.restoreGState()

// 播放三角
let triangle = NSBezierPath()
triangle.move(to: NSPoint(x: 420, y: 300))
triangle.line(to: NSPoint(x: 420, y: 724))
triangle.line(to: NSPoint(x: 760, y: 512))
triangle.close()
NSColor.white.setFill()
triangle.fill()

image.unlockFocus()

guard let rep = NSBitmapImageRep(data: image.tiffRepresentation!) else { fatalError() }
guard let png = rep.representation(using: .png, properties: [:]) else { fatalError() }
let output = URL(fileURLWithPath: CommandLine.arguments[1])
try! png.write(to: output)
print("written: \(output.path)")
