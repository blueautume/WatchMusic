import Darwin
import Foundation

private struct ProcessMemory {
    let footprint: UInt64
    let resident: UInt64

    static func current() -> ProcessMemory {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        precondition(result == KERN_SUCCESS, "task_info must return real process memory")
        return ProcessMemory(footprint: info.phys_footprint, resident: info.resident_size)
    }
}

private final class ReadOffsetObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: UInt64 = 0
    func record(_ value: UInt64) { lock.lock(); stored = value; lock.unlock() }
    var bytes: UInt64 { lock.lock(); defer { lock.unlock() }; return stored }
}

/// Runs outside the preparation task's autorelease lifetime. Sampling uses only
/// Mach counters, and exceeding the guard cancels work before an actual OOM.
private final class MemorySampler: @unchecked Sendable {
    private let lock = NSLock()
    private let timer: DispatchSourceTimer
    private let initial: ProcessMemory
    private var peakFootprint: UInt64
    private var peakResident: UInt64
    private var samples = 0
    private var exceeded = false
    private var cancel: (() -> Void)?
    private var stopped = false
    private let limit: UInt64 = 160 * 1_024 * 1_024

    init(cancel: @escaping () -> Void) {
        let initial = ProcessMemory.current()
        self.initial = initial
        peakFootprint = initial.footprint
        peakResident = initial.resident
        self.cancel = cancel
        timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "LANMemoryProbe.sample", qos: .userInitiated))
        timer.schedule(deadline: .now(), repeating: .milliseconds(5))
        timer.setEventHandler { [weak self] in self?.sample() }
        timer.resume()
    }

    private func sample() {
        let memory = ProcessMemory.current()
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        samples += 1
        peakFootprint = max(peakFootprint, memory.footprint)
        peakResident = max(peakResident, memory.resident)
        let overLimit = memory.footprint > initial.footprint + limit || memory.resident > initial.resident + limit
        let stop = overLimit && !exceeded ? cancel : nil
        exceeded = exceeded || overLimit
        lock.unlock()
        stop?()
    }

    func finish() -> (footprintDelta: UInt64, residentDelta: UInt64, samples: Int, exceeded: Bool) {
        sample()
        lock.lock()
        stopped = true
        cancel = nil
        let result = (peakFootprint - initial.footprint, peakResident - initial.resident, samples, exceeded)
        lock.unlock()
        timer.cancel()
        return result
    }
}

@main
struct LANMemoryProbe {
    private static let mebibyte: UInt64 = 1_024 * 1_024
    private static let fileSize = 512 * mebibyte
    @MainActor private static var assertions = 0

