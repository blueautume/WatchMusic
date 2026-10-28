import BackgroundTasks
import Foundation

/// Owns the system grant for the entire user-initiated LAN queue, across batches.
/// All callbacks and source-server decisions stay on PhoneLibrary's main actor.
@MainActor
final class LANContinuedProcessing {
    static let shared = LANContinuedProcessing()

    var onGranted: (() -> Void)?
    var onInterrupted: ((String) -> Void)?
    private var state = LANContinuedProcessingState()
    private var driver: AnyObject?
    private var currentProgress = LANContinuedProcessingProgress(completedBytes: 0, totalBytes: 0, completedFiles: 0, totalFiles: 0)
    private var currentSubtitle = "准备传输"
    private(set) var lastFailure: String?

    #if DEBUG && targetEnvironment(simulator)
    private var probeAutomaticallyGrants: Bool?
    #endif

    var canRunInBackground: Bool { state.canRunInBackground }
    var isRequesting: Bool {
        if case .requesting = state.phase { return true }
        return false
    }

    /// Prepare the driver during launch. Each concrete job identifier is
    /// registered immediately before its matching request is submitted.
    func register() {
        #if DEBUG && targetEnvironment(simulator)
        if probeAutomaticallyGrants != nil { return }
        #endif
        guard #available(iOS 26.0, *) else { return }
        if driver != nil { return }
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        driver = LANContinuedProcessingDriver(owner: self, identifierPrefix: bundleID + ".lan-transfer")
    }

    /// Only call from a foreground Send/Resume action. A true result means the
    /// request is pending or granted; only canRunInBackground proves a grant.
    @discardableResult
    func beginFromUserAction(isForeground: Bool) -> Bool {
        guard isForeground else { return false }
        if state.identifier != nil { return true }
        lastFailure = nil
        currentProgress = LANContinuedProcessingProgress(completedBytes: 0, totalBytes: 0, completedFiles: 0, totalFiles: 0)
        currentSubtitle = "准备传输"
        #if DEBUG && targetEnvironment(simulator)
        if let automatic = probeAutomaticallyGrants {
            let identifier = "probe." + UUID().uuidString
            guard state.request(identifier: identifier, isForeground: true, isSupported: true, isRegistered: true) else { return false }
            if automatic { grantForProbe() }
            return true
        }
        #endif
        guard #available(iOS 26.0, *), let service = driver as? LANContinuedProcessingDriver else { return false }
        let identifier = service.identifierPrefix + "." + UUID().uuidString
        guard service.start(identifier: identifier, afterRegistration: {
            self.state.request(identifier: identifier, isForeground: isForeground, isSupported: true, isRegistered: true)
        }) else {
            state.finish()
            lastFailure = "暂时无法启用后台传输"
            return false
        }
        return true
    }

    func update(completedBytes: Int64, totalBytes: Int64, completedFiles: Int, totalFiles: Int, subtitle: String) {
        currentProgress = LANContinuedProcessingProgress(completedBytes: completedBytes, totalBytes: totalBytes, completedFiles: completedFiles, totalFiles: totalFiles)
        currentSubtitle = subtitle
        if #available(iOS 26.0, *), let service = driver as? LANContinuedProcessingDriver {
            service.update(progress: currentProgress, subtitle: subtitle)
        }
    }

    /// Complete, cancel, or release a paused queue. Invalidating state first
    /// ensures an already enqueued launch/expiration can't restart that queue.
    func finish(success: Bool) {
        let identifier = state.finish()
        if #available(iOS 26.0, *), let service = driver as? LANContinuedProcessingDriver {
            service.finish(identifier: identifier, success: success)
        }
    }

    fileprivate func expects(identifier: String) -> Bool { state.identifier == identifier }

    @available(iOS 26.0, *)
    fileprivate func receive(_ task: BGContinuedProcessingTask) {
        guard let service = driver as? LANContinuedProcessingDriver,
              state.grant(identifier: task.identifier) else {
            task.setTaskCompleted(success: false)
            return
        }
        service.attach(task)
        service.update(progress: currentProgress, subtitle: currentSubtitle)
        onGranted?()
    }

    fileprivate func interrupted(identifier: String, message: String) {
        guard state.interrupt(identifier: identifier) else { return }
        lastFailure = message
        // Persist/suspend the source before relinquishing the system runtime.
        onInterrupted?(message)
        if #available(iOS 26.0, *), let service = driver as? LANContinuedProcessingDriver {
            service.finish(identifier: identifier, success: false)
        }
    }

    #if DEBUG && targetEnvironment(simulator)
    /// Native CLI probes have no UIApplication. These hooks exercise the same
    /// state machine without requesting or pretending to verify OS runtime.
    func configureProbe(automaticallyGrant: Bool = true) {
        finish(success: false)
        probeAutomaticallyGrants = automaticallyGrant
    }

    var progressForProbe: LANContinuedProcessingProgress { currentProgress }

    func grantForProbe() {
        guard probeAutomaticallyGrants != nil, let identifier = state.identifier,
              state.grant(identifier: identifier) else { return }
        onGranted?()
    }

    func interruptForProbe() {
        guard probeAutomaticallyGrants != nil, let identifier = state.identifier else { return }
        interrupted(identifier: identifier, message: "后台任务已结束，等待恢复")
    }
    #endif
}

