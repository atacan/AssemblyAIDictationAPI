// Generated from the final OpenAPI specification. Regenerated; do not edit.

internal enum OperationSecurity {
    enum Scheme: Sendable {
        case bearer
        case apiKey(header: String)
        case unsupported
    }

    static let schemes: [String: Scheme] = ["ApiKey": .apiKey(header: "authorization")]
    static let defaultRequirements: [[String]] = [["ApiKey"]]
    static let operations: [String: [[String]]] = ["transcribeDictation": [["ApiKey"]]]
}
