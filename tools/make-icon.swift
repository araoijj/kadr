// Рисует иконку «Кадр»: диафрагма объектива в рамке кадра.
// Запуск: swift tools/make-icon.swift Resources/AppIcon-1024.png
import AppKit
import CoreGraphics

let S: CGFloat = 1024
let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon-1024.png")

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

// Подложка по сетке иконок macOS: 824×824, скругление ~185, без тени.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let bodyPath = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.saveGState()
ctx.addPath(bodyPath)
ctx.clip()
let bg = CGGradient(colorsSpace: cs, colors: [rgb(0x30333B), rgb(0x131418)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
ctx.restoreGState()
ctx.addPath(bodyPath)
ctx.setStrokeColor(rgb(0xFFFFFF, 0.08))
ctx.setLineWidth(4)
ctx.strokePath()

// Уголки рамки кадра.
ctx.setStrokeColor(rgb(0xF2F2F4, 0.9))
ctx.setLineWidth(26)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)
let m: CGFloat = 228, arm: CGFloat = 112
for (x, y, dx, dy) in [(m, m, 1.0, 1.0), (S - m, m, -1.0, 1.0), (m, S - m, 1.0, -1.0), (S - m, S - m, -1.0, -1.0)] {
    ctx.move(to: CGPoint(x: x, y: y + dy * arm))
    ctx.addLine(to: CGPoint(x: x, y: y))
    ctx.addLine(to: CGPoint(x: x + dx * arm, y: y))
    ctx.strokePath()
}

// Диафрагма: 6 лепестков вокруг шестиугольного отверстия.
let c = CGPoint(x: 512, y: 512)
let R: CGFloat = 198, rIn: CGFloat = 78
let colors: [UInt32] = [0xFFC24B, 0xFF8A3D, 0xFF5A5F, 0xE8457F, 0xB04FD8, 0x6F6CFF]
let v = (0..<6).map { i -> CGPoint in
    let a = CGFloat(i) * .pi / 3 + .pi / 2
    return CGPoint(x: c.x + rIn * cos(a), y: c.y + rIn * sin(a))
}
// Луч от вершины v[i] по продолжению ребра v[i-1]→v[i] до окружности.
func hit(_ i: Int) -> CGPoint {
    let p = v[i], q = v[(i + 5) % 6]
    var d = CGPoint(x: p.x - q.x, y: p.y - q.y)
    let len = hypot(d.x, d.y); d = CGPoint(x: d.x / len, y: d.y / len)
    let fx = p.x - c.x, fy = p.y - c.y
    let b = fx * d.x + fy * d.y, cc = fx * fx + fy * fy - R * R
    let t = -b + sqrt(b * b - cc)
    return CGPoint(x: p.x + d.x * t, y: p.y + d.y * t)
}
let p = (0..<6).map(hit)
for i in 0..<6 {
    let j = (i + 1) % 6
    let a1 = atan2(p[i].y - c.y, p[i].x - c.x), a2 = atan2(p[j].y - c.y, p[j].x - c.x)
    var delta = a2 - a1
    while delta <= -.pi { delta += 2 * .pi }
    while delta > .pi { delta -= 2 * .pi }
    let path = CGMutablePath()
    path.move(to: v[i])
    path.addLine(to: p[i])
    path.addArc(center: c, radius: R, startAngle: a1, endAngle: a2, clockwise: delta < 0)
    path.addLine(to: v[i])
    path.closeSubpath()
    ctx.addPath(path)
    ctx.setFillColor(rgb(colors[i]))
    ctx.fillPath()
}
// Зазоры между лепестками и отверстие.
ctx.setStrokeColor(rgb(0x17181C))
ctx.setLineWidth(11)
ctx.setLineCap(.butt)
for i in 0..<6 {
    ctx.move(to: v[(i + 5) % 6])
    ctx.addLine(to: p[i])
    ctx.strokePath()
}
let hole = CGMutablePath()
hole.addLines(between: v)
hole.closeSubpath()
ctx.addPath(hole)
ctx.setFillColor(rgb(0x17181C))
ctx.fillPath()
// Тонкое кольцо оправы.
ctx.addEllipse(in: CGRect(x: c.x - R - 14, y: c.y - R - 14, width: 2 * (R + 14), height: 2 * (R + 14)))
ctx.setStrokeColor(rgb(0xFFFFFF, 0.14))
ctx.setLineWidth(6)
ctx.strokePath()

let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: out)
print("icon:", out.path)
