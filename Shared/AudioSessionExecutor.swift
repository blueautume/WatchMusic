import Foundation
import OSLog

/// Owns native session mutations on one worker queue. Async activation remains
/// the running operation until its MainActor consumer has handled the result.
final class AudioSessionExecutor: @unchecked Sendable {
    struct Configuration: Equatable, Sendable {
        let category: String
        let mode: String
        let policy: UInt
        let options: UInt
    }

    typealias ActivationCompletion = @MainActor @Sendable (Bool, NSError?) -> Void
    typealias SetupFailureCompletion = @MainActor @Sendable (NSError) -> Void
    typealias DeactivationCompletion = @MainActor @Sendable (NSError?) -> Void

    private enum Operation: Sendable {
        case activate(UUID, Configuration, Bool, SetupFailureCompletion?, ActivationCompletion)
        case deactivate(UUID?, DeactivationCompletion)

        @MainActor func deliver(_ result: Completion) {
            switch (self, result) {
            case (.activate(_, _, _, _, let completion), .activation(let active, let error)):
                completion(active, error)
            case (.activate(_, _, _, let setupFailure, let completion), .setupFailure(let error)):
                if let setupFailure { setupFailure(error) }
                else { completion(false, error) }
            case (.deactivate(_, let completion), .deactivation(let error)):
                completion(error)
            default: break
            }
        }

        var cancellation: Completion {
            let error = NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)
            switch self {
            case .activate: return .activation(false, error)
            case .deactivate: return .deactivation(error)
            }
        }
    }

    private enum Completion: Sendable {
        case activation(Bool, NSError?)
        case setupFailure(NSError)
        case deactivation(NSError?)
    }

    private struct Running {
        let token: UUID
        let operation: Operation
        var delivering = false
    }

    private let queue = DispatchQueue(label: "WatchMusic.audio-session", qos: .userInitiated)
    private let configure: @Sendable (Configuration) throws -> Void
    private let configurationMatches: (@Sendable (Configuration) -> Bool)?
    private let activateNative: @Sendable (@escaping @Sendable (Bool, NSError?) -> Void) -> Void
    private let deactivateNative: @Sendable () throws -> Void
    private var cachedConfiguration: Configuration?
    private var latestActivationID: UUID?
    private var pending: [Operation] = []
    private var running: Running?
    private static let logger = Logger(subsystem: "WatchMusic", category: "AudioSession")

    init(configure: @escaping @Sendable (Configuration) throws -> Void,
         activate: @escaping @Sendable (@escaping @Sendable (Bool, NSError?) -> Void) -> Void,
         deactivate: @escaping @Sendable () throws -> Void,
         configurationMatches: (@Sendable (Configuration) -> Bool)? = nil) {
        self.configure = configure
        self.activateNative = activate
        self.deactivateNative = deactivate
        self.configurationMatches = configurationMatches
    }

    func activate(id: UUID, configuration: Configuration, resetIdle: Bool,
                  onSetupFailure: SetupFailureCompletion? = nil,
                  completion: @escaping ActivationCompletion) {
        queue.async {
            self.latestActivationID = id
            self.pending.append(.activate(id, configuration, resetIdle, onSetupFailure, completion))
            self.advance()
        }
    }

    func deactivate(expectedActivationID: UUID?, completion: @escaping DeactivationCompletion) {
        queue.async {
            self.pending.append(.deactivate(expectedActivationID, completion))
            self.advance()
        }
    }

    /// Media-service reset ends the old logical operations even if the system
    /// never calls their native completion. A late callback cannot advance or
    /// otherwise mutate a newer operation.
    func invalidate() {
        queue.async {
            var canceled = self.pending
            if let current = self.running, !current.delivering { canceled.insert(current.operation, at: 0) }
            self.pending.removeAll()
            self.cachedConfiguration = nil
            self.latestActivationID = nil
            let barrier = UUID()
            // A temporary barrier also waits for already-dispatched callbacks.
            self.running = Running(token: barrier, operation: .deactivate(nil, { _ in }), delivering: true)
            let canceledOperations = canceled
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    for operation in canceledOperations { operation.deliver(operation.cancellation) }
                }
                self.queue.async {
                    guard self.running?.token == barrier else { return }
                    self.running = nil
                    self.advance()
                }
            }
        }
    }

    private func advance() {
        guard running == nil, !pending.isEmpty else { return }
        let operation = pending.removeFirst()
        let token = UUID()
        running = Running(token: token, operation: operation)
        switch operation {
        case .activate(_, let configuration, let resetIdle, _, _):
            do {
                if resetIdle {
                    let started = ProcessInfo.processInfo.systemUptime
                    try deactivateNative()
                    Self.logger.info("idle reset finished duration_ms=\((ProcessInfo.processInfo.systemUptime - started) * 1000, privacy: .public)")
                }
                let matches = configurationMatches?(configuration) ?? (cachedConfiguration == configuration)
                if !matches {
                    let started = ProcessInfo.processInfo.systemUptime
                    try configure(configuration)
                    Self.logger.info("configuration applied duration_ms=\((ProcessInfo.processInfo.systemUptime - started) * 1000, privacy: .public)")
                } else {
                    Self.logger.debug("configuration unchanged")
                }
                cachedConfiguration = configuration
                Self.logger.info("native activation started")
                activateNative { [weak self] active, error in
                    guard let self else { return }
                    self.queue.async {
                        if self.running?.token != token {
                            // A media reset can finish the old logical request
                            // before its native callback. If that old call later
                            // activates audio, clean it only while no newer lease
                            // exists; its old completion must never run twice.
                            if active, self.latestActivationID == nil {
                                Self.logger.info("late invalidated activation requested idle cleanup")
                                self.pending.append(.deactivate(nil, { _ in }))
                                self.advance()
                            }
                            return
                        }
                        self.finish(token: token, result: .activation(active, error))
                    }
                }
            } catch {
                let error = error as NSError
                Self.logger.error("session setup failed domain=\(error.domain, privacy: .public) code=\(error.code, privacy: .public)")
                finish(token: token, result: .setupFailure(error))
            }
        case .deactivate(let expectedID, _):
            guard expectedID == latestActivationID else {
                Self.logger.debug("superseded idle cleanup skipped")
                finish(token: token, result: .deactivation(nil))
                return
            }
            do {
                try deactivateNative()
                finish(token: token, result: .deactivation(nil))
            } catch {
                finish(token: token, result: .deactivation(error as NSError))
            }
        }
    }

    private func finish(token: UUID, result: Completion) {
        guard let current = running, current.token == token, !current.delivering else { return }
        running?.delivering = true
        DispatchQueue.main.async {
            MainActor.assumeIsolated { current.operation.deliver(result) }
            self.queue.async {
                guard self.running?.token == token else { return }
                self.running = nil
                self.advance()
            }
        }
    }
}
