import Darwin
import Foundation
import Testing
@testable import TodoAgentApp

@Suite("Gemini local credential file")
struct CredentialFileStoreTests {
    @Test("round trips a credential with account-only permissions")
    func roundTripAndPermissions() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let store = GeminiCredentialFileStore(directoryURL: fixture.credentialDirectory)

        try store.save("test-gemini-key")

        #expect(try store.load() == "test-gemini-key")
        #expect(try permissions(of: fixture.credentialDirectory) == 0o700)
        #expect(try permissions(of: fixture.credentialFile) == 0o600)
    }

    @Test("atomically replaces an existing credential without leaving temporary files")
    func atomicReplacement() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let store = GeminiCredentialFileStore(directoryURL: fixture.credentialDirectory)

        try store.save("first-key")
        try store.save("second-key")

        #expect(try store.load() == "second-key")
        let names = try FileManager.default.contentsOfDirectory(atPath: fixture.credentialDirectory.path)
        #expect(names == [GeminiCredentialFileStore.fileName])
    }

    @Test("deletes only the credential file and is idempotent")
    func deleteCredential() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let store = GeminiCredentialFileStore(directoryURL: fixture.credentialDirectory)
        try store.save("test-key")
        let unrelated = fixture.credentialDirectory.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: unrelated)

        #expect(try store.delete() == .removed)
        #expect(try store.delete() == .notFound)
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
    }

    @Test("rejects a symbolic-link credential without touching its target")
    func rejectsCredentialSymlink() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try FileManager.default.createDirectory(
            at: fixture.credentialDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let target = fixture.root.appendingPathComponent("target.json")
        try Data("do-not-touch".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(
            at: fixture.credentialFile,
            withDestinationURL: target
        )
        let store = GeminiCredentialFileStore(directoryURL: fixture.credentialDirectory)

        #expect(throws: CredentialFileError.symbolicLink) {
            try store.save("new-key")
        }
        #expect(try Data(contentsOf: target) == Data("do-not-touch".utf8))
    }

    @Test("rejects a symbolic-link credential directory")
    func rejectsDirectorySymlink() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let realDirectory = fixture.root.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: realDirectory, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(
            at: fixture.credentialDirectory,
            withDestinationURL: realDirectory
        )
        let store = GeminiCredentialFileStore(directoryURL: fixture.credentialDirectory)

        #expect(throws: CredentialFileError.symbolicLink) {
            try store.save("new-key")
        }
    }

    @Test("rejects a symbolic link in an intermediate directory component")
    func rejectsIntermediateDirectorySymlink() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let realParent = fixture.root.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: realParent, withIntermediateDirectories: false)
        let linkedParent = fixture.root.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linkedParent, withDestinationURL: realParent)
        let linkedCredentialDirectory = linkedParent.appendingPathComponent("TodoAgent", isDirectory: true)
        let store = GeminiCredentialFileStore(directoryURL: linkedCredentialDirectory)

        #expect(throws: CredentialFileError.symbolicLink) {
            try store.save("new-key")
        }
        #expect(
            FileManager.default.fileExists(
                atPath: realParent
                    .appendingPathComponent("TodoAgent", isDirectory: true)
                    .appendingPathComponent(GeminiCredentialFileStore.fileName)
                    .path
            ) == false
        )
    }

    @Test("rejects credentials readable by another account")
    func rejectsBroadPermissions() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let store = GeminiCredentialFileStore(directoryURL: fixture.credentialDirectory)
        try store.save("test-key")
        #expect(chmod(fixture.credentialFile.path, mode_t(0o644)) == 0)

        #expect(throws: CredentialFileError.insecurePermissions(0o44)) {
            try store.load()
        }
        #expect(try store.delete() == .removed)
    }

    @Test("reports corrupted and oversized credential documents")
    func rejectsInvalidDocuments() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try FileManager.default.createDirectory(
            at: fixture.credentialDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let store = GeminiCredentialFileStore(directoryURL: fixture.credentialDirectory)

        try Data("not-json".utf8).write(to: fixture.credentialFile)
        #expect(chmod(fixture.credentialFile.path, mode_t(0o600)) == 0)
        #expect(throws: CredentialFileError.corruptedData) {
            try store.load()
        }

        try Data(repeating: 0x41, count: GeminiCredentialFileStore.maximumFileSize + 1)
            .write(to: fixture.credentialFile)
        #expect(chmod(fixture.credentialFile.path, mode_t(0o600)) == 0)
        #expect(throws: CredentialFileError.fileTooLarge) {
            try store.load()
        }
    }
}

private struct Fixture {
    let root: URL
    let credentialDirectory: URL

    init() throws {
        // `/var` is itself a symlink on macOS, so use the canonical temp path
        // when exercising O_NOFOLLOW_ANY.
        root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("todoagent-credential-tests-\(UUID().uuidString)", isDirectory: true)
        credentialDirectory = root.appendingPathComponent("TodoAgent", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }

    var credentialFile: URL {
        credentialDirectory.appendingPathComponent(GeminiCredentialFileStore.fileName)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

private func permissions(of url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    let value = try #require(attributes[.posixPermissions] as? NSNumber)
    return value.intValue & 0o777
}
