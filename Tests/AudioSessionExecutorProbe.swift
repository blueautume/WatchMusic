import Foundation

/// Exercises the production executor with inert native-operation adapters.
/// No audio session, app, simulator, or user media is opened by this probe.
@main
struct AudioSessionExecutorProbe {
    @MainActor private static var assertions = 0

    @MainActor
    static func main() async {
        do {
            try await slowConfigurationDoesNotBlockMainActor()
            try await serialOperationsAndCallbacks()
            try await configurationCaching()
            try await externalConfigurationChanges()
            try await idleReselectionAndActivationLeases()
            try await nativeAndConfigurationFailures()
            try await explicitSetupFailureCallbacks()
            try await duplicateAndInvalidatedNativeCallbacks()
            print("PASS: \(assertions) audio-session executor assertions")
        } catch {
            FileHandle.standardError.write(Data("AUDIO_SESSION_EXECUTOR_FAIL: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    private static let configuration = AudioSessionExecutor.Configuration(
        category: "playback", mode: "default", policy: 1, options: 0)

    @MainActor
    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw ProbeFailure(message: message) }
        assertions += 1
    }

    @MainActor
    private static func waitUntil(_ message: String, condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
        try check(condition(), message)
    }

    private static func executor(_ recorder: ExecutorRecorder, checkActualConfiguration: Bool = false) -> AudioSessionExecutor {
        let matches: (@Sendable (AudioSessionExecutor.Configuration) -> Bool)?
        if checkActualConfiguration {
            matches = { @Sendable configuration in recorder.configurationMatches(configuration) }
        } else {
            matches = nil
        }
        return AudioSessionExecutor(
            configure: { try recorder.configure($0) },
            activate: { recorder.activate($0) },
            deactivate: { try recorder.deactivate() },
            configurationMatches: matches)
    }

    @MainActor
    @discardableResult
    private static func activate(_ executor: AudioSessionExecutor, recorder: ExecutorRecorder,
                                 configuration: AudioSessionExecutor.Configuration = AudioSessionExecutorProbe.configuration,
                                 resetIdle: Bool = false) async throws -> UUID {
        let requestID = UUID()
        let previousStarts = recorder.snapshot.activationStarts
        var completed = false
        var succeeded = false
        var completionError: NSError?
        executor.activate(id: requestID, configuration: configuration, resetIdle: resetIdle) { activated, error in
            recorder.callback("activation")
            succeeded = activated
            completionError = error
            completed = true
        }
        try await waitUntil("native activation starts on the executor") {
            recorder.snapshot.activationStarts == previousStarts + 1
        }
        try check(recorder.completeNext(activated: true), "a native completion belongs to the pending activation")
        try await waitUntil("native completion returns to MainActor") { completed }
        try check(succeeded && completionError == nil, "a successful native activation preserves its result")
        return requestID
    }

    @MainActor
    private static func deactivate(_ executor: AudioSessionExecutor, recorder: ExecutorRecorder,
                                   expectedActivationID: UUID?) async throws -> NSError? {
        var completed = false
        var completionError: NSError?
        executor.deactivate(expectedActivationID: expectedActivationID) { error in
            recorder.callback("deactivation")
            completionError = error
            completed = true
        }
        try await waitUntil("deactivation completes without blocking MainActor") { completed }
        return completionError
    }

    @MainActor
    private static func slowConfigurationDoesNotBlockMainActor() async throws {
        let recorder = ExecutorRecorder()
        recorder.blockNextConfiguration()
        let watchdog = DispatchWorkItem { recorder.releaseConfigurationBlock() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: watchdog)
        defer {
            watchdog.cancel()
            recorder.releaseConfigurationBlock()
        }
        let executor = executor(recorder)
        let requestID = UUID()
        var completed = false
        executor.activate(id: requestID, configuration: configuration, resetIdle: false) { _, _ in
            recorder.callback("slow-configuration")
            completed = true
        }
        try await waitUntil("slow configuration begins on the worker") { recorder.snapshot.configurationEntered }
        try check(recorder.snapshot.configurationBlocked && recorder.snapshot.activationStarts == 0,
                  "MainActor progresses while native configuration is still deliberately blocked")
        recorder.releaseConfigurationBlock()
        try await waitUntil("unblocking configuration allows native activation") { recorder.snapshot.activationStarts == 1 }
        try check(recorder.completeNext(activated: true), "slow configuration retains its native completion")
        try await waitUntil("slow configuration request completes") { completed }
        _ = try await deactivate(executor, recorder: recorder, expectedActivationID: requestID)
    }

    @MainActor
    private static func serialOperationsAndCallbacks() async throws {
        let recorder = ExecutorRecorder()
        let executor = executor(recorder)
        var completions = 0
        var successfulCompletions = 0
        let first = UUID(), second = UUID()
        executor.activate(id: first, configuration: configuration, resetIdle: false) { activated, error in
            recorder.callback("first")
            if activated && error == nil { successfulCompletions += 1 }
            completions += 1
        }
        executor.activate(id: second, configuration: configuration, resetIdle: false) { activated, error in
            recorder.callback("second")
            if activated && error == nil { successfulCompletions += 1 }
            completions += 1
        }
        try await waitUntil("the first native request starts while MainActor remains responsive") {
            recorder.snapshot.activationStarts >= 1
        }
        try check(recorder.completeNext(activated: true), "the first native callback is available")
        try await waitUntil("the second request advances after the first MainActor completion") {
            recorder.snapshot.activationStarts == 2
        }
        let intermediate = recorder.snapshot
        try check(intermediate.maxPendingNativeActivations == 1, "only one asynchronous native activation is in flight")
        try check(intermediate.events.contains("callback:first"), "the first MainActor callback precedes the second activation")
        try check(intermediate.events.firstIndex(of: "callback:first")!
                  < intermediate.events.firstIndex(of: "activate:2")!,
                  "MainActor completion runs before the next native operation begins")
        try check(recorder.completeNext(activated: true), "the second native callback is available")
        try await waitUntil("both consecutive requests complete") { completions == 2 }
        try check(successfulCompletions == 2, "consecutive callbacks retain both successful results")
        try check(recorder.snapshot.configurations.count == 1, "consecutive equal configurations do not repeat configuration work")
        let cleanupError = try await deactivate(executor, recorder: recorder, expectedActivationID: second)
        try check(cleanupError == nil, "the current activation can be deactivated")
        let final = recorder.snapshot
        try check(final.deactivations == 1, "current cleanup invokes native deactivation exactly once")
        try check(final.operationThreadViolations.isEmpty, "configuration, activation and deactivation run off the main thread")
        try check(final.callbackThreadViolations.isEmpty, "operation completions are delivered on the main thread")
    }

    @MainActor
    private static func configurationCaching() async throws {
        let recorder = ExecutorRecorder()
        let executor = executor(recorder)
        _ = try await activate(executor, recorder: recorder)
        _ = try await activate(executor, recorder: recorder)
        try check(recorder.snapshot.configurations.count == 1, "a successful configuration is reused across activations")
        let changed = AudioSessionExecutor.Configuration(category: "playback", mode: "spokenAudio", policy: 1, options: 0)
        _ = try await activate(executor, recorder: recorder, configuration: changed)
        try check(recorder.snapshot.configurations == [configuration, changed], "a changed configuration is applied once")
        executor.invalidate()
        let latest = try await activate(executor, recorder: recorder, configuration: changed)
        try check(recorder.snapshot.configurations == [configuration, changed, changed],
                  "media-service invalidation reapplies an otherwise identical configuration")
        _ = try await deactivate(executor, recorder: recorder, expectedActivationID: latest)
    }

    @MainActor
    private static func externalConfigurationChanges() async throws {
        let recorder = ExecutorRecorder()
        let executor = executor(recorder, checkActualConfiguration: true)
        _ = try await activate(executor, recorder: recorder)
        _ = try await activate(executor, recorder: recorder)
        try check(recorder.snapshot.configurations.count == 1, "matching native configuration avoids redundant setup")
        recorder.changeExternalConfiguration(to: AudioSessionExecutor.Configuration(
            category: "ambient", mode: "default", policy: 0, options: 0))
        let latest = try await activate(executor, recorder: recorder)
        try check(recorder.snapshot.configurations == [configuration, configuration],
                  "external native configuration changes are detected despite an unchanged requested configuration")
        try check(recorder.snapshot.operationThreadViolations.isEmpty,
                  "reading actual native configuration also happens off the main thread")
        _ = try await deactivate(executor, recorder: recorder, expectedActivationID: latest)
    }

    @MainActor
    private static func idleReselectionAndActivationLeases() async throws {
        let recorder = ExecutorRecorder()
        let executor = executor(recorder)
        let first = try await activate(executor, recorder: recorder)
        let second = try await activate(executor, recorder: recorder, resetIdle: true)
        let reset = recorder.snapshot
        try check(reset.activationStarts == 2, "reselecting an idle output invokes native activation again")
        try check(reset.deactivations == 1, "idle reselection resets the old idle session before requesting a route")
        try check(reset.events.contains("deactivate:1"), "idle reselection calls the native reset adapter")
        try check(reset.events.firstIndex(of: "deactivate:1")! < reset.events.firstIndex(of: "activate:2")!,
                  "idle reset finishes before the new native route activation")
        try check(reset.configurations.count == 1, "idle route reset does not repeat an unchanged audio configuration")
        _ = try await deactivate(executor, recorder: recorder, expectedActivationID: first)
        try check(recorder.snapshot.deactivations == 1, "late cleanup for the old lease cannot deactivate the new output")
        _ = try await deactivate(executor, recorder: recorder, expectedActivationID: second)
        try check(recorder.snapshot.deactivations == 2, "cleanup for the current lease still releases the session")
    }

    @MainActor
    private static func nativeAndConfigurationFailures() async throws {
        let recorder = ExecutorRecorder()
        let executor = executor(recorder)
        let configurationError = NSError(domain: "ExecutorConfigurationProbe", code: 7)
        recorder.failNextConfiguration(with: configurationError)
        var configurationFinished = false
        var configurationResult: NSError?
        executor.activate(id: UUID(), configuration: configuration, resetIdle: false) { activated, error in
            recorder.callback("configuration-failure")
            if !activated { configurationResult = error }
            configurationFinished = true
        }
        try await waitUntil("configuration failure returns without starting native activation") { configurationFinished }
        try check(configurationResult?.domain == configurationError.domain && configurationResult?.code == configurationError.code,
                  "configuration errors preserve their native error context")
        try check(recorder.snapshot.activationStarts == 0, "a failed configuration never calls native activation")
        let recovered = try await activate(executor, recorder: recorder)
        try check(recorder.snapshot.configurations.count == 2, "failed configuration is retried rather than cached as successful")
        _ = try await deactivate(executor, recorder: recorder, expectedActivationID: recovered)

        let nativeError = NSError(domain: "ExecutorNativeProbe", code: 19)
        var nativeFinished = false
        var nativeResult: NSError?
        let nativeID = UUID()
        let previousStarts = recorder.snapshot.activationStarts
        executor.activate(id: nativeID, configuration: configuration, resetIdle: false) { activated, error in
            recorder.callback("native-failure")
            if !activated { nativeResult = error }
            nativeFinished = true
        }
        try await waitUntil("a failed native activation still enters the native adapter") {
            recorder.snapshot.activationStarts == previousStarts + 1
        }
        try check(recorder.completeNext(activated: false, error: nativeError), "the failed native completion is delivered")
        try await waitUntil("native failure releases the executor for subsequent work") { nativeFinished }
        try check(nativeResult?.domain == nativeError.domain && nativeResult?.code == nativeError.code,
                  "native false and NSError return without being rewritten by the executor")
        let retry = try await activate(executor, recorder: recorder)
        let cleanupError = NSError(domain: "ExecutorCleanupProbe", code: 23)
        recorder.failNextDeactivation(with: cleanupError)
        let failedCleanup = try await deactivate(executor, recorder: recorder, expectedActivationID: retry)
        try check(failedCleanup?.domain == cleanupError.domain && failedCleanup?.code == cleanupError.code,
                  "native cleanup failure retains the error for the player's event-driven retry")
        let beforeCleanupRetry = recorder.snapshot.deactivations
        let retriedCleanup = try await deactivate(executor, recorder: recorder, expectedActivationID: retry)
        try check(retriedCleanup == nil && recorder.snapshot.deactivations == beforeCleanupRetry + 1,
                  "failed cleanup keeps its lease eligible for a later explicit retry")
        try check(recorder.snapshot.operationThreadViolations.isEmpty && recorder.snapshot.callbackThreadViolations.isEmpty,
                  "failure and retry preserve the executor's thread boundaries")
    }

    @MainActor
    private static func explicitSetupFailureCallbacks() async throws {
        let recorder = ExecutorRecorder()
        let executor = executor(recorder)
        let configurationError = NSError(domain: "ExecutorSetupProbe", code: 31)
        recorder.failNextConfiguration(with: configurationError)
        var setupErrors: [NSError] = []
        var nativeCompletions = 0
        executor.activate(id: UUID(), configuration: configuration, resetIdle: false, onSetupFailure: { error in
            recorder.callback("setup-failure")
            setupErrors.append(error)
        }) { _, _ in
            nativeCompletions += 1
        }
        try await waitUntil("configuration throws use the dedicated setup-failure completion") { setupErrors.count == 1 }
        try check(setupErrors[0].domain == configurationError.domain && setupErrors[0].code == configurationError.code,
                  "setup failure preserves configuration error context without rewriting it as native false")
        try check(nativeCompletions == 0 && recorder.snapshot.activationStarts == 0,
                  "configuration failure cannot enter the native unselected-route completion")
        _ = try await activate(executor, recorder: recorder)

        let resetError = NSError(domain: "ExecutorResetProbe", code: 37)
        recorder.failNextDeactivation(with: resetError)
        executor.activate(id: UUID(), configuration: configuration, resetIdle: true, onSetupFailure: { error in
            recorder.callback("reset-failure")
            setupErrors.append(error)
        }) { _, _ in
            nativeCompletions += 1
        }
        try await waitUntil("idle reset throws also use setup-failure completion") { setupErrors.count == 2 }
        try check(setupErrors[1].domain == resetError.domain && setupErrors[1].code == resetError.code,
                  "idle reset failure remains distinguishable from returning without selecting an output")
        try check(nativeCompletions == 0 && recorder.snapshot.activationStarts == 1,
                  "failed idle reset never starts a new native activation or calls its native completion")
        let recovered = try await activate(executor, recorder: recorder)
        _ = try await deactivate(executor, recorder: recorder, expectedActivationID: recovered)
    }

    @MainActor
    private static func duplicateAndInvalidatedNativeCallbacks() async throws {
        do {
            let recorder = ExecutorRecorder()
            let executor = executor(recorder)
            var callbacks = 0
            let first = UUID()
            executor.activate(id: first, configuration: configuration, resetIdle: false) { _, _ in
                recorder.callback("first-completion")
                callbacks += 1
            }
            try await waitUntil("duplicate-callback fixture starts one activation") { recorder.snapshot.activationStarts == 1 }
            try check(recorder.completeNext(activated: true), "first native completion is available")
            try await waitUntil("first native completion is consumed") { callbacks == 1 }
            try check(recorder.repeatLastCompletion(activated: false, error: NSError(domain: "StaleDuplicate", code: 1)),
                      "the fixture replays the exact old native completion")
            try await waitUntil("the duplicate reaches the native adapter") { recorder.snapshot.nativeCompletionDeliveries == 2 }
            let latest = try await activate(executor, recorder: recorder)
            try check(callbacks == 1, "a duplicate old callback cannot publish another result or complete the next request")
            _ = try await deactivate(executor, recorder: recorder, expectedActivationID: latest)
        }

        do {
            let recorder = ExecutorRecorder()
            let executor = executor(recorder)
            var oldCallbacks = 0
            var oldWasCanceled = false
            var newCompleted = false
            var newActivated = false
            var newError: NSError?
            executor.activate(id: UUID(), configuration: configuration, resetIdle: false) { activated, error in
                recorder.callback("invalidated")
                oldCallbacks += 1
                oldWasCanceled = !activated && error?.domain == NSCocoaErrorDomain && error?.code == NSUserCancelledError
            }
            try await waitUntil("media-reset fixture starts an unresolved native activation") { recorder.snapshot.activationStarts == 1 }
            executor.invalidate()
            let latest = UUID()
            executor.activate(id: latest, configuration: configuration, resetIdle: false) { activated, error in
                recorder.callback("after-reset")
                newActivated = activated
                newError = error
                newCompleted = true
            }
            try await waitUntil("invalidation permits a new activation without waiting for the old native callback") {
                recorder.snapshot.activationStarts == 2
            }
            try check(oldCallbacks == 1 && oldWasCanceled, "invalidation resolves the old logical operation once as cancellation")
            try check(recorder.snapshot.configurations.count == 2, "media reset clears the successful configuration cache")
            try check(recorder.completeNext(activated: false, error: NSError(domain: "LateBeforeReset", code: 2)),
                      "the pre-reset native callback arrives after the replacement activation starts")
            try await waitUntil("the stale pre-reset callback reaches the adapter") { recorder.snapshot.nativeCompletionDeliveries == 1 }
            try check(!newCompleted, "a stale callback cannot complete the new activation")
            try check(recorder.completeNext(activated: true), "the replacement native callback is still pending")
            try await waitUntil("the replacement native activation completes normally") { newCompleted }
            try check(newActivated && newError == nil && oldCallbacks == 1,
                      "late native completion cannot overwrite the replacement result or repeat old cancellation")
            _ = try await deactivate(executor, recorder: recorder, expectedActivationID: latest)
        }
    }
}

private struct ProbeFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Mutable instrumentation is locked because production operations run on the
/// worker queue and native completions deliberately arrive on a different queue.
private final class ExecutorRecorder: @unchecked Sendable {
    typealias NativeCompletion = @Sendable (Bool, NSError?) -> Void

