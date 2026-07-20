import Foundation

// Exercises Updater.isAcceptableRequirement — the rule that decides whether a
// downloaded build may replace the installed one. Compile with Updater's trust
// logic extracted via the shared source file:
//   swiftc -o /tmp/ut Tests/UpdaterTrustHarness/main.swift Tests/UpdaterTrustHarness/TrustRule.swift && /tmp/ut
// (TrustRule.swift is generated from Updater.swift by the harness runner in
// release checks; see CLAUDE.md.)

private var failures = 0
private func check(_ condition: Bool, _ name: String) {
    if !condition {
        failures += 1
        fputs("FAIL: \(name)\n", stderr)
    }
}

let selfSigned = #"designated => identifier "com.pablo.sofa.native" and certificate leaf = H"4b1ce5ae28ba8cc2c9ecfc1df98e41eb2ecda20a""#
let developerID = #"designated => identifier "com.pablo.sofa.native" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] /* exists */ and certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */ and certificate leaf[subject.OU] = SX87SFWP3N"#
let otherTeam = developerID.replacingOccurrences(of: "SX87SFWP3N", with: "EVIL000000")
let otherBundle = developerID.replacingOccurrences(of: "com.pablo.sofa.native", with: "com.evil.sofa")
let adhocLike = #"designated => identifier "com.pablo.sofa.native" and cdhash H"deadbeef""#

check(TrustRule.isAcceptable(installed: selfSigned, downloaded: selfSigned),
      "self-signed to identical self-signed")
check(TrustRule.isAcceptable(installed: developerID, downloaded: developerID),
      "Developer ID to identical Developer ID")
check(TrustRule.isAcceptable(installed: selfSigned, downloaded: developerID),
      "one-time upgrade: self-signed install accepts Developer ID build")
check(!TrustRule.isAcceptable(installed: selfSigned, downloaded: otherTeam),
      "rejects another team's Developer ID")
check(!TrustRule.isAcceptable(installed: selfSigned, downloaded: otherBundle),
      "rejects another bundle identifier")
check(!TrustRule.isAcceptable(installed: selfSigned, downloaded: adhocLike),
      "rejects ad-hoc style requirement")
check(!TrustRule.isAcceptable(installed: developerID, downloaded: selfSigned),
      "no downgrade: Developer ID install rejects self-signed build")

if failures > 0 { exit(1) }
print("Updater trust rule: 7 checks passed")
