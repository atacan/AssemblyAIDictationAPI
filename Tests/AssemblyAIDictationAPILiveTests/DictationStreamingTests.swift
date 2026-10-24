import AssemblyAIDictationAPI
import Foundation
import HTTPTypes
import OpenAPIRuntime
import Testing

struct DictationStreamingTests {
    @Test func fileHandleStreamsChunksAndEndsAtEOF() async throws {
        let bytes = Data((0 ..< 150_000).map { UInt8(truncatingIfNeeded: $0) })
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try bytes.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }

        var iterator = file.makeAsyncIterator()
        var received = Data()
        var chunkSizes: [Int] = []
        while let chunk = try await iterator.next() {
            received.append(contentsOf: chunk)
            chunkSizes.append(chunk.count)
        }

        #expect(chunkSizes == [65_536, 65_536, 18_928])
        #expect(received == bytes)
        let afterEOF = try await iterator.next()
        #expect(afterEOF == nil)
    }

    @Test func multipartUploadSendsConfigBeforeWAVAudio() async throws {
        let audio = Data(repeating: 65, count: 70_000)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try audio.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }

        let serverURL = try #require(URL(string: "https://example.invalid"))
        let client = Client(
            serverURL: serverURL,
            transport: InspectingTransport(expectedAudio: audio),
            authentication: .apiKey("offline-test-key")
        )
        let output = try await client.transcribeDictation(body: dictationBody(file: file, filename: "amazing-things.wav"))
        let response = try output.ok.body.json
        #expect(response.text == "Amazing things happen.")
    }
}

private struct InspectingTransport: ClientTransport {
    let expectedAudio: Data

    func send(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String
    ) async throws -> (HTTPResponse, HTTPBody?) {
        #expect(operationID == "transcribeDictation")
        #expect(request.method == .post)
        #expect(request.path == "/v1/transcribe/live")
        #expect(request.headerFields[.authorization] == "offline-test-key")
        #expect(request.headerFields[.contentType]?.hasPrefix("multipart/form-data; boundary=") == true)
        let body = try #require(body)
        let data = try await Data(collecting: body, upTo: 100_000)
        let wire = try #require(String(data: data, encoding: .utf8))
        let config = try #require(wire.range(of: "name=\"config\""))
        let audio = try #require(wire.range(of: "name=\"audio\""))
        try #require(config.lowerBound < audio.lowerBound)
        #expect(wire.contains("application/json"))
        let configStart = try #require(wire.range(of: "\r\n\r\n", range: config.upperBound ..< audio.lowerBound))
        let configEnd = try #require(wire.range(of: "\r\n--", range: configStart.upperBound ..< audio.lowerBound))
        let configJSON = Data(wire[configStart.upperBound ..< configEnd.lowerBound].utf8)
        let configObject = try JSONDecoder().decode([String: String].self, from: configJSON)
        #expect(configObject.isEmpty)
        #expect(wire.lowercased().contains("content-type: audio/wav\r\n"))
        #expect(wire.contains("filename=\"amazing-things.wav\""))
        #expect(data.range(of: expectedAudio) != nil)

        return (
            HTTPResponse(status: .ok, headerFields: [.contentType: "application/json"]),
            HTTPBody(
                #"{"text":"Amazing things happen.","words":[{"text":"Amazing","confidence":0.99}],"confidence":0.99,"llm_response":"Amazing things happen.","llm_error":null,"audio_duration_ms":1000,"session_id":"eb92c4ff-4bbb-429f-9b99-7279d7fe738f"}"#
            )
        )
    }
}