    struct Snapshot {
        let configurations: [AudioSessionExecutor.Configuration]
        let activationStarts: Int
        let maxPendingNativeActivations: Int
        let deactivations: Int
        let events: [String]
        let operationThreadViolations: [String]
        let callbackThreadViolations: [String]
        let configurationEntered: Bool
        let configurationBlocked: Bool
        let nativeCompletionDeliveries: Int
    }

    private let lock = NSLock()
    private var configurations: [AudioSessionExecutor.Configuration] = []
    private var activationStarts = 0
    private var maxPendingNativeActivations = 0
    private var deactivations = 0
    private var events: [String] = []
    private var operationThreadViolations: [String] = []
    private var callbackThreadViolations: [String] = []
    private var nativeCompletions: [NativeCompletion] = []
    private var configurationError: NSError?
    private var deactivationError: NSError?
    private var actualConfiguration: AudioSessionExecutor.Configuration?
    private var shouldBlockConfiguration = false
    private var configurationEntered = false
    private var configurationBlocked = false
    private let configurationGate = DispatchSemaphore(value: 0)
    private var lastCompletedNative: NativeCompletion?
    private var nativeCompletionDeliveries = 0

    var snapshot: Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(configurations: configurations, activationStarts: activationStarts,
                        maxPendingNativeActivations: maxPendingNativeActivations, deactivations: deactivations,
                        events: events, operationThreadViolations: operationThreadViolations,
                        callbackThreadViolations: callbackThreadViolations,
                        configurationEntered: configurationEntered, configurationBlocked: configurationBlocked,
                        nativeCompletionDeliveries: nativeCompletionDeliveries)
    }

