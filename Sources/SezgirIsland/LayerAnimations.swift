import AppKit
import QuartzCore
import SwiftUI

// Looping indicators (equalizer, spinning spark, pulse) run as Core Animation animations.
// The render server plays them, so the app does no per-frame work at all: no SwiftUI
// graph updates, no layout, no redraws. A SwiftUI TimelineView at 30 fps cost ~13 % of a core.

private func cg(_ c: Color) -> CGColor { NSColor(c).cgColor }

private func withoutActions(_ body: () -> Void) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    body()
    CATransaction.commit()
}

/// Base for small layer-hosting views: not interactive, never redrawn by AppKit.
class AnimationHostView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil } // clicks go to the SwiftUI button around us
}

// MARK: - Equalizer

struct AudioBars: View {
    let color: Color
    let playing: Bool
    let height: CGFloat

    var body: some View {
        AudioBarsRepresentable(color: color, playing: playing)
            .frame(width: AudioBarsView.width, height: height)
            .accessibilityHidden(true)
    }
}

private struct AudioBarsRepresentable: NSViewRepresentable {
    let color: Color
    let playing: Bool

    func makeNSView(context: Context) -> AudioBarsView { AudioBarsView() }

    func updateNSView(_ v: AudioBarsView, context: Context) {
        v.color = cg(color)
        v.playing = playing
    }
}

final class AudioBarsView: AnimationHostView {
    static let barWidth: CGFloat = 2.8
    static let gap: CGFloat = 2.2
    static let width = 4 * barWidth + 3 * gap

    // Hand-made "random" levels per bar; each bar loops at its own speed so the pattern never lines up.
    private static let levels: [[CGFloat]] = [
        [0.35, 1.0, 0.55, 0.85, 0.3, 0.75, 0.45, 0.35],
        [0.8, 0.4, 1.0, 0.5, 0.9, 0.35, 0.65, 0.8],
        [0.5, 0.9, 0.3, 1.0, 0.6, 0.4, 0.85, 0.5],
        [0.7, 0.3, 0.8, 0.45, 1.0, 0.55, 0.35, 0.7],
    ]
    private static let durations: [CFTimeInterval] = [1.15, 1.4, 0.98, 1.27]

    private let bars: [CALayer] = (0..<4).map { _ in CALayer() }
    private var laidOutHeight: CGFloat = -1

    var color: CGColor = NSColor.white.cgColor {
        didSet {
            guard color != oldValue else { return }
            withoutActions { bars.forEach { $0.backgroundColor = color } }
        }
    }

