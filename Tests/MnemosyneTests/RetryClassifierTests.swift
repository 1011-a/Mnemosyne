import XCTest
@testable import Mnemosyne

/// Guards ToolAgent.isTransientLLMError — the classifier that decides which LLM/transport failures
/// the RetryingClient should retry (transient) vs fail fast (permanent).
final class RetryClassifierTests: XCTestCase {

    func testRetriesRateLimitAnd5xx() {
        XCTAssertTrue(ToolAgent.isTransientLLMError(ClientError.http(429, "rate limited")))
        XCTAssertTrue(ToolAgent.isTransientLLMError(ClientError.http(500, "oops")))
        XCTAssertTrue(ToolAgent.isTransientLLMError(ClientError.http(503, "unavailable")))
    }

    func testDoesNotRetryClientErrorsOrConfig() {
        XCTAssertFalse(ToolAgent.isTransientLLMError(ClientError.http(400, "bad request")))
        XCTAssertFalse(ToolAgent.isTransientLLMError(ClientError.http(401, "unauthorized")))
        XCTAssertFalse(ToolAgent.isTransientLLMError(ClientError.missingDeepSeekKey))
        XCTAssertFalse(ToolAgent.isTransientLLMError(ClientError.decode("nope")))
    }

    func testRetriesNetworkTimeouts() {
        XCTAssertTrue(ToolAgent.isTransientLLMError(URLError(.timedOut)))
        XCTAssertTrue(ToolAgent.isTransientLLMError(URLError(.networkConnectionLost)))
        XCTAssertFalse(ToolAgent.isTransientLLMError(URLError(.badURL)))
    }
}
