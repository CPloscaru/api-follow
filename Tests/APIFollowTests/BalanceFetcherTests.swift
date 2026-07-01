import Foundation
import Testing
@testable import APIFollow

@Suite("OpenRouterBalanceFetcher")
struct OpenRouterBalanceFetcherTests {
    @Test("computes remaining as total_credits minus total_usage")
    func computesRemaining() {
        let json = """
        {"data": {"total_credits": 100.5, "total_usage": 25.75}}
        """.data(using: .utf8)!

        let result = OpenRouterBalanceFetcher.parse(json)
        guard case .success(let balance) = result else {
            Issue.record("expected .success, got \(result)")
            return
        }
        #expect(balance == Decimal(string: "74.750000"))
    }

    @Test("401 response classifies as authError")
    func unauthorizedIsAuthError() async {
        let client = MockHTTPClient(statusCode: 401, body: Data())
        let fetcher = OpenRouterBalanceFetcher(httpClient: client)
        let result = await fetcher.fetchBalance(adminKey: "bad-key")
        guard case .authError = result else {
            Issue.record("expected .authError, got \(result)")
            return
        }
    }
}

@Suite("FalBalanceFetcher")
struct FalBalanceFetcherTests {
    @Test("parses current_balance from the credits object")
    func parsesCurrentBalance() {
        let json = """
        {"username": "my-team", "credits": {"current_balance": 24.5, "currency": "USD"}}
        """.data(using: .utf8)!

        let result = FalBalanceFetcher.parse(json)
        guard case .success(let balance) = result else {
            Issue.record("expected .success, got \(result)")
            return
        }
        #expect(balance == Decimal(string: "24.500000"))
    }

    @Test("missing credits object surfaces parseError, not a fabricated $0")
    func missingCreditsIsParseError() {
        let json = """
        {"username": "my-team"}
        """.data(using: .utf8)!

        let result = FalBalanceFetcher.parse(json)
        guard case .parseError = result else {
            Issue.record("expected .parseError, got \(result)")
            return
        }
    }

    @Test("unexpected currency surfaces parseError")
    func unexpectedCurrencyIsParseError() {
        let json = """
        {"username": "my-team", "credits": {"current_balance": 1.0, "currency": "EUR"}}
        """.data(using: .utf8)!

        let result = FalBalanceFetcher.parse(json)
        guard case .parseError = result else {
            Issue.record("expected .parseError, got \(result)")
            return
        }
    }

    @Test("401 response classifies as authError")
    func unauthorizedIsAuthError() async {
        let client = MockHTTPClient(statusCode: 401, body: Data())
        let fetcher = FalBalanceFetcher(httpClient: client)
        let result = await fetcher.fetchBalance(adminKey: "bad-key")
        guard case .authError = result else {
            Issue.record("expected .authError, got \(result)")
            return
        }
    }
}
