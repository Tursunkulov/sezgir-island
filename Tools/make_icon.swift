import AppKit
// Draws the app icon: dark squircle, glowing island pill with artwork dot + bars.
func render(_ px: Int) -> Data {
  let s = CGFloat(px)
  let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
  let inset = s * 0.1, r = NSRect(x: inset, y: inset, width: s - inset*2, height: s - inset*2)
  let sq = NSBezierPath(roundedRect: r, xRadius: r.width * 0.225, yRadius: r.width * 0.225)
  NSGradient(colors: [NSColor(red: 0.16, green: 0.12, blue: 0.22, alpha: 1), NSColor(red: 0.05, green: 0.05, blue: 0.08, alpha: 1)])!.draw(in: sq, angle: -90)
  // glow
  let glow = NSRect(x: r.midX - r.width*0.36, y: r.midY - r.height*0.02, width: r.width*0.72, height: r.height*0.3)
  NSGradient(colors: [NSColor(red: 0.85, green: 0.47, blue: 0.34, alpha: 0.55), .clear])!.draw(in: NSBezierPath(ovalIn: glow), relativeCenterPosition: .zero)
  // pill
  let pw = r.width * 0.66, ph = r.height * 0.2
  let pill = NSRect(x: r.midX - pw/2, y: r.midY + r.height*0.02, width: pw, height: ph)
  NSColor.black.setFill(); NSBezierPath(roundedRect: pill, xRadius: ph/2, yRadius: ph/2).fill()
  NSColor.white.withAlphaComponent(0.08).setStroke(); let st = NSBezierPath(roundedRect: pill.insetBy(dx: 1, dy: 1), xRadius: ph/2, yRadius: ph/2); st.lineWidth = s*0.004; st.stroke()
  // artwork dot
  let d = ph * 0.62
  let art = NSRect(x: pill.minX + (ph-d)/2 + ph*0.1, y: pill.midY - d/2, width: d, height: d)
  NSGradient(colors: [NSColor(red: 0.95, green: 0.55, blue: 0.38, alpha: 1), NSColor(red: 0.78, green: 0.32, blue: 0.25, alpha: 1)])!.draw(in: NSBezierPath(roundedRect: art, xRadius: d*0.28, yRadius: d*0.28), angle: -60)
  // bars
  let heights: [CGFloat] = [0.45, 0.85, 0.6, 0.95, 0.5]
  let bw = ph * 0.1, gap = ph * 0.075
  var x = pill.maxX - ph*0.32 - CGFloat(heights.count) * (bw + gap)
  NSColor(red: 0.95, green: 0.6, blue: 0.45, alpha: 1).setFill()
  for h in heights { let bh = ph * 0.55 * h; NSBezierPath(roundedRect: NSRect(x: x, y: pill.midY - bh/2, width: bw, height: bh), xRadius: bw/2, yRadius: bw/2).fill(); x += bw + gap }
  // sparkle under pill
  let c = NSPoint(x: r.midX, y: r.minY + r.height*0.27), R = r.width*0.085
  let star = NSBezierPath()
  for i in 0..<8 { let a = CGFloat(i) * .pi/4 + .pi/2; let rr = i % 2 == 0 ? R : R*0.32
    let p = NSPoint(x: c.x + cos(a)*rr, y: c.y + sin(a)*rr); i == 0 ? star.move(to: p) : star.line(to: p) }
  star.close(); NSColor(red: 0.85, green: 0.47, blue: 0.34, alpha: 1).setFill(); star.fill()
  NSGraphicsContext.restoreGraphicsState()
  return rep.representation(using: .png, properties: [:])!
}
let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
for (name, px) in [("16x16",16),("16x16@2x",32),("32x32",32),("32x32@2x",64),("128x128",128),("128x128@2x",256),("256x256",256),("256x256@2x",512),("512x512",512),("512x512@2x",1024)] {
  try! render(px).write(to: URL(fileURLWithPath: "\(out)/icon_\(name).png"))
}
