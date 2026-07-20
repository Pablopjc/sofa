import Foundation

// Mirror of Updater.isAcceptableRequirement for the standalone harness (the
// app target can't be linked into a script). Keep in lockstep with
// Sources/Sofa/Updater.swift — the release checklist runs this harness, and a
// drift between the two is exactly the bug it exists to catch, so the logic is
// asserted equal by scripts/check-trust-rule.sh during release.
enum TrustRule {
    static func isAcceptable(installed: String, downloaded: String) -> Bool {
        if installed == downloaded { return true }
        return downloaded.contains("identifier \"com.pablo.sofa.native\"")
            && downloaded.contains("anchor apple generic")
            && downloaded.contains("certificate leaf[field.1.2.840.113635.100.6.1.13]")
            && downloaded.contains("certificate leaf[subject.OU] = SX87SFWP3N")
    }
}
