#if os(iOS)
import BackgroundTasks
import HappierKit
import os

/// Keeps attachment uploads running after the app is backgrounded, through iOS 26 continued
/// processing tasks: the system shows their progress in a Live Activity (Dynamic Island, Lock
/// Screen), where the user can also cancel them. When the system can't grant one right now the
/// upload simply continues in the foreground as before.
@MainActor
final class BackgroundUploads: UploadObserver {
    private let store: HappierStore
    private var tasks: [String: BGContinuedProcessingTask] = [:]
    /// Latest progress per upload, applied when the system hands over the task.
    private var fractions: [String: Double] = [:]
    private var subtitles: [String: String] = [:]
    private let log = Logger(subsystem: "dev.happier.apple", category: "uploads")

    init(store: HappierStore) {
        self.store = store
        store.uploadObserver = self
    }

    /// `BGTaskSchedulerPermittedIdentifiers` lists `<bundle id>.upload.*`.
    private func identifier(for localId: String) -> String {
        "\(Bundle.main.bundleIdentifier ?? "com.devmanny.happier").upload.\(localId)"
    }

    func uploadDidStart(localId: String, sessionTitle: String, fileCount: Int) {
        let identifier = identifier(for: localId)
        fractions[localId] = 0
        let files = fileCount == 1 ? String(localized: "1 file") : String(localized: "\(fileCount) files")
        subtitles[localId] = files
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { [weak self] task in
            nonisolated(unsafe) let task = task
            MainActor.assumeIsolated { self?.attach(task, localId: localId) }
        }
        guard registered else {
            log.error("background upload task not registered (Info.plist identifiers?)")
            return
        }
        let request = BGContinuedProcessingTaskRequest(
            identifier: identifier, title: String(localized: "Sending to \(sessionTitle)"), subtitle: files)
        // Run now or not at all: a queued task starting after the upload ended would be pointless.
        request.strategy = .fail
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            log.notice("background upload task not granted: \(String(describing: error), privacy: .public)")
        }
    }

    func uploadDidProgress(localId: String, fraction: Double) {
        let previous = fractions[localId] ?? 0
        fractions[localId] = fraction
        guard let task = tasks[localId] else { return }
        task.progress.completedUnitCount = Int64(fraction * 1000)
        // The Live Activity subtitle follows whole percents only.
        if Int(fraction * 100) != Int(previous * 100) {
            task.updateTitle(task.title, subtitle: subtitle(localId, fraction))
        }
    }

    func uploadDidFinish(localId: String, success: Bool) {
        fractions[localId] = nil
        subtitles[localId] = nil
        guard let task = tasks.removeValue(forKey: localId) else { return }
        task.progress.completedUnitCount = success ? 1000 : task.progress.completedUnitCount
        task.setTaskCompleted(success: success)
    }

    private func attach(_ task: BGTask, localId: String) {
        guard let task = task as? BGContinuedProcessingTask else {
            task.setTaskCompleted(success: false)
            return
        }
        // The upload may already be over by the time the system starts the task.
        guard let fraction = fractions[localId] else {
            task.setTaskCompleted(success: true)
            return
        }
        task.progress.totalUnitCount = 1000
        task.progress.completedUnitCount = Int64(fraction * 1000)
        task.expirationHandler = { [weak self] in
            // Cancelled from the Live Activity, or the system needed the resources back.
            Task { @MainActor in
                self?.store.cancelUpload(localId)
            }
        }
        tasks[localId] = task
    }

    private func subtitle(_ localId: String, _ fraction: Double) -> String {
        let percent = fraction.formatted(.percent.precision(.fractionLength(0)))
        return "\(subtitles[localId] ?? "") · \(percent)"
    }
}
#endif
