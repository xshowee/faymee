// 生成 Resources/AppIcon.icns
//   swift scripts/make-icon.swift
// 图形（方案 01「声波」）：蓝色渐变底板 + 9 根白色声波柱，中间一根红色代表“正在录”。
// 所有坐标基于 1024×1024 画布，原点左上；底板遵循 macOS 图标网格（824×824 圆角方块，四周留 100）。
import AppKit
import CoreGraphics

let canvas: CGFloat = 1024
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

let tilePath = CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824),
                      cornerWidth: 185, cornerHeight: 185, transform: nil)

func drawBackground(_ ctx: CGContext) {
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 12), blur: 24, color: rgb(0x000000, 0.35))
    ctx.addPath(tilePath)
    ctx.setFillColor(rgb(0x1F2A7A))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: colorSpace, colors: [rgb(0x4C6BFF), rgb(0x1F2A7A)] as CFArray,
                              locations: nil)!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])
    ctx.restoreGState()
}

/// 声波柱：(中心 x, 高度)，竖直居中于 y = 512，宽 44，两端全圆角
let bars: [(x: CGFloat, height: CGFloat)] = [
    (232, 160), (302, 300), (372, 220), (442, 460), (512, 600),
    (582, 400), (652, 520), (722, 280), (792, 140),
]

func drawBars(_ ctx: CGContext) {
    let width: CGFloat = 44
    for bar in bars {
        let rect = CGRect(x: bar.x - width / 2, y: 512 - bar.height / 2, width: width, height: bar.height)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: width / 2, cornerHeight: width / 2, transform: nil))
        ctx.setFillColor(bar.x == 512 ? rgb(0xFF6B5B) : rgb(0xFFFFFF))
        ctx.fillPath()
    }
}

func render(pixels: Int) -> Data {
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                        space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let scale = CGFloat(pixels) / canvas
    ctx.translateBy(x: 0, y: CGFloat(pixels))
    ctx.scaleBy(x: scale, y: -scale)
    drawBackground(ctx)
    drawBars(ctx)
    return NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for points in [16, 32, 128, 256, 512] {
    try render(pixels: points).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try render(pixels: points * 2).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}

let output = root.appendingPathComponent("Resources/AppIcon.icns")
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
try? FileManager.default.removeItem(at: iconset)
print("已生成 \(output.path)")
