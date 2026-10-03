@testable import BreatheCore
import Testing

@Suite("The easing")
struct EasingTests {
    @Test func spansZeroToOneAndNeverGoesBackwards() {
        #expect(abs(Breath.ease(0)) < 1e-12)
        #expect(abs(Breath.ease(1) - 1) < 1e-12)
        var previous = -1.0
        for step in 0...1000 {
            let value = Breath.ease(Double(step) / 1000)
            #expect(value >= previous)
            previous = value
        }
    }

    @Test func clampsOutsideTheUnitInterval() {
        #expect(Breath.ease(-3) == Breath.ease(0))
        #expect(Breath.ease(9) == Breath.ease(1))
    }

    @Test func isSlowerAtTheTurnaroundsThanMidPhase() {
        let step = 0.02
        let atEdge = Breath.ease(step) - Breath.ease(0)
        let atMiddle = Breath.ease(0.5 + step) - Breath.ease(0.5)
        #expect(atMiddle > atEdge * 3)
    }

    @Test func fullnessRunsFullAtTheTopAndEmptyAtTheBottom() {
        #expect(Breath.fullness(.inhale, progress: 0) == 0)
        #expect(abs(Breath.fullness(.inhale, progress: 1) - 1) < 1e-12)
        #expect(Breath.fullness(.exhale, progress: 0) == 1)
        #expect(abs(Breath.fullness(.exhale, progress: 1)) < 1e-12)
        #expect(Breath.fullness(.holdIn, progress: 0.5) == 1)
        #expect(Breath.fullness(.holdOut, progress: 0.5) == 0)
    }
}

@Suite("The orb")
struct OrbTests {
    @Test func radiusHitsBothEnds() {
        #expect(abs(OrbStyle.orbRadius(fullness: 0) - OrbStyle.minRadius) < 1e-12)
        #expect(abs(OrbStyle.orbRadius(fullness: 1) - OrbStyle.maxRadius) < 1e-12)
    }

    @Test("Half fullness is half the area, so the radius is above the midpoint")
    func interpolatesAreaNotRadius() {
        let half = OrbStyle.orbRadius(fullness: 0.5)
        let midArea = (OrbStyle.minRadius * OrbStyle.minRadius + OrbStyle.maxRadius * OrbStyle.maxRadius) / 2
        #expect(abs(half * half - midArea) < 1e-9)
        #expect(half > (OrbStyle.minRadius + OrbStyle.maxRadius) / 2)
    }

    @Test("The orb never freezes late in the inhale: it grows on every frame")
    func neverFreezesLateInTheInhale() {
        // The regression breathe.py's render tests exist for: ease() flattens
        // hard at the turnaround, and whole-pixel sizes held the orb still for
        // a dozen frames before jumping it. Sizes here are continuous.
        var previous = 0.0
        for frame in 0..<60 {
            let reading = BreathPattern.standard.reading(at: 3 + Double(frame) / 60)
            let radius = OrbStyle.frame(fullness: reading.fullness, paused: false, drift: reading.elapsed).radius
            #expect(radius > previous)
            previous = radius
        }
    }

    @Test func reddensAsItFills() {
        let empty = OrbStyle.frame(fullness: 0, paused: false, drift: 0).color
        let full = OrbStyle.frame(fullness: 1, paused: false, drift: 4).color
        #expect(full.red > empty.red)
        #expect(full.green < empty.green)
        #expect(full.blue < empty.blue)
    }

    @Test func pausingGreysTheOrbAndKillsTheHalo() {
        let live = OrbStyle.frame(fullness: 1, paused: false, drift: 4)
        let held = OrbStyle.frame(fullness: 1, paused: true, drift: 4)
        #expect(held.color.red < live.color.red)
        #expect(!live.halo.isEmpty)
        #expect(held.halo.isEmpty)
        #expect(held.radius == live.radius)
    }

    @Test func emptyLungsHaveNoHalo() {
        #expect(OrbStyle.frame(fullness: 0, paused: false, drift: 3).halo.isEmpty)
    }

    @Test("The halo drifts, so two moments never match")
    func haloDrifts() {
        let a = OrbStyle.frame(fullness: 1, paused: false, drift: 4)
        let b = OrbStyle.frame(fullness: 1, paused: false, drift: 7.3)
        #expect(a.halo != b.halo)
        #expect(a.radius == b.radius)
        #expect(a.color == b.color)
    }

    @Test("Every lobe glows beyond the orb and stays centred near it")
    func lobesStayAroundTheOrb() {
        for step in 0..<200 {
            let frame = OrbStyle.frame(fullness: 1, paused: false, drift: Double(step) * 0.37)
            #expect(frame.halo.count == 4)
            for lobe in frame.halo {
                let dx = lobe.center.x - OrbStyle.orbCenter.x
                let dy = lobe.center.y - OrbStyle.orbCenter.y
                #expect((dx * dx + dy * dy).squareRoot() <= OrbStyle.maxRadius * 0.5)
                #expect(lobe.radius > OrbStyle.maxRadius * 0.5)
                #expect(lobe.opacity > 0 && lobe.opacity < 0.5)
            }
        }
    }

    @Test func glowIsSolidInTheCoreAndFadesToNothing() {
        #expect(OrbStyle.glowFalloff(at: 0) == 1)
        #expect(OrbStyle.glowFalloff(at: 1 / OrbStyle.glowSpan) == 1)
        #expect(OrbStyle.glowFalloff(at: 1) == 0)
        var previous = 1.0
        for step in 0...100 {
            let value = OrbStyle.glowFalloff(at: Double(step) / 100)
            #expect(value <= previous)
            previous = value
        }
    }

    @Test func blendingHitsBothEnds() {
        let a = RGB(0, 0, 0)
        let b = RGB(10, 20, 30)
        #expect(a.blended(toward: b, by: 0) == a)
        #expect(a.blended(toward: b, by: 1) == b)
        #expect(a.blended(toward: b, by: 0.5) == RGB(5, 10, 15))
    }
}
