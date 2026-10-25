import AssemblyAIDictationAPITypes
import Foundation
import OpenAPIRuntime

func dictationBody(file: FileHandle, filename: String) -> Operations.transcribeDictation.Input.Body {
    typealias Part = Operations.transcribeDictation.Input.Body.multipartFormPayload

    // Order matters: the service needs config before it can consume any audio.
    let parts = AsyncStream<Part> { continuation in
        continuation.yield(.config(.init(payload: .init(body: .init()))))
        continuation.yield(
            .audio(
                .init(
                    payload: .init(body: HTTPBody(file, length: .unknown, iterationBehavior: .single)),
                    filename: filename
                )
            )
        )
        continuation.finish()
    }
    return .multipartForm(MultipartBody(parts))
}

func recordingDictationBody(file: FileHandle, filename: String) -> Operations.transcribeDictationRecording.Input.Body {
    typealias Part = Operations.transcribeDictationRecording.Input.Body.multipartFormPayload

    // Recorded audio supports an audio-only request with the default cleanup.
    let parts = AsyncStream<Part> { continuation in
        continuation.yield(
            .audio(
                .init(
                    payload: .init(body: HTTPBody(file, length: .unknown, iterationBehavior: .single)),
                    filename: filename
                )
            )
        )
        continuation.finish()
    }
    return .multipartForm(MultipartBody(parts))
}
