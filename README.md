# AssemblyAIDictationAPI

A Swift client for AssemblyAI's Dictation API. Upload short audio recordings and
receive both the verbatim transcript and cleaned-up text in one response. Audio
can be streamed in the request body without loading the entire recording into
memory.

| Endpoint | Swift method | Authentication |
| --- | --- | --- |
| `POST /v1/transcribe/live` | `client.transcribeDictation(body:)` | AssemblyAI API key |
| `GET /warm` | `client.warm()` | None |

The client and models are generated with `swift-openapi-generator`. Choose either
URLSession or AsyncHTTPClient; both expose the same operations and response types.

## Install

Use Swift 6 or newer for the examples below. The package declares support for
macOS 13+, iOS 16+, tvOS 16+, and watchOS 9+; transport availability also depends on
your platform.

Add the package in Xcode using
`https://github.com/atacan/AssemblyAIDictationAPI.git`, or add these dependencies to
your `Package.swift`. The example tracks `main`. Add OpenAPIRuntime directly when
constructing streaming bodies in your code.

```swift
// In Package(...):
dependencies: [
    .package(
        url: "https://github.com/atacan/AssemblyAIDictationAPI.git",
        branch: "main"
    ),
    .package(
        url: "https://github.com/apple/swift-openapi-runtime.git",
        from: "1.12.0"
    ),
],
targets: [
    .target(
        name: "YourApp",
        dependencies: [
            .product(name: "AssemblyAIDictationAPI", package: "AssemblyAIDictationAPI"),
            .product(name: "AssemblyAIDictationAPITypes", package: "AssemblyAIDictationAPI"),
            .product(name: "AssemblyAIDictationAPIURLSession", package: "AssemblyAIDictationAPI"),
            .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
        ]
    ),
]
```

| Product | Use it for |
| --- | --- |
| `AssemblyAIDictationAPI` | Shared `Client` and authentication |
| `AssemblyAIDictationAPITypes` | `Operations`, response models, `Servers`, and `APIProtocol` |
| `AssemblyAIDictationAPIURLSession` | `Client.urlSession(...)` |
| `AssemblyAIDictationAPIAsyncHTTPClient` | `Client.asyncHTTPClient(...)` |

## Create a client

Use `.apiKey(...)`: AssemblyAI expects the raw API key in the `Authorization`
header, with no `Bearer` prefix. These examples run in an async, throwing context,
such as an async function or a command-line app's `main()`.

```swift
import Foundation
import AssemblyAIDictationAPI
import AssemblyAIDictationAPITypes
import AssemblyAIDictationAPIURLSession
import OpenAPIRuntime

enum ExampleError: Error {
    case missingAPIKey
}

guard let apiKey = ProcessInfo.processInfo.environment["ASSEMBLYAI_API_KEY"],
      !apiKey.isEmpty else {
    throw ExampleError.missingAPIKey
}

let client = Client.urlSession(
    serverURL: try Servers.Server1.url(),
    authentication: .apiKey(apiKey)
)
```

For an app, supply the key from your own credential store instead of the process
environment. Dynamic credentials are supported through an async provider:
`authentication: .apiKey { try await credentialStore.apiKey() }`.

Choose the server that matches your data residency requirements:

| Server helper | Host |
| --- | --- |
| `Servers.Server1.url()` | `https://dictation.assemblyai.com` (global) |
| `Servers.Server2.url()` | `https://dictation.us.assemblyai.com` (US) |
| `Servers.Server3.url()` | `https://dictation.eu.assemblyai.com` (EU) |

For AsyncHTTPClient, replace the URLSession product in your target dependencies
with `AssemblyAIDictationAPIAsyncHTTPClient`, then use:

```swift
import AssemblyAIDictationAPIAsyncHTTPClient

let httpClient = Client.asyncHTTPClient(
    serverURL: try Servers.Server1.url(),
    authentication: .apiKey(apiKey)
)
```

All subsequent examples work with either factory.

## Stream a WAV file in multipart form

The request has two parts, **in this order**:

1. `config`: JSON settings. Always send this part, even when its value is `{}`.
2. `audio`: the audio bytes. The generated `.audio` case sends `audio/wav`.

The service rejects a missing config part or audio that arrives before config.
Let OpenAPIRuntime create the multipart boundary and headers for you.

### 1. Read the file in chunks

