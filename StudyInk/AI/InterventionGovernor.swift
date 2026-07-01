import SwiftUI

/// The tutor's politeness layer (refinement P3): every PROACTIVE surface asks the
/// governor first. It enforces
///  - a cooldown between proactive suggestions (sensitivity-driven, ~90s on Helpful),
///  - a per-session cap,
///  - type suppression — dismissing two suggestions of the same type silences that
///    type for the rest of the session (accepting one forgives past dismissals),
///  - the idle threshold the arbiter waits before firing, per sensitivity.
/// Manual actions (buttons, circle-ask, chat) never consult the governor.
@MainActor
final class InterventionGovernor: ObservableObject {

    /// The proactive surface types the governor arbitrates.
    enum Kind: String, CaseIterable {
        case ghost        // idle next-step suggestion
        case gradeOffer   // "find my mistake" pill
        case stuckHint    // stuck-signal fast-track offer
    }

    struct Thresholds {
        /// Pen-idle time before the arbiter fires at all.
        var idleDelay: TimeInterval
        /// Minimum gap between two proactive surfaces.
        var cooldown: TimeInterval
        /// Max proactive surfaces per app session.
        var sessionCap: Int
    }

    /// Sensitivity = eligibility AND pace (handoff §3.5 + refinement P3).
    static func thresholds(for s: AmbientSensitivity) -> Thresholds {
        switch s {
        case .off:     return Thresholds(idleDelay: .infinity, cooldown: .infinity, sessionCap: 0)
        case .subtle:  return Thresholds(idleDelay: 8.0, cooldown: 150, sessionCap: 6)
        case .helpful: return Thresholds(idleDelay: 3.9, cooldown: 90, sessionCap: 14)
        }
    }

    private var lastShownAt: Date?
    private var shownCount = 0
    private var dismissals: [Kind: Int] = [:]

    /// May a proactive surface of this kind be shown now?
    /// `bypassCooldown` is for a follow-up surface shown in the SAME pause (the
    /// arbiter emits at most one "loud" surface; the quiet grade pill may ride along).
    func mayOffer(_ kind: Kind, sensitivity: AmbientSensitivity, bypassCooldown: Bool = false) -> Bool {
        let t = Self.thresholds(for: sensitivity)
        guard t.sessionCap > 0 else { return false }
        guard shownCount < t.sessionCap else { return false }
        guard (dismissals[kind] ?? 0) < 2 else { return false }   // suppressed for the session
        if !bypassCooldown, let last = lastShownAt,
           Date().timeIntervalSince(last) < t.cooldown { return false }
        return true
    }

    func noteShown(_ kind: Kind) {
        lastShownAt = Date()
        shownCount += 1
    }

    /// The student explicitly dismissed a suggestion of this type (x / flick-left).
    func noteDismissed(_ kind: Kind) {
        dismissals[kind, default: 0] += 1
    }

    /// The student engaged (accepted / opened / asked) — that type is welcome again,
    /// and the interaction resets the pace so help doesn't feel rationed mid-flow.
    func noteAccepted(_ kind: Kind) {
        dismissals[kind] = 0
    }
}

/// Local stuck-detection signals (refinement P3) — no AI call, just pen telemetry.
/// Currently: repeated erasing in the same region (≥3 erase gestures within a
/// ~200pt-radius region inside one minute) ⇒ the student is likely stuck there.
@MainActor
final class StuckDetector {
    private var eraseEvents: [(center: CGPoint, at: Date)] = []

    /// Record an erase gesture; returns true when it completes a stuck pattern.
    func noteErase(at center: CGPoint) -> Bool {
        let now = Date()
        eraseEvents.removeAll { now.timeIntervalSince($0.at) > 60 }
        eraseEvents.append((center, now))
        let near = eraseEvents.filter { hypot($0.center.x - center.x, $0.center.y - center.y) < 200 }
        if near.count >= 3 {
            eraseEvents.removeAll()   // fire once, then re-arm fresh
            return true
        }
        return false
    }

    func reset() { eraseEvents.removeAll() }
}
