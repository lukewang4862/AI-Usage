import AppKit
let folder = CommandLine.arguments[1]
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let s = CGFloat(pixels)
        NSColor(calibratedWhite: 0.97, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: s*0.05, y: s*0.05, width: s*0.9, height: s*0.9), xRadius: s*0.21, yRadius: s*0.21).fill()
        let track = NSBezierPath(ovalIn: NSRect(x: s*0.18, y: s*0.18, width: s*0.64, height: s*0.64))
        track.lineWidth = s*0.07
        NSColor(calibratedRed: 0.86, green: 0.9, blue: 0.94, alpha: 1).setStroke(); track.stroke()
        let arc = NSBezierPath(); arc.appendArc(withCenter: NSPoint(x: s*0.5, y: s*0.5), radius: s*0.32, startAngle: 90, endAngle: -145, clockwise: true)
        arc.lineWidth = s*0.07; arc.lineCapStyle = .round
        NSColor(calibratedRed: 0.22, green: 0.75, blue: 0.47, alpha: 1).setStroke(); arc.stroke()
        let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center
        ("%" as NSString).draw(in: NSRect(x: 0, y: s*0.3, width: s, height: s*0.43), withAttributes: [.font: NSFont.systemFont(ofSize: s*0.33, weight: .medium), .foregroundColor: NSColor(calibratedWhite: 0.16, alpha: 1), .paragraphStyle: paragraph])
        image.unlockFocus()
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: folder + "/icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"))
    }
}