This is the same `FileHandle` async sequence used by the live tests. Add it to your
application once; it is a test helper, **not an extension shipped by the library**.
Each iteration reads up to 64 KiB from the handle's current position and closes the
handle at EOF.

```swift
import Foundation

extension FileHandle: @retroactive AsyncSequence {
    public typealias Element = ArraySlice<UInt8>

    public struct AsyncFileIterator: AsyncIteratorProtocol {
        private let fileHandle: FileHandle
        private let chunkSize: Int
        private var isClosed = false

        init(fileHandle: FileHandle, chunkSize: Int = 65_536) {
            self.fileHandle = fileHandle
            self.chunkSize = chunkSize
        }

        public mutating func next() async throws -> ArraySlice<UInt8>? {
            guard !isClosed else { return nil }
            guard let data = try fileHandle.read(upToCount: chunkSize),
                  !data.isEmpty else {
                isClosed = true
                try? fileHandle.close()
                return nil
            }
            return ArraySlice(data)
        }
    }

    public func makeAsyncIterator() -> AsyncFileIterator {
        AsyncFileIterator(fileHandle: self)
    }
}
```

Working source: [FileHandle+AsyncSequence.swift](Tests/AssemblyAIDictationAPILiveTests/FileHandle+AsyncSequence.swift).

### 2. Build the ordered multipart body

The outer `AsyncStream` yields the two parts in order. The inner `HTTPBody` reads
from the file only as the transport consumes it; finishing the outer stream does
not close the file or buffer its contents.

```swift
typealias DictationPart = Operations.transcribeDictation.Input.Body.multipartFormPayload
typealias DictationConfiguration = DictationPart.configPayload.bodyPayload

func dictationBody(
    file: FileHandle,
    filename: String,
    configuration: DictationConfiguration = .init()
) -> Operations.transcribeDictation.Input.Body {
    let parts = AsyncStream<DictationPart> { continuation in
        // Config must be first, including when using the default empty object.
        continuation.yield(.config(.init(payload: .init(body: configuration))))
        continuation.yield(
            .audio(
                .init(
                    payload: .init(
                        body: HTTPBody(file, length: .unknown, iterationBehavior: .single)
                    ),
                    filename: filename
                )
            )
        )
        continuation.finish()
    }
    return .multipartForm(MultipartBody(parts))
}
```

`.unknown` means the body length is not supplied up front. `.single` means the
stream can be consumed only once. To retry, open a new file handle and construct a
new request body.

Working source with default settings: [DictationRequest.swift](Tests/AssemblyAIDictationAPILiveTests/DictationRequest.swift).
The README helper also accepts a configuration argument.

### 3. Send the request and use the result

Keep the file open until the request finishes. The `defer` also closes it if the
request fails or the server responds before consuming all the audio.

```swift
func transcribeWAV(
    at url: URL,
    using client: Client,
    configuration: DictationConfiguration = .init()
) async throws -> Components.Schemas.DictationResponse {
    let file = try FileHandle(forReadingFrom: url)
    defer { try? file.close() }

    let output = try await client.transcribeDictation(
        body: dictationBody(
            file: file,
            filename: url.lastPathComponent,
            configuration: configuration
        )
    )
    return try output.ok.body.json
}

let result = try await transcribeWAV(
    at: URL(fileURLWithPath: "amazing-things.wav"),
    using: client
)

print(result.text)                         // Verbatim transcript.
print(result.llm_response ?? result.text)  // Cleaned-up text, with a fallback.
```

`output.ok` requires HTTP 200 and throws for another status. Network and response
conversion errors can also throw. For detailed HTTP handling, switch over the
generated output cases, such as `.badRequest`, `.unauthorized`, `.tooManyRequests`,
and `.undocumented`. See the complete switch and credential-safe error reporting in the
[live tests](Tests/AssemblyAIDictationAPILiveTests/AssemblyAIDictationAPILiveTests.swift).

A successful transcription can have `llm_response == nil` and a non-nil
`llm_error` when rewriting fails. Use `text` as the fallback; this is still an HTTP
200 response. Results also include words with confidence scores, overall
confidence, audio duration in milliseconds, and a session ID.

### Customize transcription and rewriting

Pass settings to the helper above. Omitting settings sends `{}` and uses the
service's default cleanup.

