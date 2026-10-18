import Foundation

/// A session-owned cooperative gate. Pausing does not restart scanning or
/// serialize book text. Cancellation wakes every suspended waiter permanently.
public actor LibrarySearchControl {
    public enum State: Sendable, Equatable { case running, paused, cancelled }
    public private(set) var state = State.running
    private var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
    public var suspendedWaiterCount: Int { waiters.count }
    public init() {}
    public func pause() { if state != .cancelled { state = .paused } }
    public func resume() {
        guard state == .paused else { return }
        state = .running
        let pending = waiters.values; waiters = [:]
        for continuation in pending { continuation.resume() }
    }
    public func cancel() {
        state = .cancelled
        let pending = waiters.values; waiters = [:]
        for continuation in pending { continuation.resume(throwing: CancellationError()) }
    }
    public func waitUntilRunning() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled || state == .cancelled { continuation.resume(throwing: CancellationError()) }
                else if state == .running { continuation.resume() }
                else { waiters[id] = continuation }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }
    private func cancelWaiter(_ id: UUID) { waiters.removeValue(forKey: id)?.resume(throwing: CancellationError()) }
}

public enum LibrarySearchRunState: String, Sendable {
    case running, paused, cancelled, finished, failed
}
