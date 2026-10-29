import Combine
import Foundation

/// Transient transfer measurements have their own observation boundary. Updating
/// bytes or an estimate must not invalidate navigation or an open music menu.
@MainActor
final class PhoneTransferProgress: ObservableObject {
    nonisolated let objectWillChange = ObservableObjectPublisher()
    private(set) var values: [String: Double] = [:]
    private(set) var metrics: [String: TransferMetrics] = [:]
    private(set) var remainingEstimate: String?

    func update(values: [String: Double], metrics: [String: TransferMetrics], remainingEstimate: String?) {
        guard self.values != values || self.metrics != metrics || self.remainingEstimate != remainingEstimate else { return }
        objectWillChange.send()
        self.values = values
        self.metrics = metrics
        self.remainingEstimate = remainingEstimate
    }

    func replaceValues(_ values: [String: Double]) {
        update(values: values, metrics: metrics, remainingEstimate: remainingEstimate)
    }

    func replaceMetrics(_ metrics: [String: TransferMetrics]) {
        update(values: values, metrics: metrics, remainingEstimate: remainingEstimate)
    }
}
