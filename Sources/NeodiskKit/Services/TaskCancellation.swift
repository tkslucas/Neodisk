import Foundation

/// Await owned detached work while forwarding cancellation from its caller.
/// Shared tasks with independent consumers should keep using `value` instead.
public extension Task where Failure == Never {
    var cancellableValue: Success {
        get async {
            await withTaskCancellationHandler {
                await value
            } onCancel: {
                cancel()
            }
        }
    }
}

public extension Task where Failure == any Error {
    var cancellableValue: Success {
        get async throws {
            try await withTaskCancellationHandler {
                try await value
            } onCancel: {
                cancel()
            }
        }
    }
}
