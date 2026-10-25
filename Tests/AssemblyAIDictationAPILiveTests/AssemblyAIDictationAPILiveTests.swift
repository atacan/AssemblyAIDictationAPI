import AssemblyAIDictationAPI
import AssemblyAIDictationAPIAsyncHTTPClient
import AssemblyAIDictationAPITypes
import AssemblyAIDictationAPIURLSession
import Foundation
import Testing

@Suite(
    "AssemblyAI live endpoints",
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["ASSEMBLYAI_RUN_LIVE_TESTS"] == "1"),
    .timeLimit(.minutes(3))
)
struct AssemblyAIDictationAPILiveTests {
    @Test("GET /warm opens a connection without authentication", arguments: LiveTransport.allCases)
    func warm(transport: LiveTransport) async throws {
        let client = try transport.makeClient()
        let output: Operations.warm.Output
        do {
            output = try await client.warm()
        } catch {
            throw LiveTestError.requestFailed
        }

        switch output {
        case .ok(let value):
            let response = try value.body.json
            #expect(response.warm == "toasty")
        case .undocumented(let status, _):
            throw LiveTestError.unexpectedStatus(status)
        }
    }

    @Test("POST /v1/transcribe/live streams WAV audio", arguments: LiveTransport.allCases)
    func transcribeDictation(transport: LiveTransport) async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let apiKey = environment["ASSEMBLYAI_API_KEY"],
            !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw LiveTestError.missingAPIKey
        }

        let audioURL: URL
        if let path = environment["ASSEMBLYAI_AUDIO_FILE"] {
            audioURL = URL(fileURLWithPath: path)
        } else {
            audioURL = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("amazing-things.wav")
        }
        let file = try FileHandle(forReadingFrom: audioURL)
        // Also close on cancellation, early HTTP responses, or failed uploads.
        defer { try? file.close() }

        let client = try transport.makeClient(authentication: .apiKey(apiKey))
        let output: Operations.transcribeDictation.Output
        do {
            output = try await client.transcribeDictation(body: dictationBody(file: file, filename: audioURL.lastPathComponent))
        } catch {
            // OpenAPIRuntime.ClientError can contain the authenticated request.
            // Never let Swift Testing print that request or its headers.
            throw LiveTestError.requestFailed
        }

        let response: Components.Schemas.DictationResponse
        switch output {
        case .ok(let value): response = try value.body.json
        case .badRequest: throw LiveTestError.unexpectedStatus(400)
        case .unauthorized: throw LiveTestError.unexpectedStatus(401)
        case .contentTooLarge: throw LiveTestError.unexpectedStatus(413)
        case .unsupportedMediaType: throw LiveTestError.unexpectedStatus(415)
        case .tooManyRequests: throw LiveTestError.unexpectedStatus(429)
        case .badGateway: throw LiveTestError.unexpectedStatus(502)
        case .serviceUnavailable: throw LiveTestError.unexpectedStatus(503)
        case .gatewayTimeout: throw LiveTestError.unexpectedStatus(504)
        case .undocumented(let status, _): throw LiveTestError.unexpectedStatus(status)
        }

        #expect(!response.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(!response.words.isEmpty)
        #expect(response.words.allSatisfy { !$0.text.isEmpty && (0 ... 1).contains($0.confidence) })
        #expect((0 ... 1).contains(response.confidence))
        #expect(response.audio_duration_ms > 0 && response.audio_duration_ms <= 120_000)
        #expect(UUID(uuidString: response.session_id) != nil)

        // A rewrite failure is documented as a successful transcription.
        if response.llm_error == nil {
            let rewrite = try #require(response.llm_response)
            #expect(!rewrite.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    @Test("POST /v1/transcribe transcribes recorded WAV audio without config", arguments: LiveTransport.allCases)
    func transcribeDictationRecording(transport: LiveTransport) async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let apiKey = environment["ASSEMBLYAI_API_KEY"],
            !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw LiveTestError.missingAPIKey
        }

        let audioURL =
            environment["ASSEMBLYAI_AUDIO_FILE"].map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("amazing-things.wav")
        let file = try FileHandle(forReadingFrom: audioURL)
        defer { try? file.close() }

        let client = try transport.makeClient(authentication: .apiKey(apiKey))
        let output: Operations.transcribeDictationRecording.Output
        do {
            output = try await client.transcribeDictationRecording(body: recordingDictationBody(file: file, filename: audioURL.lastPathComponent))
        } catch {
            // Keep authenticated requests out of test failure messages.
            throw LiveTestError.requestFailed
        }

        let response: Components.Schemas.DictationResponse
        switch output {
        case .ok(let value): response = try value.body.json
        case .badRequest: throw LiveTestError.unexpectedStatus(400)
        case .unauthorized: throw LiveTestError.unexpectedStatus(401)
        case .contentTooLarge: throw LiveTestError.unexpectedStatus(413)
        case .unsupportedMediaType: throw LiveTestError.unexpectedStatus(415)
        case .tooManyRequests: throw LiveTestError.unexpectedStatus(429)
        case .badGateway: throw LiveTestError.unexpectedStatus(502)
        case .serviceUnavailable: throw LiveTestError.unexpectedStatus(503)
        case .gatewayTimeout: throw LiveTestError.unexpectedStatus(504)
        case .undocumented(let status, _): throw LiveTestError.unexpectedStatus(status)
        }

        #expect(!response.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(!response.words.isEmpty)
        #expect(response.words.allSatisfy { !$0.text.isEmpty && (0 ... 1).contains($0.confidence) })
        #expect((0 ... 1).contains(response.confidence))
        #expect(response.audio_duration_ms > 0 && response.audio_duration_ms <= 1_200_000)
        #expect(UUID(uuidString: response.session_id) != nil)

        if response.llm_error == nil {
            let rewrite = try #require(response.llm_response)
            #expect(!rewrite.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
}

enum LiveTransport: String, CaseIterable, Sendable {
    case urlSession
    case asyncHTTPClient

    func makeClient(authentication: Authentication = .none) throws -> Client {
        let serverURL = try Servers.Server1.url()
        switch self {
        case .urlSession:
            return .urlSession(serverURL: serverURL, authentication: authentication)
        case .asyncHTTPClient:
            return .asyncHTTPClient(serverURL: serverURL, authentication: authentication)
        }
    }
}

private enum LiveTestError: Error, CustomStringConvertible {
    case missingAPIKey
    case requestFailed
    case unexpectedStatus(Int)

    var description: String {
        switch self {
        case .missingAPIKey:
            return "Set ASSEMBLYAI_API_KEY before enabling live tests."
        case .requestFailed:
            return "Live request failed during transport or response decoding; request details are omitted to protect credentials."
        case .unexpectedStatus(let status):
            return "Expected HTTP 200, received HTTP \(status)."
        }
    }
}
