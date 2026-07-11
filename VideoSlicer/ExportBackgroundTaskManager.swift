import UIKit

@MainActor
protocol ExportBackgroundTaskManaging {
    func beginExportTask(named name: String, expirationHandler: @escaping @MainActor () -> Void)
    func endExportTask()
}

@MainActor
final class ExportBackgroundTaskManager: ExportBackgroundTaskManaging {
    static let shared = ExportBackgroundTaskManager()

    private var taskIdentifier: UIBackgroundTaskIdentifier = .invalid

    func beginExportTask(named name: String, expirationHandler: @escaping @MainActor () -> Void) {
        endExportTask()

        taskIdentifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            Task { @MainActor in
                expirationHandler()
                self?.endExportTask()
            }
        }
    }

    func endExportTask() {
        guard taskIdentifier != .invalid else { return }

        UIApplication.shared.endBackgroundTask(taskIdentifier)
        taskIdentifier = .invalid
    }

    // MARK: - Creator priority hint

    /// Returns the QoS class that should be used to dispatch the export
    /// `Task` for the given subscription tier. Creator gets `.userInitiated`
    /// (high priority) so the system scheduler promotes paid renders
    /// ahead of background Free exports. Free uses `.utility` so
    /// Free yields to Creator renders during multi-render batches.
    ///
    /// Note: `TaskPriority.background` is the *lowest* priority in Swift's
    /// enum ordering (`.background < .utility < .medium < .userInitiated <
    /// .userInteractive`), not the highest — the previous code inverted the
    /// intent and deprioritized paid exports.
    static func exportQoS(for tier: SubscriptionStore.Tier) -> TaskPriority {
        switch tier {
        case .creator: return .userInitiated
        case .free:    return .utility
        }
    }
}
