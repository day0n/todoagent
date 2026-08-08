import Foundation

enum WorkspaceAuthorizationStore {
    private static let key = "TodoAgent.authorizedWorkspaceBookmarks.v1"

    static func save(_ url: URL) throws {
        let bookmark = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        var values = UserDefaults.standard.dictionary(forKey: key) as? [String: Data] ?? [:]
        values[url.standardizedFileURL.path] = bookmark
        UserDefaults.standard.set(values, forKey: key)
    }

    static func restore(_ path: String) -> URL? {
        guard let data = (UserDefaults.standard.dictionary(forKey: key) as? [String: Data])?[path] else { return nil }
        var stale = false
        return try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale)
    }
}