```swift
let configuration = DictationConfiguration(
    language_codes: [.en],
    keyterms_prompt: ["AssemblyAI", "Swift"],
    llm_instruction: "Rewrite this dictation as a concise email.",
    rewrite_mode: .smart
)

let customizedResult = try await transcribeWAV(
    at: URL(fileURLWithPath: "amazing-things.wav"),
    using: client,
    configuration: configuration
)
```

WAV files carry their sample rate and channel count in the header, so those config
fields are unnecessary for WAV. This endpoint accepts audio up to 120 seconds;
compressed formats such as MP3, M4A, and FLAC are not supported by this operation.

## Pre-warm when recording starts

When the user starts recording, call `/warm` so connection setup can overlap the
recording. Use the **same client and hostname** for transcription. Idle connections
can expire, so warming at application startup may be too early.

```swift
// When recording begins; start this task without delaying audio capture.
let warmTask = Task {
    // Warming is optional. Its failure should not prevent transcription.
    _ = try? await client.warm().ok.body.json
}

// Capture audio, then use `client` to send the transcription request.
// Keep the task handle if your application needs to cancel the warm request.
```

No API key is required for `/warm`, and the package omits authentication for this
operation even on a configured client. The JSON acknowledgement is
`{"warm":"toasty"}`. The Swift operation throws on network/decoding errors;
`.ok` also throws on an unexpected HTTP status.

