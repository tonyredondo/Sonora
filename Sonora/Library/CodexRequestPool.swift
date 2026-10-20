import Foundation

/// Shared by translation and meaning. A waiting worker chooses its next job
/// only after receiving a slot, so queue edits can still remove pending work.
@MainActor
final class CodexRequestPool {
    static let shared = CodexRequestPool()
    static let capacity = 4
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func perform(_ operation: @MainActor () async -> Void) async {
        if running == Self.capacity {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            running += 1
        }
        defer {
            if waiters.isEmpty { running -= 1 }
            else { waiters.removeFirst().resume() }
        }
        await operation()
    }
}
