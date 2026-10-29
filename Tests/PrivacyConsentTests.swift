import Foundation

@main
struct PrivacyConsentTests {
    private static var checks = 0

    @MainActor
    static func main() {
        let suite = "WatchMusic.PrivacyConsentTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let instant = Date(timeIntervalSince1970: 1_793_232_000)
        let first = PrivacyConsentController(defaults: defaults, now: { instant })
        verify(!first.isAccepted && first.isPresentingConsent, "fresh install requires a decision")
        verify(defaults.object(forKey: PrivacyConsentPolicy.storageKey) == nil, "checking consent writes nothing")

        first.cancel()
        verify(first.state == .declined && !first.isPresentingConsent && !first.isAccepted,
               "cancel keeps the application gated")
        verify(defaults.object(forKey: PrivacyConsentPolicy.storageKey) == nil, "cancel never writes agreement")
        first.agree()
        verify(!first.isAccepted, "an action outside the presented decision cannot accept")
        first.review()
        verify(first.isPresentingConsent, "declined user can reopen the full decision")
        first.agree()
        let record = PrivacyConsentRecord(version: PrivacyConsentPolicy.currentVersion, acceptedAt: instant)
        verify(first.state == .accepted(record), "explicit agreement records version and time")
        verify(!first.isPresentingConsent, "agreement dismisses the decision")
        let savedData = defaults.data(forKey: PrivacyConsentPolicy.storageKey)!
        verify((try? JSONDecoder().decode(PrivacyConsentRecord.self, from: savedData)) == record,
               "persisted record matches the affirmative action")

        let restarted = PrivacyConsentController(defaults: defaults, now: { instant.addingTimeInterval(100) })
        verify(restarted.isAccepted && !restarted.isPresentingConsent, "cold launch skips accepted current agreements")
        restarted.agree()
        restarted.cancel()
        restarted.review()
        verify(defaults.data(forKey: PrivacyConsentPolicy.storageKey) == savedData,
               "duplicate or out-of-state events do not rewrite the record")
        verify(restarted.state == .accepted(record), "review cannot accidentally gate an accepted user")

        let updated = PrivacyConsentController(defaults: defaults, version: "2027-01-01", now: { instant.addingTimeInterval(200) })
        verify(!updated.isAccepted && updated.isPresentingConsent, "changed agreement version requires a fresh decision")
        updated.cancel()
        verify(defaults.data(forKey: PrivacyConsentPolicy.storageKey) == savedData,
               "declining a new version does not misrepresent an older record")
        updated.review(); updated.agree()
        verify(updated.isAccepted, "the new version can be accepted after reviewing again")
        verify(PrivacyConsentController(defaults: defaults, version: "2027-01-01").isAccepted,
               "the new version persists across controllers")

        defaults.set("shuffle", forKey: "player.mode")
        updated.withdraw()
        verify(!updated.isAccepted && updated.state == .declined, "withdrawal immediately closes the gate")
        verify(defaults.data(forKey: PrivacyConsentPolicy.storageKey) == nil, "withdrawal removes the agreement record")
        verify(defaults.string(forKey: "player.mode") == "shuffle", "withdrawal does not delete unrelated local preferences")
        verify(PrivacyConsentController(defaults: defaults).isPresentingConsent, "next launch asks again after withdrawal")

        defaults.set(Data("invalid JSON".utf8), forKey: PrivacyConsentPolicy.storageKey)
        verify(!PrivacyConsentController(defaults: defaults).isAccepted, "corrupt data never grants access")
        for date in [Date(timeIntervalSince1970: 0), Date(timeIntervalSince1970: -1)] {
            let invalid = PrivacyConsentRecord(version: PrivacyConsentPolicy.currentVersion, acceptedAt: date)
            defaults.set(try! JSONEncoder().encode(invalid), forKey: PrivacyConsentPolicy.storageKey)
            verify(!PrivacyConsentController(defaults: defaults).isAccepted, "invalid acceptance time never grants access")
        }
        defaults.removeObject(forKey: PrivacyConsentPolicy.storageKey)
        let badClock = PrivacyConsentController(defaults: defaults, now: { Date(timeIntervalSince1970: -1) })
        badClock.agree()
        verify(!badClock.isAccepted, "an invalid timestamp cannot create an accepted state")
        verify(defaults.data(forKey: PrivacyConsentPolicy.storageKey) == nil, "an invalid action writes no misleading record")

        print("PASS: \(checks) privacy consent persistence, cancellation, version and withdrawal assertions")
    }

    private static func verify(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        guard condition() else { fatalError("FAIL: \(message)") }
    }
}
