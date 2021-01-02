import Foundation
import PersistedPropertyWrapper
import BackgroundTasks
import UIKit
import os.log

enum BackupFrequencyPeriod: Int, CaseIterable {
    case daily = 1
    case weekly = 2
    case off = 0
}

extension BackupFrequencyPeriod {
    var duration: TimeInterval? {
        switch self {
        case .daily: return 60 * 60 * 24
        case .weekly: return 60 * 60 * 24 * 7
        case .off: return nil
        }
    }
}

extension Notification.Name {
    static let autoBackupEnabledOrDisabled = Notification.Name("autoBackupEnabledOrDisabled")
}

class AutoBackupManager {
    static let shared = AutoBackupManager()

    private init() {
        if #available(iOS 13.0, *) {
            NotificationCenter.default.addObserver(self, selector: #selector(backgroundRefreshStatusChanged), name: UIApplication.backgroundRefreshStatusDidChangeNotification, object: nil)
        }
    }

    @objc private func backgroundRefreshStatusChanged() {
        guard #available(iOS 13.0, *) else {
            os_log("Unexpected call to backgroundRefreshStatusChanged", type: .error)
            return
        }
        // If background app refresh has become available, schedule one now.
        if UIApplication.shared.backgroundRefreshStatus == .available {
            self.scheduleBackup()
        } else {
            self.nextBackupEarliestStartDate = nil
        }
    }

    var cannotRunScheduledAutoBackups: Bool {
        guard #available(iOS 13.0, *) else { return false }
        return UIApplication.shared.backgroundRefreshStatus != .available && backupFrequency != .off
    }

    @Persisted("backup-frequency-period", defaultValue: .daily)
    private(set) var backupFrequency: BackupFrequencyPeriod

    /// Sets the new backup frequency, cancelling or re-scheduling an auto-backup if appropriate. If auto-backups have been disabled or enabled by this call,
    /// posts a `.autoBackupEnabledOrDisabled` notification.
    func setBackupFrequency(_ newBackupFrequency: BackupFrequencyPeriod) {
        if backupFrequency == newBackupFrequency { return }
        let isEnableOrDisableChange = backupFrequency == .off || newBackupFrequency == .off
        backupFrequency = newBackupFrequency

        if #available(iOS 13.0, *) {
            if newBackupFrequency == .off {
                cancelScheduledBackup()
            } else {
                scheduleBackup()
            }
        }
        if isEnableOrDisableChange {
            NotificationCenter.default.post(name: .autoBackupEnabledOrDisabled, object: nil)
        }
        UserEngagement.logEvent(newBackupFrequency == .off ? .disableAutoBackup : .changeAutoBackupFrequency)
    }

    @Persisted("last-backup-completion-date")
    var lastBackupCompletion: Date?

    @Persisted("next-backup-earliest-start-date")
    var nextBackupEarliestStartDate: Date?

    private let backgroundTaskIdentifier = "com.andrewbennet.books.backup"

    @available(iOS 13.0, *)
    func registerBackgroundTasks() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: backgroundTaskIdentifier, using: nil) { task in
            guard let processingTask = task as? BGProcessingTask else { preconditionFailure("Unexpected task type") }
            self.handleBackupTask(processingTask)
        }
    }

    func backupIsDue() -> Bool {
        guard let backupFrequencyDuration = backupFrequency.duration else { return false }
        guard let lastBackupCompletion = lastBackupCompletion else { return true }
        return lastBackupCompletion.addingTimeInterval(backupFrequencyDuration) < Date()
    }

    @available(iOS 13.0, *)
    func cancelScheduledBackup() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: backgroundTaskIdentifier)
        nextBackupEarliestStartDate = nil
    }

    @available(iOS 13.0, *)
    func scheduleBackup(startingAfter earliestBeginDate: Date? = nil) {
        guard let backupInterval = backupFrequency.duration else { return }

        let request = BGProcessingTaskRequest(identifier: backgroundTaskIdentifier)
        if let earliestBeginDate = earliestBeginDate {
            request.earliestBeginDate = earliestBeginDate
        } else if let lastBackup = lastBackupCompletion {
            request.earliestBeginDate = lastBackup.advanced(by: backupInterval)
        }
        nextBackupEarliestStartDate = request.earliestBeginDate ?? Date()

        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            guard let bgTaskError = error as? BGTaskScheduler.Error else {
                fatalError("Unexpected scheduling background task: \(error.localizedDescription)")
            }
            switch bgTaskError.code {
            case .tooManyPendingTaskRequests: fatalError("Unexpected 'tooManyPendingTaskRequests' error when scheduling background task")
            case .notPermitted: fatalError("Unexpected 'notPermitted' error when scheduling background task")
            case .unavailable:
                os_log("Background task scheduling is unavailable", type: .error)
            @unknown default:
                os_log("Unknown background task scheduling error with code %d", type: .error, bgTaskError.code.rawValue)
            }
        }
    }

    @available(iOS 13.0, *)
    func handleBackupTask(_ task: BGProcessingTask) {
        // Schedule a new backup task
        if let backupInterval = backupFrequency.duration {
            scheduleBackup(startingAfter: Date(timeIntervalSinceNow: backupInterval))
        }

        let backupManager = BackupManager()
        do {
            try backupManager.performBackup()
            task.setTaskCompleted(success: true)
        } catch {
            os_log("Background backup task failed: %{public}s", type: .error, error.localizedDescription)
            task.setTaskCompleted(success: false)
        }
        lastBackupCompletion = Date()
    }
}
