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
}
