// Adapted from umputun/agterm and thdxg/macterm (MIT).

import Foundation

/// Selects a complete Ghostty runtime resource tree without trusting an
/// inherited `GHOSTTY_RESOURCES_DIR` from the process that launched TodoAgent.
struct GhosttyResourceResolver {
    let candidates: [URL]
    let isDirectory: (URL) -> Bool
    let fileExists: (URL) -> Bool

    func resolve() -> URL? {
        candidates.first { candidate in
            isDirectory(candidate.appendingPathComponent("shell-integration", isDirectory: true))
                && isDirectory(candidate.appendingPathComponent("themes", isDirectory: true))
                && fileExists(
                    candidate
                        .deletingLastPathComponent()
                        .appendingPathComponent("terminfo/78/xterm-ghostty", isDirectory: false)
                )
        }
    }
}

enum GhosttyBundledResources {
    static func candidates(bundle: Bundle? = nil) -> [URL] {
        let bundle = bundle ?? TodoAgentResourceBundle.bundle
        var result: [URL] = []
        if let root = bundle.resourceURL {
            result.append(root.appendingPathComponent("ghostty", isDirectory: true))
        }
        if bundle !== Bundle.main, let root = Bundle.main.resourceURL {
            result.append(root.appendingPathComponent("ghostty", isDirectory: true))
        }
        return result
    }

    static func resolve(bundle: Bundle? = nil, fileManager: FileManager = .default) -> URL? {
        GhosttyResourceResolver(
            candidates: candidates(bundle: bundle),
            isDirectory: { url in
                var isDirectory: ObjCBool = false
                return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
                    && isDirectory.boolValue
            },
            fileExists: { fileManager.fileExists(atPath: $0.path) }
        ).resolve()
    }
}
