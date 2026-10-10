import Foundation

/// Selftests only: receives a fully serialized model request and aborts it
/// BEFORE any transport, credential load or retry sees it. Lets route tests
/// build real bodies for production hosts (api.openai.com, chatgpt.com,
/// openrouter.ai) without a network send. nil in production (a no-op check
/// after the body is final; the body itself is never touched).
enum WireInterceptForTesting {
    struct Intercepted: Error {}
    nonisolated(unsafe) static var handler: ((_ protocolName: String, _ body: Data) -> Void)?

    static func check(_ protocolName: String, _ body: Data?) throws {
        guard let handler else { return }
        handler(protocolName, body ?? Data())
        throw Intercepted()
    }
}
