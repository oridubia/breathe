import BreatheCore
import SwiftUI

/// breathe.py's floating window, drawn: the target ring, the halo, the orb,
/// and the white count tab on top so the halo never tints it.
struct OrbCanvas: View {
    let orb: OrbFrame
    let label: TabLabel

    var body: some View {
        Canvas { context, size in
            OrbPainter(size: size).paint(orb, label: label, in: &context)
        }
    }
}

/// Maps the 280 x 250 design box onto the canvas and draws in it.
private struct OrbPainter {
    let scale: Double
    let origin: CGPoint

    init(size: CGSize) {
        // Fill the width of a phone; stop growing on an iPad.
        let width = Double(size.width)
        let height = Double(size.height)
        scale = min(width / OrbStyle.width, height / OrbStyle.height, 2.4)
        origin = CGPoint(
            x: (width - OrbStyle.width * scale) / 2,
            y: (height - OrbStyle.height * scale) * 0.45
        )
    }

    func paint(_ orb: OrbFrame, label: TabLabel, in context: inout GraphicsContext) {
        // The ring's inner edge is where the orb peaks.
        let ringRadius = OrbStyle.maxRadius + OrbStyle.ringWidth / 2
        context.stroke(
            circle(at: OrbStyle.orbCenter, radius: ringRadius),
            with: .color(Color(OrbStyle.ringColor, opacity: OrbStyle.ringOpacity)),
            lineWidth: OrbStyle.ringWidth * scale
        )

        for lobe in orb.halo {
            context.fill(
                circle(at: lobe.center, radius: lobe.radius),
                with: .radialGradient(
                    Self.glow(lobe), center: point(lobe.center),
                    startRadius: 0, endRadius: lobe.radius * scale
                )
            )
        }

        context.fill(circle(at: OrbStyle.orbCenter, radius: orb.radius), with: .color(Color(orb.color)))

        context.drawLayer { layer in
            layer.addFilter(.shadow(
                color: Color(OrbStyle.tabShadowColor, opacity: OrbStyle.tabShadowOpacity),
                radius: 2 * scale, x: 0, y: 2 * scale
            ))
            layer.fill(circle(at: OrbStyle.tabCenter, radius: OrbStyle.tabDiameter / 2), with: .color(Color(OrbStyle.tabColor)))
        }
        context.draw(text(for: label), at: point(OrbStyle.tabCenter))
    }

    private func point(_ design: DesignPoint) -> CGPoint {
        CGPoint(x: Double(origin.x) + design.x * scale, y: Double(origin.y) + design.y * scale)
    }

    /// A circle given in design units.
    private func circle(at center: DesignPoint, radius: Double) -> Path {
        let middle = point(center)
        let r = CGFloat(radius * scale)
        return Path(ellipseIn: CGRect(x: middle.x - r, y: middle.y - r, width: r * 2, height: r * 2))
    }

    private func text(for label: TabLabel) -> Text {
        let size = OrbStyle.countFontSize * scale
        let ink = Color(OrbStyle.tabInk)
        switch label {
        case .count(let count):
            return Text(verbatim: "\(count)")
                .font(.system(size: size, weight: .medium, design: .rounded).monospacedDigit())
                .foregroundStyle(ink)
        case .start:
            return Text(Image(systemName: "play.fill"))
                .font(.system(size: size * 0.8))
                .foregroundStyle(ink)
        }
    }

    private static func glow(_ lobe: HaloLobe) -> Gradient {
        Gradient(stops: falloff.map { stop in
            Gradient.Stop(color: Color(lobe.tint, opacity: lobe.opacity * stop.opacity), location: stop.location)
        })
    }

    /// The lobe falloff as gradient stops: solid through the core, then the
    /// k^2.3 tail, sampled once.
    private static let falloff: [(location: Double, opacity: Double)] = {
        let core = 1 / OrbStyle.glowSpan
        let tail = (0...12).map { step in
            let location = core + (1 - core) * Double(step) / 12
            return (location: location, opacity: OrbStyle.glowFalloff(at: location))
        }
        return [(location: 0, opacity: 1)] + tail
    }()
}

extension Color {
    /// A colour from breathe.py's 0-255 sRGB triples.
    init(_ rgb: RGB, opacity: Double = 1) {
        self.init(.sRGB, red: rgb.red / 255, green: rgb.green / 255, blue: rgb.blue / 255, opacity: opacity)
    }
}
