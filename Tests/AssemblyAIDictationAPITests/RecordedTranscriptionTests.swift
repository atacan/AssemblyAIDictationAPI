import AssemblyAIDictationAPI
import AssemblyAIDictationAPITypes
import Foundation
import HTTPTypes
import OpenAPIRuntime
import Testing

struct RecordedTranscriptionTests {
    @Test(arguments: [false, true])
    func recordingAcceptsOptionalConfigAfterAudio(includeConfig: Bool) async throws {
        let client = try makeClient(includeConfig: includeConfig)
        let output = try await client.transcribeDictationRecording(body: recordingBody(includeConfig: includeConfig))
        let response = try output.ok.body.json
        #expect(response.text == "Recorded dictation.")
        #expect(response.audio_duration_ms == 180_000)
    }

    @Test func recordingDecodesAudioTooLargeDetail() async throws {
        let client = try makeClient(status: .contentTooLarge)
        let output = try await client.transcribeDictationRecording(body: recordingBody())
        let response = try output.contentTooLarge.body.json
        #expect(response.status == 413)
        #expect(response.title == "Audio Too Large")
        #expect(response.detail == "Audio is longer than 20 minutes.")
    }

    private func makeClient(includeConfig: Bool = false, status: HTTPResponse.Status = .ok) throws -> Client {
        Client(
            serverURL: try #require(URL(string: "https://example.invalid")),
            transport: RecordingTransport(includeConfig: includeConfig, status: status),
            authentication: .apiKey("offline-test-key")
        )
    }

    private func recordingBody(includeConfig: Bool = false) -> Operations.transcribeDictationRecording.Input.Body {
        typealias Part = Operations.transcribeDictationRecording.Input.Body.multipartFormPayload
        let parts = AsyncStream<Part> { continuation in
            continuation.yield(.audio(.init(payload: .init(body: HTTPBody("recorded audio")), filename: "recording.wav")))
            if includeConfig {
                continuation.yield(.config(.init(payload: .init(body: .init(rewrite_mode: .smart)))))
            }
            continuation.finish()
        }
        return .multipartForm(MultipartBody(parts))
    }
}

private struct RecordingTransport: ClientTransport {
    let includeConfig: Bool
    let status: HTTPResponse.Status

    func send(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String
    ) async throws -> (HTTPResponse, HTTPBody?) {
        #expect(operationID == "transcribeDictationRecording")
        #expect(request.method == .post)
        #expect(request.path == "/v1/transcribe")
        #expect(request.headerFields[.authorization] == "offline-test-key")
        #expect(request.headerFields[.contentType]?.hasPrefix("multipart/form-data; boundary=") == true)
        let body = try #require(body)
        let data = try await Data(collecting: body, upTo: 16_384)
        let wire = try #require(String(data: data, encoding: .utf8))
        let audio = try #require(wire.range(of: "name=\"audio\""))
        #expect(wire.contains("filename=\"recording.wav\""))
        #expect(wire.lowercased().contains("content-type: audio/wav\r\n"))
        #expect(wire.contains("\r\n\r\nrecorded audio\r\n"))
        if includeConfig {
            let config = try #require(wire.range(of: "name=\"config\""))
            #expect(audio.lowerBound < config.lowerBound)
            #expect(wire.contains("application/json"))
            let configStart = try #require(wire.range(of: "\r\n\r\n", range: config.upperBound ..< wire.endIndex))
            let configEnd = try #require(wire.range(of: "\r\n--", range: configStart.upperBound ..< wire.endIndex))
            let configJSON = Data(wire[configStart.upperBound ..< configEnd.lowerBound].utf8)
            let configObject = try JSONDecoder().decode([String: String].self, from: configJSON)
            #expect(configObject["rewrite_mode"] == "smart")
        } else {
            #expect(!wire.contains("name=\"config\""))
        }

        let response =
            status == .ok
            ? #"{"text":"Recorded dictation.","words":[],"confidence":0.99,"llm_response":null,"llm_error":null,"audio_duration_ms":180000,"session_id":"eb92c4ff-4bbb-429f-9b99-7279d7fe738f"}"#
            : #"{"status":413,"title":"Audio Too Large","detail":"Audio is longer than 20 minutes."}"#
        return (
            HTTPResponse(status: status, headerFields: [.contentType: "application/json"]),
            HTTPBody(response)
        )
    }
}
