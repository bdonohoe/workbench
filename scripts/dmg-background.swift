// Draws the background of Workbench's disk image window: the app on the
// left, Applications on the right, and the icon's prompt chevron repeated
// between them in the burst's colors, pointing the way.
//
//   swift scripts/dmg-background.swift OUT_DIR
//
// Writes background.png (640x400) and background@2x.png. The icon spots
// here must match the positions in scripts/dmg-settings.py.
import AppKit

let size = CGSize(width: 640, height: 400)
let appSpot = CGPoint(x: 160, y: 180)   // from the top left, like Finder
let applicationsSpot = CGPoint(x: 480, y: 180)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

let navy: UInt32 = 0x1A2040
// The burst's petals, in order around the wheel.
let burst: [UInt32] = [0xF07890, 0xF0A070, 0xE8D47C, 0x7CE0A8, 0x70D4E8, 0x7CA4F0, 0xB48CF0, 0xF078C8]

func render(scale: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                               pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = context
    let cg = context.cgContext
    // Flip so y runs down, matching Finder's icon positions.
    cg.translateBy(x: 0, y: size.height)
    cg.scaleBy(x: 1, y: -1)

    // Paper: a soft cool white, a touch darker at the bottom.
    let paper = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                           colors: [color(0xF7F8FC), color(0xECEEF6)] as CFArray, locations: [0, 1])!
    cg.drawLinearGradient(paper, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])

    // A faint dot grid, like a terminal's character cells.
    cg.setFillColor(color(navy, 0.07))
    for x in stride(from: CGFloat(16), to: size.width, by: 16) {
        for y in stride(from: CGFloat(16), to: size.height, by: 16) {
            cg.fillEllipse(in: CGRect(x: x - 0.75, y: y - 0.75, width: 1.5, height: 1.5))
        }
    }

    // A soft wash of the burst's colors behind the chevrons.
    let mid = CGPoint(x: (appSpot.x + applicationsSpot.x) / 2, y: appSpot.y)
    for (i, hex) in [burst[0], burst[4], burst[6]].enumerated() {
        let center = CGPoint(x: mid.x - 40 + CGFloat(i) * 40, y: mid.y + (i == 1 ? -6 : 6))
        let glow = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                              colors: [color(hex, 0.20), color(hex, 0)] as CFArray, locations: [0, 1])!
        cg.drawRadialGradient(glow, startCenter: center, startRadius: 0, endCenter: center, endRadius: 90, options: [])
    }

    // Three prompt chevrons, the icon's ">" shape, fading in toward
    // Applications and colored across the burst.
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                              colors: burst.map { color($0) } as CFArray, locations: nil)!
    let chevronWidth: CGFloat = 20, chevronHeight: CGFloat = 40, gap: CGFloat = 30
    let firstX = mid.x - gap - chevronWidth / 2
    for i in 0..<3 {
        let left = firstX + CGFloat(i) * gap
        let path = CGMutablePath()
        path.move(to: CGPoint(x: left, y: mid.y - chevronHeight / 2))
        path.addLine(to: CGPoint(x: left + chevronWidth, y: mid.y))
        path.addLine(to: CGPoint(x: left, y: mid.y + chevronHeight / 2))
        let outline = path.copy(strokingWithWidth: 9, lineCap: .round, lineJoin: .round, miterLimit: 10)
        cg.saveGState()
        cg.setAlpha([0.35, 0.65, 1][i])
        cg.addPath(outline)
        cg.clip()
        cg.drawLinearGradient(gradient, start: CGPoint(x: firstX - 6, y: 0),
                              end: CGPoint(x: firstX + 2 * gap + chevronWidth + 6, y: 0), options: [])
        cg.restoreGState()
    }

    // The instruction, as a command at a prompt with a cursor after it.
    let mono = NSFont.monospacedSystemFont(ofSize: 13, weight: .medium)
    let prompt = NSAttributedString(string: "> ", attributes: [.font: mono, .foregroundColor: NSColor(cgColor: color(burst[0]))!])
    let command = NSAttributedString(string: "drag Workbench onto Applications",
                                     attributes: [.font: mono, .foregroundColor: NSColor(cgColor: color(navy, 0.72))!])
    let line = NSMutableAttributedString(attributedString: prompt)
    line.append(command)
    let cursorWidth: CGFloat = 8
    let textWidth = line.size().width + 3 + cursorWidth
    let baselineY: CGFloat = 330
    let textX = (size.width - textWidth) / 2
    // NSAttributedString draws in AppKit's unflipped space, so flip back
    // for the text alone.
    cg.saveGState()
    cg.translateBy(x: 0, y: size.height)
    cg.scaleBy(x: 1, y: -1)
    line.draw(at: CGPoint(x: textX, y: size.height - baselineY + mono.descender))
    cg.restoreGState()
    cg.setFillColor(color(navy, 0.55))
    cg.fill(CGRect(x: textX + textWidth - cursorWidth, y: baselineY - mono.ascender + 1,
                   width: cursorWidth, height: mono.ascender - mono.descender - 2))

    NSGraphicsContext.current = nil
    return rep
}

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
for (scale, name) in [(CGFloat(1), "background.png"), (CGFloat(2), "background@2x.png")] {
    let data = render(scale: scale).representation(using: .png, properties: [:])!
    try! data.write(to: outDir.appendingPathComponent(name))
}