/// The plist wildcard is permission to create jobs, not a launch-handler route.
/// Register and submit the same concrete identifier. This boundary is shared
/// with a strict fake scheduler in tests; no OS runtime grant is simulated here.
@MainActor
enum LANContinuedProcessingSubmission {
    static func start(identifier: String, register: (String) -> Bool, afterRegistration: () -> Bool = { true }, submit: (String) -> Void) -> Bool {
        guard !identifier.isEmpty, !identifier.contains("*"), register(identifier) else { return false }
        guard afterRegistration() else { return false }
        submit(identifier)
        return true
    }
}

@available(iOS 26.0, *)
@MainActor
private final class LANContinuedProcessingDriver {
    let identifierPrefix: String
    private weak var owner: LANContinuedProcessing?
    private var registeredIdentifiers = Set<String>()
    private var activeTask: BGContinuedProcessingTask?
    private var submissionTask: Task<Void, Never>?
    private var submissionIdentifier: String?
    private var lastSubtitle: String?

    init(owner: LANContinuedProcessing, identifierPrefix: String) {
        self.owner = owner
        self.identifierPrefix = identifierPrefix
    }

    func start(identifier: String, afterRegistration: () -> Bool) -> Bool {
        LANContinuedProcessingSubmission.start(identifier: identifier,
            register: { self.register(identifier: $0) }, afterRegistration: afterRegistration,
            submit: { self.submit(identifier: $0) })
    }

    private func register(identifier: String) -> Bool {
        if registeredIdentifiers.contains(identifier) { return true }
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { [weak self] task in
            MainActor.assumeIsolated {
                guard let self, let continuedTask = task as? BGContinuedProcessingTask else {
                    task.setTaskCompleted(success: false)
                    return
                }
                self.owner?.receive(continuedTask)
                if self.owner == nil { continuedTask.setTaskCompleted(success: false) }
            }
        }
        if registered { registeredIdentifiers.insert(identifier) }
        return registered
    }

    private func submit(identifier: String) {
        submissionIdentifier = identifier
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: "向手表传输音乐", subtitle: "准备传输")
        request.strategy = .fail
        if #available(iOS 27.0, *) {
            submissionTask = Task { [weak self] in
                guard let self, self.owner?.expects(identifier: identifier) == true else { return }
                do {
                    try await BGTaskScheduler.shared.submitTaskRequest(request)
                    if Task.isCancelled { BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier) }
                } catch {
                    self.owner?.interrupted(identifier: identifier, message: "暂时无法继续后台传输，等待恢复")
                }
            }
        } else {
            do { try BGTaskScheduler.shared.submit(request) }
            catch { owner?.interrupted(identifier: identifier, message: "暂时无法继续后台传输，等待恢复") }
        }
    }

    func attach(_ task: BGContinuedProcessingTask) {
        activeTask = task
        lastSubtitle = nil
        let identifier = task.identifier
        task.expirationHandler = { [weak self] in
            Task { @MainActor in
                self?.owner?.interrupted(identifier: identifier, message: "后台任务已结束，等待恢复")
            }
        }
    }

    func update(progress: LANContinuedProcessingProgress, subtitle: String) {
        guard let activeTask else { return }
        activeTask.progress.totalUnitCount = progress.totalUnitCount
        activeTask.progress.completedUnitCount = progress.completedUnitCount
        if lastSubtitle != subtitle {
            activeTask.updateTitle("向手表传输音乐", subtitle: subtitle)
            lastSubtitle = subtitle
        }
    }

    func finish(identifier: String?, success: Bool) {
        if submissionIdentifier == identifier {
            submissionTask?.cancel()
            submissionTask = nil
            submissionIdentifier = nil
        }
        if let identifier { BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier) }
        if let task = activeTask, identifier == task.identifier {
            activeTask = nil
            lastSubtitle = nil
            task.expirationHandler = nil
            task.setTaskCompleted(success: success)
        }
    }
}
