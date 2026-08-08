import Foundation
import Testing
@testable import TodoAgentApp

@Suite("Rust Engine client", .serialized)
struct EngineClientTests {
    @Test("Swift decodes every shared NDJSON contract message")
    func sharedContract() throws {
        let fixtureURL = repositoryRoot
            .appending(path: "protocol/fixtures/contract.ndjson")
        let contents = try String(contentsOf: fixtureURL, encoding: .utf8)
        let messages = try contents.split(whereSeparator: \.isNewline).map {
            try EngineWireMessage.decode(Data($0.utf8))
        }

        try #require(messages.count == 4)

        guard case let .event(ready) = messages[0] else {
            Issue.record("The first contract line must be engine.ready.")
            return
        }
        #expect(ready.name == "engine.ready")
        let handshake = try #require(
            JSONSerialization.jsonObject(with: ready.data) as? [String: Any]
        )
        #expect(handshake["protocolVersion"] as? Int == 1)
        #expect(handshake["engineVersion"] as? String == "0.1.0")

        guard case let .request(id, method, params) = messages[1] else {
            Issue.record("The second contract line must be a request.")
            return
        }
        #expect(id == "snapshot-1")
        #expect(method == "app.snapshot")
        #expect(try JSONSerialization.jsonObject(with: params) as? [String: String] == [:])

