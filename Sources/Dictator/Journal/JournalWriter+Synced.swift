import Foundation

/// The Mac's journal resolves relative templates against the synced folder.
/// `JournalWriter` itself lives in DictatorCore and takes the base folder as
/// a parameter, because on iOS the equivalent is the user's shared folder;
/// these keep every Mac call site as it was.
extension JournalWriter {
    @MainActor
    static func resolvedURL(pathTemplate: String, date: Date = Date()) throws -> URL {
        try resolvedURL(pathTemplate: pathTemplate, relativeTo: SyncedStorage.directory, date: date)
    }

    @MainActor
    static func root(pathTemplate: String) -> URL? {
        root(pathTemplate: pathTemplate, relativeTo: SyncedStorage.directory)
    }

    @discardableResult
    @MainActor
    static func append(text: String,
                       pathTemplate: String,
                       headerTemplate: String,
                       entryTemplate: String,
                       appName: String?,
                       date: Date = Date()) throws -> Written {
        try append(text: text,
                   pathTemplate: pathTemplate,
                   relativeTo: SyncedStorage.directory,
                   headerTemplate: headerTemplate,
                   entryTemplate: entryTemplate,
                   appName: appName,
                   date: date)
    }
}