    func configure(_ configuration: AudioSessionExecutor.Configuration) throws {
        lock.lock()
        configurations.append(configuration)
        events.append("configure")
        if Thread.isMainThread { operationThreadViolations.append("configure") }
        let error = configurationError
        configurationError = nil
        let shouldBlock = shouldBlockConfiguration
        shouldBlockConfiguration = false
        if shouldBlock {
            configurationEntered = true
            configurationBlocked = true
        }
        lock.unlock()
        if shouldBlock {
            configurationGate.wait()
            lock.lock()
            configurationBlocked = false
            lock.unlock()
        }
        if let error { throw error }
        lock.lock()
        actualConfiguration = configuration
        lock.unlock()
    }

    func configurationMatches(_ configuration: AudioSessionExecutor.Configuration) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if Thread.isMainThread { operationThreadViolations.append("configurationMatches") }
        return actualConfiguration == configuration
    }

    func changeExternalConfiguration(to configuration: AudioSessionExecutor.Configuration) {
        lock.lock()
        actualConfiguration = configuration
        lock.unlock()
    }

    func activate(_ completion: @escaping NativeCompletion) {
        lock.lock()
        defer { lock.unlock() }
        activationStarts += 1
        events.append("activate:\(activationStarts)")
        if Thread.isMainThread { operationThreadViolations.append("activate") }
        nativeCompletions.append(completion)
        maxPendingNativeActivations = max(maxPendingNativeActivations, nativeCompletions.count)
    }

    func deactivate() throws {
        lock.lock()
        deactivations += 1
        events.append("deactivate:\(deactivations)")
        if Thread.isMainThread { operationThreadViolations.append("deactivate") }
        let error = deactivationError
        deactivationError = nil
        lock.unlock()
        if let error { throw error }
    }

    func callback(_ name: String) {
        lock.lock()
        defer { lock.unlock() }
        events.append("callback:\(name)")
        if !Thread.isMainThread { callbackThreadViolations.append(name) }
    }

    func failNextConfiguration(with error: NSError) {
        lock.lock()
        configurationError = error
        lock.unlock()
    }

    func failNextDeactivation(with error: NSError) {
        lock.lock()
        deactivationError = error
        lock.unlock()
    }

    func blockNextConfiguration() {
        lock.lock()
        shouldBlockConfiguration = true
        lock.unlock()
    }

    func releaseConfigurationBlock() {
        configurationGate.signal()
    }

    private func deliver(_ completion: @escaping NativeCompletion, activated: Bool, error: NSError?) {
        DispatchQueue.global().async {
            completion(activated, error)
            self.lock.lock()
            self.nativeCompletionDeliveries += 1
            self.lock.unlock()
        }
    }

    func completeNext(activated: Bool, error: NSError? = nil) -> Bool {
        lock.lock()
        guard !nativeCompletions.isEmpty else { lock.unlock(); return false }
        let completion = nativeCompletions.removeFirst()
        lastCompletedNative = completion
        lock.unlock()
        deliver(completion, activated: activated, error: error)
        return true
    }

    func repeatLastCompletion(activated: Bool, error: NSError?) -> Bool {
        lock.lock()
        let completion = lastCompletedNative
        lock.unlock()
        guard let completion else { return false }
        deliver(completion, activated: activated, error: error)
        return true
    }
}
