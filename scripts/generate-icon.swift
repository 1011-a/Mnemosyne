#!/usr/bin/env swift
// Renders the Mnemosyne app icon (aurora orb on a dark squircle) and assembles
// an .icns via iconutil. Usage: swift generate-icon.swift <output.icns>
import AppKit

func cg(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    CGColor(red: r, green: g, blue: b, alpha: a)
}

func render(px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                              isPlanar: false, colorSpaceName: .deviceRGB,
                              bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    let ctx = context.cgContext
    let s = CGFloat(px)

    // Dark squircle background
    let radius = s * 0.225
    let bg = CGPath(roundedRect: CGRect(x: 0, y: 0, width: s, height: s),
                    cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.addPath(bg); ctx.clip()
    ctx.setFillColor(cg(0.039, 0.043, 0.059)); ctx.fill(CGRect(x: 0, y: 0, width: s, height: s))

    // Ambient aurora wash
    let space = CGColorSpaceCreateDeviceRGB()
    let wash = CGGradient(colorsSpace: space,
                          colors: [cg(0.66, 0.34, 0.97, 0.18), cg(0.13, 0.83, 0.93, 0.0)] as CFArray,
                          locations: [0, 1])!
    ctx.drawRadialGradient(wash, startCenter: CGPoint(x: s * 0.5, y: s * 0.62), startRadius: 0,
                           endCenter: CGPoint(x: s * 0.5, y: s * 0.62), endRadius: s * 0.6, options: [])

    // The intelligence orb
    let orbR = s * 0.30
    let center = CGPoint(x: s * 0.5, y: s * 0.5)
    let orbRect = CGRect(x: center.x - orbR, y: center.y - orbR, width: orbR * 2, height: orbR * 2)
    let grad = CGGradient(colorsSpace: space,
                          colors: [cg(0.66, 0.34, 0.97), cg(0.43, 0.34, 0.97), cg(0.13, 0.83, 0.93)] as CFArray,
                          locations: [0, 0.5, 1])!
    ctx.saveGState()
    ctx.addEllipse(in: orbRect); ctx.clip()
    ctx.drawLinearGradient(grad,
                           start: CGPoint(x: orbRect.minX, y: orbRect.maxY),
                           end: CGPoint(x: orbRect.maxX, y: orbRect.minY), options: [])
    ctx.restoreGState()

    // Specular highlight + rim
    ctx.setFillColor(cg(1, 1, 1, 0.22))
    let hl = orbR * 0.5
    ctx.fillEllipse(in: CGRect(x: center.x - orbR * 0.45, y: center.y + orbR * 0.1, width: hl, height: hl))
    ctx.setStrokeColor(cg(1, 1, 1, 0.18)); ctx.setLineWidth(max(1, s * 0.008))
    ctx.strokeEllipse(in: orbRect)

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Mnemosyne.icns"
let fm = FileManager.default
let iconset = NSTemporaryDirectory() + "Mnemosyne-\(UUID().uuidString).iconset"
try! fm.createDirectory(atPath: iconset, withIntermediateDirectories: true)

// (base point size, scale) -> filename
let variants: [(Int, Int)] = [(16,1),(16,2),(32,1),(32,2),(128,1),(128,2),(256,1),(256,2),(512,1),(512,2)]
for (pt, scale) in variants {
    let px = pt * scale
    let name = scale == 1 ? "icon_\(pt)x\(pt).png" : "icon_\(pt)x\(pt)@2x.png"
    try! render(px: px).write(to: URL(fileURLWithPath: iconset + "/" + name))
}

let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset, "-o", out]
try! p.run(); p.waitUntilExit()
try? fm.removeItem(atPath: iconset)
print(p.terminationStatus == 0 ? "✓ wrote \(out)" : "✗ iconutil failed")
exit(p.terminationStatus)