    @MainActor static func main() async {
        do {
            try await run()
        } catch {
            FileHandle.standardError.write(Data("LAN_MEMORY_PROBE_FAIL: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    @MainActor private static func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
        guard value() else { throw ProbeError.failed(message) }
        assertions += 1
    }

    @MainActor private static func run() async throws {
        guard CommandLine.arguments.count >= 2 else { throw ProbeError.failed("Expected independent SHA-256 for 512 MiB of zero bytes") }
        let expectedSHA = CommandLine.arguments[1]
        let expectLimit = CommandLine.arguments.contains("--expect-memory-limit")
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent("LANMemoryProbe-" + UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: directory) }

        // Sparse files exercise actual FileHandle reads without allocating a
        // matching in-memory fixture or consuming gigabytes of disk space.
        func sparse(_ name: String, bytes: UInt64) throws -> LANTransferSource {
            let url = directory.appendingPathComponent(name)
            guard manager.createFile(atPath: url.path, contents: nil) else { throw ProbeError.failed("Cannot create sparse fixture") }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.truncate(atOffset: bytes)
            return LANTransferSource(id: UUID().uuidString, folder: "MemoryProbe", fileName: name, url: url)
        }

        let warmup = try sparse("warmup.flac", bytes: 4_096)
        let warmupServer = LANHTTPServer(allowLoopbackForTesting: true)
        _ = try await warmupServer.start(sources: [warmup])
        warmupServer.stop()
        try await Task.sleep(nanoseconds: 50_000_000)
        let sources = try (0..<3).map { try sparse("large-\($0).flac", bytes: fileSize) }
        let server = LANHTTPServer(allowLoopbackForTesting: true)
        defer { server.stop() }
        let preparation = Task { try await server.start(sources: sources) }
        let guardOffset = ReadOffsetObservation()
        let monitor = MemorySampler {
            guardOffset.record(sources.reduce(0) { $0 + UInt64(max(0, currentReadOffset(for: $1.url))) })
            preparation.cancel()
        }
        let result = await preparation.result
        let stats = monitor.finish()
        report("batch", stats, logicalBytes: fileSize * UInt64(sources.count))
        if expectLimit {
            try expect(stats.exceeded, "Unfixed preparation must reproduce increasing memory and trip the bounded safety guard")
            try expect(guardOffset.bytes > 0, "The guard must observe a source descriptor that has actually advanced")
            if case .success = result { throw ProbeError.failed("Unfixed preparation unexpectedly completed below the memory guard") }
            try expect(server.activeSessionID == nil, "Guard cancellation must not leave a listener")
            log("BASELINE_REPRODUCED: preparation exceeded 160 MiB growth; observed_active_file_offset=\(guardOffset.bytes); cancelled safely")
            return
        }
        try expect(!stats.exceeded, "Preparation exceeded the 160 MiB safety guard")
        let offer = try result.get()
        try expect(offer.files.count == sources.count, "Preparation must retain the entire multi-file offer")
        try expect(offer.files.allSatisfy { $0.byteCount == Int64(fileSize) && $0.sha256 == expectedSHA },
                   "Every 512 MiB source must have the independent expected size and SHA-256")
        try expect(stats.footprintDelta < 64 * mebibyte && stats.residentDelta < 64 * mebibyte,
                   "Preparing 1.5 GiB must use less than 64 MiB additional process memory")
        try expect(stats.samples > 5, "Memory must be sampled during the real reads")
        server.stop()

        // Cancel only once a real descriptor has advanced, rather than merely
        // checking an already-cancelled Task before preparation starts.
        let cancellationSource = try sparse("cancel.flac", bytes: 8 * 1_024 * mebibyte)
        let cancelledServer = LANHTTPServer(allowLoopbackForTesting: true)
        defer { cancelledServer.stop() }
        let cancellation = Task { try await cancelledServer.start(sources: [cancellationSource]) }
        let cancellationMonitor = MemorySampler { cancellation.cancel() }
        let waitUntil = Date().addingTimeInterval(3)
        var observedOffset: off_t = 0
        while Date() < waitUntil, observedOffset == 0 {
            try await Task.sleep(nanoseconds: 2_000_000)
            observedOffset = currentReadOffset(for: cancellationSource.url)
        }
        let cancelledAt = Date()
        cancellation.cancel()
        let cancellationResult = await cancellation.result
        let elapsed = Date().timeIntervalSince(cancelledAt)
        let cancellationStats = cancellationMonitor.finish()
        report("cancel", cancellationStats, logicalBytes: UInt64(max(0, observedOffset)))
        try expect(observedOffset > 0, "Cancellation must interrupt an actively read large source")
        if case .success = cancellationResult { throw ProbeError.failed("Cancelled preparation exposed a listener") }
        if case .failure(let error) = cancellationResult { try expect(error is CancellationError, "Active cancellation must remain a cancellation") }
        try expect(cancelledServer.activeSessionID == nil, "Active cancellation leaves no active listener")
        try expect(elapsed < 1, "Cancellation must finish promptly between bounded reads")
        try expect(!cancellationStats.exceeded, "Cancellation must not retain all bytes read so far")
        log("PASS: \(assertions) real LAN preparation memory assertions")
    }

    /// Match the fixture inode, then observe a zero-relative lseek without
    /// changing its descriptor offset or reading any unrelated file's bytes.
    private static func currentReadOffset(for url: URL) -> off_t {
        var expected = stat()
        guard url.path.withCString({ fstatat(AT_FDCWD, $0, &expected, 0) }) == 0 else { return 0 }
        var maximum: off_t = 0
        for descriptor: Int32 in 3..<256 {
            var actual = stat()
            guard fstat(descriptor, &actual) == 0,
                  actual.st_dev == expected.st_dev, actual.st_ino == expected.st_ino else { continue }
            maximum = max(maximum, lseek(descriptor, 0, SEEK_CUR))
        }
        return maximum
    }

    private static func report(_ stage: String,
                               _ stats: (footprintDelta: UInt64, residentDelta: UInt64, samples: Int, exceeded: Bool),
                               logicalBytes: UInt64) {
        log("MEMORY \(stage): logical_bytes=\(logicalBytes) peak_footprint_delta=\(stats.footprintDelta) peak_rss_delta=\(stats.residentDelta) samples=\(stats.samples) guard=\(stats.exceeded)")
    }

    private static func log(_ value: String) { FileHandle.standardOutput.write(Data((value + "\n").utf8)) }

    private enum ProbeError: LocalizedError {
        case failed(String)
        var errorDescription: String? { if case .failed(let message) = self { return message }; return nil }
    }
}