    var playing = false {
        didSet { if playing != oldValue { refresh(animatedStop: true) } }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        for b in bars {
            b.cornerRadius = Self.barWidth / 2
            b.backgroundColor = color
            layer?.addSublayer(b)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    private var restHeight: CGFloat { max(Self.barWidth, bounds.height * 0.2) }

    override func layout() {
        super.layout()
        withoutActions {
            for (i, b) in bars.enumerated() {
                b.bounds = CGRect(x: 0, y: 0, width: Self.barWidth, height: restHeight)
                b.position = CGPoint(x: CGFloat(i) * (Self.barWidth + Self.gap) + Self.barWidth / 2, y: bounds.midY)
            }
        }
        if bounds.height != laidOutHeight {
            laidOutHeight = bounds.height
            refresh(animatedStop: false)
        }
    }

    private func refresh(animatedStop: Bool) {
        guard bounds.height > 0 else { return }
        for (i, b) in bars.enumerated() {
            if playing {
                let a = CAKeyframeAnimation(keyPath: "bounds.size.height")
                a.values = Self.levels[i].map { max(Self.barWidth, bounds.height * $0) }
                a.duration = Self.durations[i]
                a.calculationMode = .cubic
                a.repeatCount = .infinity
                a.timeOffset = Double(i) * 0.37
                b.add(a, forKey: "eq")
            } else {
                let current = b.presentation()?.bounds.height ?? restHeight
                b.removeAnimation(forKey: "eq")
                if animatedStop && current != restHeight {
                    let a = CABasicAnimation(keyPath: "bounds.size.height")
                    a.fromValue = current
                    a.toValue = restHeight
                    a.duration = 0.25
                    a.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    b.add(a, forKey: "settle")
                }
            }
        }
    }
}

// MARK: - Claude spark

struct ClaudeSpark: View {
    var size: CGFloat
    var spinning: Bool
    var color: Color = claudeOrange

    var body: some View {
        SparkRepresentable(size: size, spinning: spinning, color: color)
            .frame(width: size * 1.7, height: size * 1.7)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

private struct SparkRepresentable: NSViewRepresentable {
    let size: CGFloat
    let spinning: Bool
    let color: Color

    func makeNSView(context: Context) -> SparkView { SparkView() }

    func updateNSView(_ v: SparkView, context: Context) {
        v.update(size: size, spinning: spinning, color: cg(color))
    }
}

final class SparkView: AnimationHostView {
    private let glow = CAGradientLayer()
    private let spinner = CALayer()     // rotates
    private let spark = CAShapeLayer()  // breathes
    private var size: CGFloat = 0
    private var spinning = false
    private var color: CGColor = NSColor.white.cgColor

    override init(frame: NSRect) {
        super.init(frame: frame)
        glow.type = .radial
        glow.startPoint = CGPoint(x: 0.5, y: 0.5)
        glow.endPoint = CGPoint(x: 1, y: 1)
        layer?.addSublayer(glow)
        spinner.addSublayer(spark)
        layer?.addSublayer(spinner)
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(size: CGFloat, spinning: Bool, color: CGColor) {
        let sizeChanged = size != self.size
        let colorChanged = color != self.color
        let spinChanged = spinning != self.spinning
        guard sizeChanged || colorChanged || spinChanged else { return }
        self.size = size
        self.color = color
        self.spinning = spinning
        withoutActions {
            if sizeChanged {
                spark.path = SparkShape().path(in: CGRect(x: 0, y: 0, width: size, height: size)).cgPath
                spark.bounds = CGRect(x: 0, y: 0, width: size, height: size)
            }
            spark.fillColor = color
            let a = NSColor(cgColor: color)?.alphaComponent ?? 1
            glow.colors = [color.copy(alpha: a * (spinning ? 0.35 : 0.18)) ?? color, color.copy(alpha: 0) ?? color]
        }
        if spinChanged || sizeChanged { applyAnimations() }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        withoutActions {
            glow.frame = bounds
            spinner.bounds = CGRect(x: 0, y: 0, width: size, height: size)
            spinner.position = CGPoint(x: bounds.midX, y: bounds.midY)
            spark.position = CGPoint(x: size / 2, y: size / 2)
        }
    }

    private func applyAnimations() {
        spinner.removeAnimation(forKey: "spin")
        spark.removeAnimation(forKey: "breathe")
        guard spinning else { return }
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = -2 * Double.pi // clockwise in the flipped-y sense of the old Canvas version
        spin.duration = 3.9
        spin.repeatCount = .infinity
        spinner.add(spin, forKey: "spin")

        let breathe = CABasicAnimation(keyPath: "transform.scale")
        breathe.fromValue = 0.9
        breathe.toValue = 1.0
        breathe.duration = 0.98
        breathe.autoreverses = true
        breathe.repeatCount = .infinity
        breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        spark.add(breathe, forKey: "breathe")
    }
}

// MARK: - Pulse

/// A softly pulsing filled circle ("Claude is waiting").
struct PulseCircle: View {
    let color: Color

    var body: some View {
        PulseRepresentable(color: color).accessibilityHidden(true)
    }
}

private struct PulseRepresentable: NSViewRepresentable {
    let color: Color

    func makeNSView(context: Context) -> PulseView { PulseView() }

    func updateNSView(_ v: PulseView, context: Context) { v.color = cg(color) }
}

final class PulseView: AnimationHostView {
    private let dot = CALayer()

    var color: CGColor = NSColor.white.cgColor {
        didSet { if color != oldValue { withoutActions { dot.backgroundColor = color } } }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        dot.backgroundColor = color
        dot.opacity = 0.12
        layer?.addSublayer(dot)
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = 0.12
        a.toValue = 0.35
        a.duration = 0.9
        a.autoreverses = true
        a.repeatCount = .infinity
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        dot.add(a, forKey: "pulse")
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        withoutActions {
            dot.frame = bounds
            dot.cornerRadius = min(bounds.width, bounds.height) / 2
        }
    }
}
