import Foundation

/// One automatic attempt per drawer; discovery changes and refresh must not
/// resend a stream that has already been sent or explicitly selected.
struct TVAutomaticPlayback {
    private(set) var attempted = false
    mutating func suppress() { attempted = true }
    mutating func claim(hasPlayback: Bool, deviceCount: Int, serviceCount: Int,
                        unresolvedCount: Int, moreComing: Bool, paired: Bool,
                        busy: Bool, active: Bool) -> Bool {
        guard !attempted, hasPlayback, deviceCount == 1, serviceCount == 1,
              unresolvedCount == 0, !moreComing, paired, !busy, active else { return false }
        attempted = true
        return true
    }
}

/// Android TV Remote v2 exposes volume keys and feedback rather than a portable
/// absolute-volume command. Reconcile a slider target against confirmed levels.
/// Stop at the closest reachable step instead of oscillating around odd levels.
struct TVVolumeAdjustment {
    let target: Int
    private var previousDistance: Int?
    private var correctedOvershoot = false
    init(fraction: Double, maximum: Int) {
        target = Int((min(1, max(0, fraction.isFinite ? fraction : 0)) * Double(max(0, maximum))).rounded())
    }
    mutating func nextKey(level: Int) -> UInt64? {
        let distance = abs(target - level)
        guard distance > 0, !correctedOvershoot else { return nil }
        if let previousDistance, distance >= previousDistance {
            guard distance > previousDistance else { return nil }
            // If a coarse hardware step landed farther away, undo it once.
            correctedOvershoot = true
            return level < target ? 24 : 25
        }
        previousDistance = distance
        return level < target ? 24 : 25
    }
}
