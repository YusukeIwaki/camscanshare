import Foundation

/// Synchronous image jobs share one executor, including Core ML inference.
/// Queued jobs allocate image buffers only after checking cancellation.
actor ImageProcessingWorker {
    static let shared = ImageProcessingWorker()

    func run<T: Sendable>(_ operation: @Sendable () throws -> T) throws -> T {
        try Task.checkCancellation()
        return try autoreleasepool(invoking: operation)
    }
}
