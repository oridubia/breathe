import Foundation

/// An sRGB colour on breathe.py's 0-255 scale.
public struct RGB: Sendable, Equatable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(_ red: Double, _ green: Double, _ blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// Linear blend: `self` at 0, `other` at 1. breathe.py's lerp3, without
    /// the rounding to whole levels that only an 8-bit image needed.
    public func blended(toward other: RGB, by t: Double) -> RGB {
        RGB(red + (other.red - red) * t, green + (other.green - green) * t, blue + (other.blue - blue) * t)
    }
}

/// A point in design units: the points of breathe.py's 280 x 250 window.
public struct DesignPoint: Sendable, Equatable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// One soft lobe of the halo, in design units.
public struct HaloLobe: Sendable, Equatable {
    public let center: DesignPoint
    /// Radius of the whole glow, tail included.
    public let radius: Double
    /// Peak opacity, 0...1, held across the core; see `OrbStyle.glowFalloff`.
    public let opacity: Double
    public let tint: RGB
}

/// The orb as one frame shows it.
public struct OrbFrame: Sendable, Equatable {
    public let radius: Double
    public let color: RGB
    /// Drawn in order, under the orb.
    public let halo: [HaloLobe]
}

/// breathe.py's look: the target ring, the orb that grows toward it, the halo
/// drifting round it and the white count tab, in design units. A renderer
/// scales the 280 x 250 design box to fit and draws, in order: ring, halo,
/// orb, tab.
public enum OrbStyle {
    public static let width = 280.0
    public static let height = 250.0

    public static let orbCenter = DesignPoint(x: 140, y: 118)
    public static let minRadius = 16.0
    public static let maxRadius = 56.0

    /// The ring's inner edge is where the orb peaks.
    public static let ringWidth = 3.0
    public static let ringColor = RGB(196, 178, 156)
    public static let ringOpacity = 199.0 / 255.0

    /// Muted terracotta with empty lungs, cinnabar at full saturation.
    public static let restColor = RGB(198, 122, 100)
    public static let fullColor = RGB(220, 62, 34)
    public static let pausedColor = RGB(176, 158, 146)

    /// Halo diameter over orb diameter.
    public static let glowSpan = 1.9

    public static let tabCenter = DesignPoint(x: 140, y: 202)
    public static let tabDiameter = 34.0
    public static let tabColor = RGB(255, 255, 255)
    public static let tabInk = RGB(110, 88, 78)
    public static let tabShadowColor = RGB(84, 58, 46)
    public static let tabShadowOpacity = 66.0 / 255.0
    public static let countFontSize = 15.0

    /// Interpolates AREA, not radius, so the growth reads evenly to the eye.
    public static func orbRadius(fullness: Double) -> Double {
        let area = minRadius * minRadius + (maxRadius * maxRadius - minRadius * minRadius) * fullness
        return area.squareRoot()
    }

    /// A lobe's opacity at `fraction` of its radius, relative to its peak:
    /// solid across the inner 1 / `glowSpan`, then a k^2.3 falloff to nothing.
    public static func glowFalloff(at fraction: Double) -> Double {
        let core = 1 / glowSpan
        if fraction <= core {
            return 1
        }
        if fraction >= 1 {
            return 0
        }
        return pow(1 - (fraction - core) / (1 - core), 2.3)
    }

    /// Composes one frame. `drift` is how long the halo has been moving: the
    /// session's elapsed time, or a constant to hold it still.
    public static func frame(fullness: Double, paused: Bool, drift: Double) -> OrbFrame {
        let radius = orbRadius(fullness: fullness)
        var color = restColor.blended(toward: fullColor, by: min(1, pow(fullness, 1.15)))
        if paused {
            color = color.blended(toward: pausedColor, by: 0.55)
        }
        let intensity = paused ? 0 : pow(fullness, 2.6)
        let halo = intensity > 0.01
            ? lobes.compactMap { $0.lobe(orbRadius: radius, intensity: intensity, drift: drift) }
            : []
        return OrbFrame(radius: radius, color: color, halo: halo)
    }

    /// Four lobes, each on its own orbit, breathing size and intensity at
    /// unequal rates: the halo is never the same thickness twice round, and it
    /// keeps moving through the hold. Cosmetic only; nothing here feeds back
    /// into the clock.
    private static let lobes = [
        LobeMotion(tint: RGB(228, 80, 46), span: 0.72, orbit: 0.30, orbitRate: 0.23,
                   phase: 0.0, sizeRate: 0.31, alphaRate: 0.19, weight: 1.00),
        LobeMotion(tint: RGB(216, 58, 32), span: 0.86, orbit: 0.24, orbitRate: -0.17,
                   phase: 2.1, sizeRate: 0.24, alphaRate: 0.27, weight: 0.78),
        LobeMotion(tint: RGB(235, 104, 58), span: 0.62, orbit: 0.40, orbitRate: 0.13,
                   phase: 4.2, sizeRate: 0.37, alphaRate: 0.22, weight: 0.88),
        LobeMotion(tint: RGB(222, 70, 40), span: 0.95, orbit: 0.18, orbitRate: -0.29,
                   phase: 5.5, sizeRate: 0.19, alphaRate: 0.33, weight: 0.58),
    ]

    private struct LobeMotion {
        let tint: RGB
        let span: Double
        let orbit: Double
        let orbitRate: Double
        let phase: Double
        let sizeRate: Double
        let alphaRate: Double
        let weight: Double

        func lobe(orbRadius r: Double, intensity: Double, drift e: Double) -> HaloLobe? {
            let opacity = 118 / 255 * intensity * weight * (0.66 + 0.34 * sin(alphaRate * e + phase * 1.7))
            // breathe.py skips a lobe whose 8-bit peak truncates to zero.
            guard opacity >= 1 / 255 else { return nil }
            let diameter = max(2, r * 2 * OrbStyle.glowSpan * span * (1 + 0.22 * sin(sizeRate * e + phase)))
            let offset = r * orbit * (1 + 0.20 * sin(sizeRate * 0.7 * e + phase * 1.4))
            let angle = phase + orbitRate * e
            let center = DesignPoint(x: OrbStyle.orbCenter.x + cos(angle) * offset,
                                     y: OrbStyle.orbCenter.y + sin(angle) * offset)
            return HaloLobe(center: center, radius: diameter / 2, opacity: opacity, tint: tint)
        }
    }
}
