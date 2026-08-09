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

        try #require(messages.count == 15)

        guard case let .event(ready) = messages[0] else {
            Issue.record("The first contract line must be engine.ready.")
            return
        }
        #expect(ready.name == "engine.ready")
        let handshake = try #require(
            JSONSerialization.jsonObject(with: ready.data) as? [String: Any]
        )
        #expect(handshake["protocolVersion"] as? Int == 2)
        #expect(handshake["engineVersion"] as? String == "0.1.0")

        guard case let .request(id, method, params) = messages[1] else {
            Issue.record("The second contract line must be a request.")
            return
        }
        #expect(id == "bootstrap-1")
        #expect(method == "app.bootstrap")
        #expect(try JSONSerialization.jsonObject(with: params) as? [String: String] == [:])

        guard case let .response(responseID, result) = messages[2] else {
            Issue.record("The third contract line must be a response.")
            return
        }
        #expect(responseID == "bootstrap-1")
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

        guard case let .response(listResponseID, listResult) = messages[5] else {
            Issue.record("The assistant list fixture must include its response.")
            return
        }
        #expect(listResponseID == "assistant-list-1")
        let listed = try JSONDecoder().decode(AssistantSessionListResponse.self, from: listResult)
        #expect(listed.sessions.first?.displayTitle == "原生助手")
        #expect(listed.sessions.first?.isRunning == false)

        guard case let .request(sendID, sendMethod, sendParams) = messages[6] else {
            Issue.record("The assistant send fixture must be a request.")
            return
        }
        #expect(sendID == "assistant-send-1")
        #expect(sendMethod == "assistant.send")
        let sendObject = try #require(
            JSONSerialization.jsonObject(with: sendParams) as? [String: Any]
        )
        #expect(sendObject["sessionId"] as? String == "00000000-0000-4000-8000-000000000201")
        #expect(sendObject["clientMessageId"] as? String == "00000000-0000-4000-8000-000000000202")
        #expect(sendObject["model"] as? String == "gemini-3.6-flash")

        guard case let .event(deltaEvent) = messages[8] else {
            Issue.record("The ninth contract line must be an assistant delta event.")
            return
        }
        #expect(deltaEvent.name == "assistant.message.delta")
        let delta = try JSONDecoder().decode(AssistantMessageDeltaEvent.self, from: deltaEvent.data)
        #expect(delta.turnID == "00000000-0000-4000-8000-000000000203")
        #expect(delta.attempt == 1)
        #expect(delta.delta == "已经创建")

        guard case let .event(appendedEvent) = messages[11] else {
            Issue.record("The twelfth contract line must be an appended assistant message.")
            return
        }
        #expect(appendedEvent.name == "assistant.message.appended")
        let appended = try JSONDecoder().decode(
            AssistantMessageAppendedEvent.self,
            from: appendedEvent.data
        )
        #expect(appended.message.sequence == 2)
        #expect(appended.message.role == .todoAgent)
        let referencedTaskID = try #require(UUID(uuidString: "00000000-0000-4000-8000-000000000101"))
        #expect(appended.message.taskReferences == [referencedTaskID])

        guard case let .response(historyResponseID, historyResult) = messages[14] else {
            Issue.record("The final contract line must be an assistant history response.")
            return
        }
        #expect(historyResponseID == "assistant-history-1")
        let history = try JSONDecoder().decode(AssistantSessionBundle.self, from: historyResult)
        #expect(history.activeTurn == nil)
        #expect(history.tools.first?.callID == "call-1")
        #expect(history.tools.first?.taskReferences == [referencedTaskID])
    }

    @Test("CLI requests use the Engine's camel-case identifier fields")
    func cliRequestWireFields() throws {
        let taskID = try #require(UUID(uuidString: "00000000-0000-4000-8000-000000000401"))
        let clientMessageID = try #require(
            UUID(uuidString: "00000000-0000-4000-8000-000000000402")
        )

        func object<T: Encodable>(_ value: T) throws -> [String: Any] {
            try #require(
                JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
                    as? [String: Any]
            )
        }

        let taskObject = try object(SessionLookup(sessionID: nil, taskID: taskID))

        #expect(taskObject["taskId"] as? String == taskID.uuidString)
        #expect(taskObject["taskID"] == nil)
        #expect(taskObject["sessionId"] == nil)

        let sessionObject = try object(
            SessionLookup(sessionID: "logical-session", taskID: nil)
        )

        #expect(sessionObject["sessionId"] as? String == "logical-session")
        #expect(sessionObject["sessionID"] == nil)
        #expect(sessionObject["taskId"] == nil)

        let createTask = try object(
            CreateTaskRequest(title: "任务", note: "", listID: taskID, dueDate: nil)
        )
        #expect(createTask["listId"] as? String == taskID.uuidString)
        #expect(createTask["listID"] == nil)

        let taskStatus = try object(TaskIDRequest(taskID: taskID))
        #expect(taskStatus["taskId"] as? String == taskID.uuidString)
        #expect(taskStatus["taskID"] == nil)

        let createSession = try object(
            CreateSessionRequest(
                taskID: taskID,
                runtimeKind: .codex,
                workingDirectory: "/tmp/project",
                clientMessageID: clientMessageID
            )
        )
        #expect(createSession["taskId"] as? String == taskID.uuidString)
        #expect(createSession["clientMessageId"] as? String == clientMessageID.uuidString)
        #expect(createSession["taskID"] == nil)
        #expect(createSession["clientMessageID"] == nil)

        let send = try object(
            SendSessionRequest(
                sessionID: "logical-session",
                clientMessageID: clientMessageID,
                text: "继续"
            )
        )
        #expect(send["sessionId"] as? String == "logical-session")
        #expect(send["clientMessageId"] as? String == clientMessageID.uuidString)
        #expect(send["sessionID"] == nil)
        #expect(send["clientMessageID"] == nil)

        let history = try object(
            HistoryRequest(sessionID: "logical-session", afterSequence: 3, limit: 500)
        )
        #expect(history["sessionId"] as? String == "logical-session")
        #expect(history["sessionID"] == nil)

        let markRead = try object(
            MarkReadRequest(sessionID: "logical-session", throughSequence: 4)
        )
        #expect(markRead["sessionId"] as? String == "logical-session")
        #expect(markRead["sessionID"] == nil)

        let cancel = try object(SessionIDRequest(sessionID: "logical-session"))
        #expect(cancel["sessionId"] as? String == "logical-session")
        #expect(cancel["sessionID"] == nil)
    }

    @Test("CLI Session bundles decode Engine camel-case identifier fields")
    func cliSessionBundleWireFields() throws {
        let data = Data(
            #"""
            {
              "session": {
                "id": "logical-session",
                "taskId": "00000000-0000-4000-8000-000000000401",
                "runtimeKind": "codex",
                "workingDirectory": "/tmp/project",
                "providerSessionId": "provider-session",
                "providerEngine": null,
                "state": "idle",
                "lastAgentSequence": 2,
                "lastReadSequence": 1,
                "lastErrorCode": null,
                "lastErrorMessage": null,
                "createdAt": "2026-08-09T00:00:00Z",
                "updatedAt": "2026-08-09T00:00:01Z"
              },
              "messages": [{
                "id": "message-1",
                "sessionId": "logical-session",
                "turnId": "turn-1",
                "sequence": 2,
                "clientMessageId": "00000000-0000-4000-8000-000000000402",
                "role": "agent",
                "kind": "text",
                "body": "完成",
                "payloadJson": null,
                "createdAt": "2026-08-09T00:00:00Z",
                "updatedAt": "2026-08-09T00:00:01Z"
              }],
              "activeTurn": {
                "id": "turn-1",
                "sessionId": "logical-session",
                "ordinal": 1,
                "userMessageId": "message-user",
                "providerSessionIdBefore": null,
                "providerSessionIdAfter": "provider-session",
                "status": "completed",
                "exitCode": 0,
                "finalOutput": "完成",
                "errorCode": null,
                "errorMessage": null,
                "providerUsageJson": "{}",
                "startedAt": "2026-08-09T00:00:00Z",
                "endedAt": "2026-08-09T00:00:01Z",
                "createdAt": "2026-08-09T00:00:00Z"
              }
            }
            """#.utf8
        )
        let bundle = try JSONDecoder().decode(SessionBundle.self, from: data)

        #expect(bundle.session.taskID.uuidString == "00000000-0000-4000-8000-000000000401")
        #expect(bundle.session.providerSessionID == "provider-session")
        #expect(bundle.messages.first?.sessionID == "logical-session")
        #expect(bundle.messages.first?.turnID == "turn-1")
        #expect(bundle.messages.first?.clientMessageID == "00000000-0000-4000-8000-000000000402")
        #expect(bundle.activeTurn?.userMessageID == "message-user")
        #expect(bundle.activeTurn?.providerSessionIDAfter == "provider-session")
        #expect(bundle.activeTurn?.providerUsageJSON == "{}")
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

    @Test("Repository load keeps persisted runtimes and verify uses its extended timeout")
    func repositoryRuntimeLifecycle() async throws {
        let fake = try makeRuntimeRepositoryFakeEngine()
        defer { try? FileManager.default.removeItem(at: fake.directory) }

        let client = try EngineClient(
            executableURL: URL(fileURLWithPath: "/bin/zsh"),
            executableArguments: [fake.executable.path],
            requestTimeout: .milliseconds(100),
            handshakeTimeout: .seconds(2)
        )
        let repository = EngineRepository(client: client)

        do {
            let initial = try await repository.load()
            #expect(initial.runtimes.first?.status == .ready)
            #expect(initial.runtimes.first?.verifiedAt == "2026-08-09T00:02:00Z")
            let initialRequests = try String(contentsOf: fake.requestLog, encoding: .utf8)
            #expect(initialRequests.contains(#""method":"app.bootstrap""#))
            #expect(initialRequests.contains(#""method":"runtime.detect""#) == false)
            #expect(initialRequests.contains(#""method":"runtime.verify""#) == false)

            // The fake runtime verifier deliberately takes longer than the
            // client's generic request timeout. EngineRepository's dedicated
            // verification budget must let it complete normally.
            let verified = try await repository.verifyRuntime(.codex)
            #expect(verified.runtimes.first?.status == .ready)
            #expect(verified.runtimes.first?.verifiedAt == "2026-08-09T00:02:00Z")

            let allRequests = try String(contentsOf: fake.requestLog, encoding: .utf8)
            #expect(allRequests.contains(#""method":"runtime.verify""#))
            #expect(allRequests.contains(#""method":"app.sync""#))
            await repository.shutdown()
        } catch {
            await repository.shutdown()
            throw error
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
            #expect(error == .protocolMismatch(expected: 2, received: 999))
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
        protocol_version=2
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

    private func makeRuntimeRepositoryFakeEngine() throws -> TemporaryRuntimeRepositoryEngine {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "todoagent-runtime-test-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let executable = directory.appending(path: "fake-runtime-engine")
        let requestLog = URL(fileURLWithPath: executable.path + ".requests.ndjson")
        let script = #"""
        #!/bin/zsh
        request_log="$0.requests.ndjson"
        : > "$request_log"
        printf '{"event":"engine.ready","data":{"protocolVersion":2,"engineVersion":"fake-runtime-1.0.0","capabilities":["engine.shutdown"]}}\n'

        runtime='{"kind":"codex","launchPath":"/usr/local/bin/codex","resolvedPath":"/opt/codex/bin/codex","version":"codex-cli 1.2.3","status":"ready","authStatus":"authenticated","capabilities":{},"providerEngine":null,"detectedAt":"2026-08-09T00:01:00Z","verifiedAt":"2026-08-09T00:02:00Z","verifyError":null}'
        verified_bootstrap='{"revision":0,"lists":[],"tasks":[],"runtimes":['"$runtime"'],"sessions":[]}'

        while IFS= read -r line; do
          printf '%s\n' "$line" >> "$request_log"
          request_id="$(printf '%s' "$line" | /usr/bin/sed -E 's/.*"id":"([^"]+)".*/\1/')"
          if [[ "$line" == *'"method":"engine.shutdown"'* ]]; then
            printf '{"id":"%s","result":{"ok":true}}\n' "$request_id"
            exit 0
          fi
          if [[ "$line" == *'"method":"app.bootstrap"'* ]]; then
            printf '{"id":"%s","result":%s}\n' "$request_id" "$verified_bootstrap"
            continue
          fi
          if [[ "$line" == *'"method":"runtime.verify"'* ]]; then
            /bin/sleep 0.35
            printf '{"id":"%s","result":%s}\n' "$request_id" "$runtime"
            continue
          fi
          if [[ "$line" == *'"method":"app.sync"'* ]]; then
            printf '{"id":"%s","result":%s}\n' "$request_id" "$verified_bootstrap"
            continue
          fi
        done
        """#

        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: executable.path
        )
        return TemporaryRuntimeRepositoryEngine(
            directory: directory,
            executable: executable,
            requestLog: requestLog
        )
    }
}

private struct TemporaryFakeEngine: Sendable {
    let directory: URL
    let executable: URL
}

private struct TemporaryRuntimeRepositoryEngine: Sendable {
    let directory: URL
    let executable: URL
    let requestLog: URL
}

private enum EngineLifecycleScenario: CaseIterable, Sendable {
    case immediateReadyAndRetry
    case failedHandshakeCanRetry
    case automaticRestartHandshakes
}

private struct EmptyTestParams: Encodable, Sendable {}
private struct EmptyTestResult: Decodable, Sendable {}