        guard case let .response(responseID, result) = messages[2] else {
            Issue.record("The third contract line must be a response.")
            return
        }
        #expect(responseID == "snapshot-1")
        let snapshot = try #require(
            JSONSerialization.jsonObject(with: result) as? [String: Any]
        )
        #expect((snapshot["lists"] as? [Any])?.isEmpty == true)
        #expect((snapshot["tasks"] as? [Any])?.isEmpty == true)

        guard case let .failure(errorID, code, message, details) = messages[3] else {
            Issue.record("The fourth contract line must be an error response.")
            return
        }
        #expect(errorID == "missing-1")
        #expect(code == "not_found")
        #expect(message == "requested record does not exist")
        #expect(details == nil)
    }

    @Test(
        "Engine process lifecycle",
        .serialized,
        .timeLimit(.minutes(1)),
        arguments: EngineLifecycleScenario.allCases
    )
    fileprivate func engineProcessLifecycle(_ scenario: EngineLifecycleScenario) async throws {
        switch scenario {
        case .immediateReadyAndRetry:
            try await immediateReadyAndRetry()
        case .failedHandshakeCanRetry:
            try await failedHandshakeCanRetry()
        case .automaticRestartHandshakes:
            try await automaticRestartHandshakes()
        }
    }

    private func immediateReadyAndRetry() async throws {
        let fake = try makeFakeEngine()
        defer { try? FileManager.default.removeItem(at: fake.directory) }

        let client = try EngineClient(
            executableURL: URL(fileURLWithPath: "/bin/zsh"),
            executableArguments: [fake.executable.path],
            requestTimeout: .seconds(8),
            handshakeTimeout: .seconds(8)
        )
        let events = await client.events()
        let collectedEvents = Task {
            var names: [String] = []
            for await event in events {
                names.append(event.name)
            }
            return names
        }

        do {
            try await start(client, stage: "initial immediate-ready start")
            #expect(await client.engineVersion == "fake-1.0.0")
            #expect(await client.capabilities == ["engine.shutdown"])

            await client.stop()
            let names = await collectedEvents.value
            #expect(names.contains("engine.ready"))

            try await start(client, stage: "start after graceful stop")
            #expect(await client.engineVersion == "fake-1.0.0")
            await client.stop()
        } catch {
            await client.stop()
            throw error
        }
    }

    private func failedHandshakeCanRetry() async throws {
        let fake = try makeFakeEngine(wrongProtocolOnFirstLaunch: true)
        defer { try? FileManager.default.removeItem(at: fake.directory) }

        let client = try EngineClient(
            executableURL: URL(fileURLWithPath: "/bin/zsh"),
            executableArguments: [fake.executable.path],
            requestTimeout: .seconds(8),
            handshakeTimeout: .seconds(8)
        )

        do {
            try await client.start()
            Issue.record("The first handshake should have been rejected.")
        } catch let error as EngineClientError {
            #expect(error == .protocolMismatch(expected: 1, received: 999))
        }

        do {
            try await start(client, stage: "retry after rejected handshake")
            #expect(await client.engineVersion == "fake-1.0.0")
            await client.stop()
        } catch {
            await client.stop()
            throw error
        }
    }

    private func automaticRestartHandshakes() async throws {
        let fake = try makeFakeEngine()
        defer { try? FileManager.default.removeItem(at: fake.directory) }

        let client = try EngineClient(
            executableURL: URL(fileURLWithPath: "/bin/zsh"),
            executableArguments: [fake.executable.path],
            requestTimeout: .seconds(8),
            handshakeTimeout: .seconds(8)
        )
        let events = await client.events()
        let secondReady = Task {
            var readyCount = 0
            for await event in events where event.name == "engine.ready" {
                readyCount += 1
                if readyCount == 2 { return true }
            }
            return false
        }

        do {
            try await start(client, stage: "initial automatic-restart start")

            do {
                let _: EmptyTestResult = try await client.request(
                    method: "test.exit",
                    params: EmptyTestParams()
                )
                Issue.record("test.exit must end the first fake engine process.")
            } catch let error as EngineClientError {
                #expect(error == .processExited(17))
            }

            #expect(await secondReady.value)
            #expect(await client.engineVersion == "fake-1.0.0")
            #expect(await client.capabilities == ["engine.shutdown"])
            await client.stop()
        } catch {
            await client.stop()
            throw error
        }
    }

    private var repositoryRoot: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 {
            url.deleteLastPathComponent()
        }
        return url
    }

    private func start(_ client: EngineClient, stage: String) async throws {
        do {
            try await client.start()
        } catch {
            Issue.record("\(stage) failed: \(error)")
            throw error
        }
    }

    private func makeFakeEngine(
        wrongProtocolOnFirstLaunch: Bool = false
    ) throws -> TemporaryFakeEngine {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "todoagent-engine-test-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let executable = directory.appending(path: "fake-engine")
        let firstLaunchBlock = wrongProtocolOnFirstLaunch
            ? #"""
            marker="$0.first-launch-complete"
            if [[ ! -e "$marker" ]]; then
              /usr/bin/touch "$marker"
              protocol_version=999
            fi
            """#
            : ""

        var script = #"""
        #!/bin/zsh
        protocol_version=1
        __FIRST_LAUNCH_BLOCK__
        printf '{"event":"engine.ready","data":{"protocolVersion":%s,"engineVersion":"fake-1.0.0","capabilities":["engine.shutdown"]}}\n' "$protocol_version"

        while IFS= read -r line; do
          if [[ "$line" == *'"method":"engine.shutdown"'* ]]; then
            request_id="$(printf '%s' "$line" | /usr/bin/sed -E 's/.*"id":"([^"]+)".*/\1/')"
            printf '{"id":"%s","result":{"ok":true}}\n' "$request_id"
            exit 0
          fi
          if [[ "$line" == *'"method":"test.exit"'* ]]; then
            exit 17
          fi
        done
        """#
        script = script.replacingOccurrences(
            of: "__FIRST_LAUNCH_BLOCK__",
            with: firstLaunchBlock
        )

        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: executable.path
        )
        return TemporaryFakeEngine(directory: directory, executable: executable)
    }
}

private struct TemporaryFakeEngine: Sendable {
    let directory: URL
    let executable: URL
}

private enum EngineLifecycleScenario: CaseIterable, Sendable {
    case immediateReadyAndRetry
    case failedHandshakeCanRetry
    case automaticRestartHandshakes
}

private struct EmptyTestParams: Encodable, Sendable {}
private struct EmptyTestResult: Decodable, Sendable {}
