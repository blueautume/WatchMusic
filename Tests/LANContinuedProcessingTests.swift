import Foundation

@main
enum LANContinuedProcessingTests {
    @MainActor
    static func main() {
        var checks = 0
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            checks += 1
            guard condition() else { fatalError("Check \(checks): \(message)") }
        }

        var state = LANContinuedProcessingState()
        expect(!state.canRunInBackground, "an idle app has no background grant")
        expect(!state.request(identifier: "a", isForeground: false, isSupported: true, isRegistered: true), "background arrivals may not invent user initiated jobs")
        expect(!state.request(identifier: "a", isForeground: true, isSupported: false, isRegistered: true), "old iOS must stay foreground-only")
        expect(!state.request(identifier: "a", isForeground: true, isSupported: true, isRegistered: false), "failed registration doesn't imply runtime")
        expect(state.request(identifier: "a", isForeground: true, isSupported: true, isRegistered: true), "a foreground Send can request runtime")
        expect(!state.canRunInBackground, "successful submission alone is not a runtime grant")
        expect(!state.request(identifier: "b", isForeground: true, isSupported: true, isRegistered: true), "appending songs reuses the same pending queue task")
        expect(!state.grant(identifier: "stale"), "an unrelated system callback cannot grant this queue")
        expect(state.grant(identifier: "a"), "the expected launch handler grants runtime")
        expect(state.canRunInBackground, "only the launched task allows the HTTP source in background")
        expect(!state.grant(identifier: "a"), "a duplicate launch doesn't run a second source")
        expect(!state.interrupt(identifier: "stale"), "an old expiration must not interrupt active work")
        expect(state.interrupt(identifier: "a"), "system expiration revokes the current runtime")
        expect(!state.canRunInBackground && state.identifier == nil, "expiration is observable before source cleanup")
        expect(state.request(identifier: "b", isForeground: true, isSupported: true, isRegistered: true), "an explicit new user action can start another queue")
        expect(!state.interrupt(identifier: "a"), "the old expiration can't invalidate the replacement queue")
        expect(state.finish() == "b", "clearing a pending queue returns its exact cancellation identifier")
        expect(!state.grant(identifier: "b"), "a late grant cannot resurrect a cleared queue")
        expect(state.request(identifier: "c", isForeground: true, isSupported: true, isRegistered: true), "new queue after cancel remains possible")
        expect(state.grant(identifier: "c"), "replacement queue gets its own grant")
        expect(state.finish() == "c" && !state.canRunInBackground, "completion releases the grant immediately")
        expect(state.finish() == nil, "repeated cleanup has no extra system task to finish")

        let unknown = LANContinuedProcessingProgress(completedBytes: 500, totalBytes: 0, completedFiles: 0, totalFiles: 0)
        expect(unknown.completedUnitCount == 0 && unknown.totalUnitCount > 0, "preflight can't report fake transfer completion")
        let downloading = LANContinuedProcessingProgress(completedBytes: 50, totalBytes: 100, completedFiles: 0, totalFiles: 1)
        expect(downloading.completedUnitCount > 0 && downloading.completedUnitCount < downloading.totalUnitCount, "bytes advance system progress")
        let waitingForSave = LANContinuedProcessingProgress(completedBytes: 100, totalBytes: 100, completedFiles: 0, totalFiles: 1)
        expect(waitingForSave.completedUnitCount == 9_900, "all bytes still reserve the Watch validation/save checkpoint")
        let partialSave = LANContinuedProcessingProgress(completedBytes: 100, totalBytes: 100, completedFiles: 1, totalFiles: 2)
        expect(partialSave.completedUnitCount > waitingForSave.completedUnitCount && partialSave.completedUnitCount < partialSave.totalUnitCount, "individual save receipts advance final phase")
        let done = LANContinuedProcessingProgress(completedBytes: 100, totalBytes: 100, completedFiles: 2, totalFiles: 2)
        expect(done.completedUnitCount == done.totalUnitCount, "only received bytes and every save receipt finish the job")
        let negative = LANContinuedProcessingProgress(completedBytes: -10, totalBytes: 100, completedFiles: -2, totalFiles: 2)
        expect(negative.completedUnitCount == 0, "invalid observations can't move progress below zero")
        let oversized = LANContinuedProcessingProgress(completedBytes: .max, totalBytes: .max, completedFiles: .max, totalFiles: .max)
        expect(oversized.completedUnitCount == oversized.totalUnitCount, "large queues don't overflow integer progress arithmetic")
        let noBytes = LANContinuedProcessingProgress(completedBytes: 0, totalBytes: 100, completedFiles: 1, totalFiles: 1)
        expect(noBytes.completedUnitCount < noBytes.totalUnitCount, "a save count by itself cannot complete missing byte observations")

