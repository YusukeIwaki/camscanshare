import Foundation
import XCTest
@testable import CamScanShare

final class ImageProcessingWorkerTests: XCTestCase {
    func testConcurrentRequestsRunOneImageJobAtATime() async throws {
        let worker = ImageProcessingWorker()
        let probe = ConcurrencyProbe()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    try await worker.run {
                        probe.begin()
                        Thread.sleep(forTimeInterval: 0.002)
                        probe.end()
                    }
                }
            }
            try await group.waitForAll()
        }
        XCTAssertEqual(probe.maximumActiveJobs, 1)
        XCTAssertEqual(probe.finishedJobs, 20)
    }

    func testCancelledRequestDoesNotRunImageJob() async {
        let worker = ImageProcessingWorker()
        let probe = ConcurrencyProbe()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await worker.run {
                probe.begin()
                probe.end()
            }
        }
        do {
            try await task.value
            XCTFail("Cancelled jobs must throw before allocating images")
        } catch is CancellationError {
            XCTAssertEqual(probe.finishedJobs, 0)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}

private final class ConcurrencyProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    private var maximum = 0
    private var finished = 0

    var maximumActiveJobs: Int {
        lock.lock()
        defer { lock.unlock() }
        return maximum
    }

    var finishedJobs: Int {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }

    func begin() {
        lock.lock()
        defer { lock.unlock() }
        active += 1
        maximum = max(maximum, active)
    }

    func end() {
        lock.lock()
        defer { lock.unlock() }
        active -= 1
        finished += 1
    }
}
