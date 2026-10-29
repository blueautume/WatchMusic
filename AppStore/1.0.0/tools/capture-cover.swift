// Original, code-drawn demo artwork. No third-party photos or album graphics.
import AppKit

let output = CommandLine.arguments[1]
let size = NSSize(width: 1024, height: 1024)
let image = NSImage(size: size)
image.lockFocus()
let gradient = NSGradient(colors: [NSColor(srgbRed: 0.02, green: 0.09, blue: 0.20, alpha: 1),
                                   NSColor(srgbRed: 0.07, green: 0.38, blue: 0.61, alpha: 1),
                                   NSColor(srgbRed: 0.39, green: 0.76, blue: 0.79, alpha: 1)])!
gradient.draw(in: NSRect(origin: .zero, size: size), angle: 90)
NSColor(srgbRed: 1.0, green: 0.89, blue: 0.65, alpha: 1).setFill()
NSBezierPath(ovalIn: NSRect(x: 630, y: 610, width: 190, height: 190)).fill()
for (index, color) in [NSColor(srgbRed: 0.08, green: 0.29, blue: 0.43, alpha: 1),
                        NSColor(srgbRed: 0.04, green: 0.20, blue: 0.33, alpha: 1),
                        NSColor(srgbRed: 0.025, green: 0.13, blue: 0.24, alpha: 1)].enumerated() {
    let base = CGFloat(330 - index * 105)
    let path = NSBezierPath()
    path.move(to: NSPoint(x: 0, y: 0)); path.line(to: NSPoint(x: 0, y: base))
    path.curve(to: NSPoint(x: 1024, y: base + 25), controlPoint1: NSPoint(x: 320, y: base + 220), controlPoint2: NSPoint(x: 510, y: base - 170))
    path.line(to: NSPoint(x: 1024, y: 0)); path.close()
    color.setFill(); path.fill()
}
NSColor(srgbRed: 0.80, green: 0.96, blue: 0.98, alpha: 0.45).setStroke()
for n in 0..<5 {
    let y = CGFloat(105 + n * 25)
    let line = NSBezierPath()
    line.move(to: NSPoint(x: 485, y: y))
    line.curve(to: NSPoint(x: 900, y: y + 5), controlPoint1: NSPoint(x: 630, y: y + 27), controlPoint2: NSPoint(x: 770, y: y - 27))
    line.lineWidth = 2.5; line.stroke()
}
image.unlockFocus()
let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
