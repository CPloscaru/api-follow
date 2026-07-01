import Foundation

/// Thin seam over URLSession so adapters are unit-testable without live
/// network calls — tests inject a mock conformer instead of hitting real
/// provider APIs.
protocol HTTPClient: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: HTTPClient {}
