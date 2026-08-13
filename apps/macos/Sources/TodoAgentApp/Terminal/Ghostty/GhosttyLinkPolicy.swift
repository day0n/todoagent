// Adapted from umputun/agterm and thdxg/macterm (MIT).

import Foundation

enum GhosttyLinkPolicy {
    enum Disposition: Equatable {
        case open(URL)
        case reveal(URL)
        case ignore
    }

    static let permittedSchemes: Set<String> = ["http", "https", "mailto", "ftp"]

    static let localHostNames: Set<String> = {
        var result: Set<String> = ["localhost"]
        var buffer = [CChar](repeating: 0, count: 256)
        if gethostname(&buffer, buffer.count) == 0 {
            let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
            result.formUnion(expandedHostNames(from: [String(decoding: bytes, as: UTF8.self)]))
        }
        return result
    }()

    static func disposition(for raw: String, localHosts: Set<String> = localHostNames) -> Disposition {
        guard !raw.contains("\0"), !raw.contains(where: { $0.isWhitespace }),
              let url = URL(string: raw), let scheme = url.scheme?.lowercased()
        else { return .ignore }

        if permittedSchemes.contains(scheme) { return .open(url) }
        guard scheme == "file" else { return .ignore }
        let host = normalizedHost(url.host(percentEncoded: false) ?? "")
        guard host.isEmpty || localHosts.contains(host) else { return .ignore }
        let rawPath = url.path(percentEncoded: false)
        guard rawPath.hasPrefix("/"), !rawPath.hasPrefix("//") else { return .ignore }
        let path = lexicallyNormalizedAbsolutePath(rawPath)
        guard !isAutomountPath(path) else { return .ignore }
        return .reveal(URL(fileURLWithPath: path, isDirectory: false))
    }

    static func expandedHostNames(from raw: Set<String>) -> Set<String> {
        var result: Set<String> = []
        for value in raw {
            let name = normalizedHost(value)
            guard !name.isEmpty else { continue }
            result.insert(name)
            if name.hasSuffix(".local") {
                let short = String(name.dropLast(6))
                if !short.isEmpty { result.insert(short) }
            }
        }
        return result
    }

    static func normalizedHost(_ host: String) -> String {
        let lower = host.lowercased()
        return lower.hasSuffix(".") ? String(lower.dropLast()) : lower
    }

    static func lexicallyNormalizedAbsolutePath(_ path: String) -> String {
        var components: [Substring] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            if component == "." { continue }
            if component == ".." {
                if !components.isEmpty { components.removeLast() }
                continue
            }
            components.append(component)
        }
        return "/" + components.joined(separator: "/")
    }

    static func isAutomountPath(_ path: String) -> Bool {
        let lower = path.lowercased()
        return [
            "/net", "/network", "/home", "/system/volumes/data/home",
            "/system/volumes/data/net", "/system/volumes/data/network/servers",
        ].contains { lower == $0 || lower.hasPrefix($0 + "/") }
    }
}
