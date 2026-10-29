import Combine
import Foundation

enum PrivacyConsentPolicy {
    /// Bump when either agreement requires a fresh affirmative decision.
    static let currentVersion = "2026-10-29"
    static let storageKey = "legal.acceptedAgreements.v1"
}

struct PrivacyConsentRecord: Codable, Equatable {
    let version: String
    let acceptedAt: Date

    func isCurrent(version: String) -> Bool {
        self.version == version && acceptedAt.timeIntervalSince1970.isFinite
            && acceptedAt.timeIntervalSince1970 > 0
    }
}

/// One record is written only in response to an explicit agreement action.
/// Declining and reading the agreements never change a stored decision.
@MainActor
final class PrivacyConsentController: ObservableObject {
    enum State: Equatable {
        case awaitingDecision
        case declined
        case accepted(PrivacyConsentRecord)
    }

    @Published private(set) var state: State
    private let defaults: UserDefaults
    private let version: String
    private let now: () -> Date

    init(defaults: UserDefaults = .standard,
         version: String = PrivacyConsentPolicy.currentVersion,
         now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.version = version
        self.now = now
        if let data = defaults.data(forKey: PrivacyConsentPolicy.storageKey),
           let record = try? JSONDecoder().decode(PrivacyConsentRecord.self, from: data),
           record.isCurrent(version: version) {
            state = .accepted(record)
        } else {
            state = .awaitingDecision
        }
    }

    var isAccepted: Bool {
        if case .accepted = state { return true }
        return false
    }

    var isPresentingConsent: Bool { state == .awaitingDecision }

    func agree() {
        guard state == .awaitingDecision else { return }
        let record = PrivacyConsentRecord(version: version, acceptedAt: now())
        guard record.isCurrent(version: version),
              let data = try? JSONEncoder().encode(record) else { return }
        defaults.set(data, forKey: PrivacyConsentPolicy.storageKey)
        state = .accepted(record)
    }

    func cancel() {
        guard state == .awaitingDecision else { return }
        state = .declined
    }

    func review() {
        guard !isAccepted else { return }
        state = .awaitingDecision
    }

    func withdraw() {
        defaults.removeObject(forKey: PrivacyConsentPolicy.storageKey)
        state = .declined
    }
}
