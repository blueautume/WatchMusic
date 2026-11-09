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
    // Source-side counts are independent of Watch delegate/WC delivery. They
    // describe bytes handed to the network stack, never a saved-file receipt.
    private(set) var sourceBytes: [String: Int64] = [:]

    func recordSourceBytes(_ bytes: Int64, for id: String) {
        let value = max(sourceBytes[id] ?? 0, max(0, bytes))
        guard sourceBytes[id] != value else { return }
        objectWillChange.send()
        sourceBytes[id] = value
    }

    func resetSourceBytes(for ids: Set<String>) {
        guard ids.contains(where: { sourceBytes[$0] != nil }) else { return }
        objectWillChange.send()
        for id in ids { sourceBytes.removeValue(forKey: id) }
    }

    func retainSourceBytes(for ids: Set<String>) {
        let retained = sourceBytes.filter { ids.contains($0.key) }
        guard retained != sourceBytes else { return }
        objectWillChange.send()
        sourceBytes = retained
    }

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