        #if os(iOS) && DEBUG && targetEnvironment(simulator)
        // A strict scheduler contract reproduces the native failure boundary:
        // plist permission patterns cannot stand in for concrete registrations.
        // This is the same submission boundary used by the production driver.
        let prefix = "com.example.player.lan-transfer."
        let firstJob = prefix + UUID().uuidString
        var registeredJobs = Set<String>()
        var submittedJobs: [String] = []
        var registrationTrace: [String] = []
        var preparingState = LANContinuedProcessingState()
        func registerJob(_ identifier: String) -> Bool {
            registrationTrace.append("register:" + identifier)
            guard identifier.hasPrefix(prefix), UUID(uuidString: String(identifier.dropFirst(prefix.count))) != nil else { return false }
            return registeredJobs.insert(identifier).inserted
        }
        func submitJob(_ identifier: String) {
            expect(registeredJobs.contains(identifier), "the exact submitted job must already have its own launch handler")
            expect(preparingState.identifier == identifier, "request state is established before an immediate launch could arrive")
            registrationTrace.append("submit:" + identifier)
            submittedJobs.append(identifier)
        }
        expect(LANContinuedProcessingSubmission.start(identifier: firstJob, register: registerJob, afterRegistration: {
            expect(registeredJobs.contains(firstJob), "only confirmed concrete registration enters requesting state")
            return preparingState.request(identifier: firstJob, isForeground: true, isSupported: true, isRegistered: true)
        }, submit: submitJob), "a permitted unique job can reach the scheduler")
        expect(registrationTrace == ["register:" + firstJob, "submit:" + firstJob], "registration and submission use one exact identifier in order")
        expect(!preparingState.canRunInBackground, "correct registration/submission still doesn't prove a real OS grant")
        preparingState.finish()
        let secondJob = prefix + UUID().uuidString
        expect(LANContinuedProcessingSubmission.start(identifier: secondJob, register: registerJob, afterRegistration: {
            preparingState.request(identifier: secondJob, isForeground: true, isSupported: true, isRegistered: true)
        }, submit: submitJob), "the next queue obtains another concrete registration")
        expect(Set(submittedJobs).count == 2, "replacement queues retain distinct callback identities")
        let submissionsBeforeReject = submittedJobs.count
        var preparedRejectedJob = false
        expect(!LANContinuedProcessingSubmission.start(identifier: prefix + UUID().uuidString, register: { _ in false }, afterRegistration: {
            preparedRejectedJob = true; return true
        }, submit: { submittedJobs.append($0) }), "registration denial cannot be treated as a submitted request")
        expect(!preparedRejectedJob && submittedJobs.count == submissionsBeforeReject, "failed registration never requests state or sends work")
        let traceBeforeWildcard = registrationTrace
        expect(!LANContinuedProcessingSubmission.start(identifier: prefix + "*", register: registerJob, submit: { submittedJobs.append($0) }), "the permission wildcard is rejected at the driver boundary")
        expect(registrationTrace == traceBeforeWildcard && submittedJobs.count == submissionsBeforeReject, "a wildcard never reaches native register or submit")
        expect(!LANContinuedProcessingSubmission.start(identifier: prefix + UUID().uuidString, register: registerJob, afterRegistration: { false }, submit: { submittedJobs.append($0) }), "canceled preparation cannot submit even after successful registration")
        expect(submittedJobs.count == submissionsBeforeReject, "source cancellation between registration and submit stays canceled")

        // These are business-state probes, not evidence of a system BGTask grant.
        let coordinator = LANContinuedProcessing.shared
        var granted = 0
        var interrupted = 0
        var revokedBeforeCleanup = false
        coordinator.onGranted = { granted += 1 }
        coordinator.onInterrupted = { _ in
            interrupted += 1
            revokedBeforeCleanup = !coordinator.canRunInBackground
        }
        coordinator.configureProbe(automaticallyGrant: false)
        expect(!coordinator.beginFromUserAction(isForeground: false), "coordinator rejects background start")
        expect(coordinator.beginFromUserAction(isForeground: true), "coordinator submits from Send")
        expect(coordinator.isRequesting && !coordinator.canRunInBackground && granted == 0, "pending callback cannot keep a CLI source alive")
        coordinator.update(completedBytes: 25, totalBytes: 100, completedFiles: 0, totalFiles: 1, subtitle: "0/1 首")
        coordinator.grantForProbe()
        expect(coordinator.canRunInBackground && granted == 1, "grant callback enables the existing queue")
        expect(coordinator.beginFromUserAction(isForeground: true) && granted == 1, "a second list doesn't request or grant another task")
        coordinator.interruptForProbe()
        expect(interrupted == 1 && revokedBeforeCleanup, "expiration notifies library only after revoking runtime")
        coordinator.interruptForProbe()
        expect(interrupted == 1, "duplicate expiration doesn't cancel a future queue")
        expect(coordinator.beginFromUserAction(isForeground: true), "Resume can request another task")
        coordinator.finish(success: false)
        coordinator.grantForProbe()
        expect(!coordinator.canRunInBackground && granted == 1, "late grant cannot restart cleared submissions")
        coordinator.configureProbe()
        expect(coordinator.beginFromUserAction(isForeground: true) && coordinator.canRunInBackground, "automatic grant fixture uses the same launched state")
        coordinator.finish(success: true)
        expect(!coordinator.canRunInBackground && !coordinator.isRequesting, "finished source no longer owns runtime")
        coordinator.onGranted = nil
        coordinator.onInterrupted = nil
        #endif

        print("LAN continued processing: \(checks) assertions passed")
    }
}