See [AssemblyAI's pre-warming guidelines](https://www.assemblyai.com/docs/dictation/connection-pre-warming).

## Upload while recording: raw PCM

The file example uploads an existing WAV incrementally. For microphone capture,
provide an async sequence of audio chunks as they become available. Raw 16-bit PCM
is suitable for this: specify its sample rate and channel count in config.

The generated `.audio` case uses `audio/wav`. For PCM, use a raw `.undocumented`
part named `audio` to set `audio/pcm` explicitly. This is a supported runtime escape
hatch for multipart headers; the server still receives a regular audio part.

```swift
func pcmBody<Chunks: AsyncSequence & Sendable>(
    chunks: Chunks,
    sampleRate: Int,
    channels: Int
) -> Operations.transcribeDictation.Input.Body where Chunks.Element == ArraySlice<UInt8> {
    let parts = AsyncStream<DictationPart> { continuation in
        continuation.yield(
            .config(.init(payload: .init(body: .init(sample_rate: sampleRate, channels: channels))))
        )
        continuation.yield(
            .undocumented(
                .init(
                    name: "audio",
                    filename: "microphone.pcm",
                    headerFields: [.contentType: "audio/pcm"],
                    body: HTTPBody(chunks, length: .unknown, iterationBehavior: .single)
                )
            )
        )
        continuation.finish()
    }
    return .multipartForm(MultipartBody(parts))
}
```

Pass the returned body to `client.transcribeDictation(body:)`. The chunk producer
must yield bytes matching the declared format and finish when recording stops;
that ends the audio part and lets the server complete its response. Keep audio
flowing during the upload, since long pauses can cause a timeout. A microphone
stream is single-use too; retain a recording if you need to retry it. The package
does not provide microphone capture or convert audio formats.

See [AssemblyAI's upload-while-recording guide](https://www.assemblyai.com/docs/dictation/uploading-while-recording).

## Working examples and tests

| File | What to look at |
| --- | --- |
| [FileHandle+AsyncSequence.swift](Tests/AssemblyAIDictationAPILiveTests/FileHandle+AsyncSequence.swift) | 64 KiB reads and EOF handling |
| [DictationRequest.swift](Tests/AssemblyAIDictationAPILiveTests/DictationRequest.swift) | Config first, then streaming WAV audio |
| [AssemblyAIDictationAPILiveTests.swift](Tests/AssemblyAIDictationAPILiveTests/AssemblyAIDictationAPILiveTests.swift) | Both endpoints with both transport factories; response handling |
| [DictationStreamingTests.swift](Tests/AssemblyAIDictationAPILiveTests/DictationStreamingTests.swift) | Offline verification of chunking, multipart order, content type, and bytes |
| [WarmTests.swift](Tests/AssemblyAIDictationAPITests/WarmTests.swift) | Offline checks that warming never requests or sends credentials |

Run offline tests without making API calls:

```bash
ASSEMBLYAI_RUN_LIVE_TESTS=0 swift test
```

Live tests are disabled unless `ASSEMBLYAI_RUN_LIVE_TESTS=1`. To run them, export
`ASSEMBLYAI_API_KEY` and place `amazing-things.wav` in the repository root. You can
set `ASSEMBLYAI_AUDIO_FILE` to another WAV path. The variables must be exported in
the process environment; tests do not load `.env` automatically. Audio files are
ignored by Git and must be supplied locally.

```bash
# Both endpoints, with both transports:
ASSEMBLYAI_RUN_LIVE_TESTS=1 swift test --filter AssemblyAIDictationAPILiveTests

# Warm only; no API key or audio file needed:
ASSEMBLYAI_RUN_LIVE_TESTS=1 swift test --filter 'AssemblyAIDictationAPILiveTests/warm'

# Transcription only:
ASSEMBLYAI_RUN_LIVE_TESTS=1 swift test --filter 'AssemblyAIDictationAPILiveTests/transcribeDictation'
```

Each test runs once with URLSession and once with AsyncHTTPClient. The full live
suite makes **two warm requests and two transcription requests** to the global
host. Transcription requests may incur charges. Warm and transcription are
separate tests; the suite does not measure connection reuse or latency.

## Advanced client configuration

Both factories accept `configuration:` for OpenAPI runtime settings,
`transportConfiguration:` for the transport, and `middlewares:` for additional
middleware. Additional middleware runs before shared authentication on outgoing
requests.

The default transports use a shared URLSession/HTTP client. To inject your own,
pass `URLSessionTransport.Configuration(session:)` or
`AsyncHTTPClientTransport.Configuration(client:timeout:)`. Import the corresponding
upstream transport module and add its product as a direct dependency when using
these types. Your application owns injected clients and their lifecycle; do not
shut down the shared AsyncHTTPClient.

For another transport, use
`Client(serverURL:configuration:transport:authentication:middlewares:)` from the
core product. The core and Types targets do not depend on either transport;
SwiftPM may still resolve both transport packages declared by this package.

## Development and code generation

Edit [original_openapi.yaml](original_openapi.yaml) or add corrections and endpoints
to [openapi-overlay.yaml](openapi-overlay.yaml), then run:

```bash
make regenerate
```

The Makefile pins a bootstrapper revision that supports this package's shared
client and transport layout. Regeneration updates Swift types, operations, and
operation security metadata from the overlaid specification. Keep manual code
outside `GeneratedSources/` and do not edit
`Authentication/GeneratedSecurity/OperationSecurity.swift` directly. Existing
factory helpers, tests, and documentation are preserved.

Run `make help` for other development commands.

## Secret scanning

This repository includes Betterleaks and TruffleHog checks based on
[this secret-scanning guide](https://actondon.com/blog/secret-scanning-for-git-repo).
Activate the local hooks after initializing or cloning the Git repository:

```bash
brew install pre-commit
pre-commit install
```

Alternatively, install pre-commit with `uv tool install pre-commit` or
`pip install pre-commit`. Version 3.2 or newer is required. pre-commit downloads
and builds the pinned scanners, bootstrapping Go if needed; its first run requires
network access and can take a few minutes. The bootstrapper generates the
configuration; each developer installs the hooks locally.

On a commit, Betterleaks scans the staged diff and redacts its findings. TruffleHog
scans the staged files supplied by pre-commit, which temporarily hides unstaged
edits. Both work before the first commit. TruffleHog checks candidate credentials
against provider APIs and blocks only verified, active secrets. Scanner execution
errors also fail the checks. Run `pre-commit run` to check staged changes manually.

The GitHub workflow runs on pushes and pull requests to every branch. It fetches
full history to determine ranges, but scans incoming commits: push before-to-after
and pull request merge-base-to-head. New branches are compared with the default
branch when available; an initial repository push scans its imported history.
Unchanged older history is outside subsequent CI scans. Both scanners run
independently, so findings from either cause a failed workflow.

OpenAPI specifications, overlays, examples, and generated Swift files are scanned.
Keep real credentials in environment variables and leave only placeholders in
examples. If a finding is a false positive, review the exact location before
adding a targeted exception:

- Betterleaks supports a `betterleaks:allow` comment on the relevant line or its reported
  fingerprint in a root `.betterleaksignore` file.
- TruffleHog supports a `trufflehog:ignore` comment on the relevant line.

For formats that cannot contain comments, use a scanner-specific configuration or
path exception limited to the affected fixture. Avoid excluding whole source or
specification directories. Rotate and revoke any exposed real credential.

Regenerating the package preserves existing hook configuration, workflow, and
documentation files, including your edits.
