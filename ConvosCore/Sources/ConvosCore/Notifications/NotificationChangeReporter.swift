import GRDB

public protocol NotificationChangeReporterType {
    func notifyChangesInDatabase()
}

/// Notifies GRDB value observers of database changes made by external processes.
///
/// This class exists because GRDB's value observation mechanism only detects changes made within
/// the same process. When the Notification Service Extension modifies the database (e.g., saving
/// new messages received via push notifications), the main app's GRDB observers do not
/// automatically see these changes.
///
/// By calling `notifyChangesInDatabase()` when the app returns to the foreground, we manually
/// trigger GRDB to re-check for changes, ensuring the UI updates to reflect any messages or
/// data that were written by the notification extension while the app was backgrounded.
///
/// ## Usage
/// Call `notifyChangesInDatabase()` when `UIApplication.willEnterForegroundNotification` is received
/// to ensure all GRDB value observations are refreshed with any external changes.
public
final
class NotificationChangeReporter: NotificationChangeReporterType {
    let databaseWriter: any DatabaseWriter

    init(databaseWriter: any DatabaseWriter) {
        self.databaseWriter = databaseWriter
    }

    public func notifyChangesInDatabase() {
        do {
            try databaseWriter.write { db in
                try db.notifyChanges(in: .fullDatabase)
            }
        } catch {
            Log.error("Error notifying changes in conversations table: \(error.localizedDescription)")
        }
    }
}
