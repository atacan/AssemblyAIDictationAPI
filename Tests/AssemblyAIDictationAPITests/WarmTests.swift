import AssemblyAIDictationAPI
import Foundation
import HTTPTypes
import OpenAPIRuntime
import Testing

struct WarmTests {
    @Test(arguments: [false, true])
    func warmDoesNotRequireOrSendCredentials(configuredCredentials: Bool) async throws {
        let serverURL = try #require(URL(string: "https://example.invalid"))
        let client = Client(
            serverURL: serverURL,
            transport: WarmTransport(),
            authentication: configuredCredentials ? .apiKey { throw UnexpectedCredentialAccess() } : .none
        )

        let output = try await client.warm()
        let response = try output.ok.body.json
        #expect(response.warm == "toasty")
    }

    @Test func warmPreservesUnexpectedHTTPStatus() async throws {
        let serverURL = try #require(URL(string: "https://example.invalid"))
        let client = Client(serverURL: serverURL, transport: WarmTransport(status: .serviceUnavailable), authentication: .none)

        switch try await client.warm() {
        case .undocumented(let status, _):
            #expect(status == 503)
        case .ok:
            Issue.record("Expected the unavailable server to return HTTP 503.")
        }
    }
}

private struct UnexpectedCredentialAccess: Error {}

private struct WarmTransport: ClientTransport {
    var status: HTTPResponse.Status = .ok

    func send(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String
    ) async throws -> (HTTPResponse, HTTPBody?) {
        #expect(operationID == "warm")
        #expect(request.method == .get)
        #expect(request.path == "/warm")
        #expect(request.headerFields[.authorization] == nil)
        #expect(body == nil)

        return (
            HTTPResponse(status: status, headerFields: [.contentType: "application/json"]),
            HTTPBody(#"{"warm":"toasty"}"#)
        )
    }
}
