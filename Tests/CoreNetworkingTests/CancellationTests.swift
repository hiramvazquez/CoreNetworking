import Testing
import Foundation
@testable import CoreNetworking
import CoreNetworkingTestSupport

/// Cancelación REAL: el mock entrega con latencia larga (5 s) y `stopLoading`
/// cancela la entrega pendiente. Si la cancelación del Task no cancelara la
/// transferencia, estos tests tardarían ≥5 s — se asserta el error Y el tiempo.
@Suite("Cancelación de execute / upload / download / backoff")
struct CancellationTests {
    private struct SlowRequest: BaseRequest {
        typealias Parameters = EmptyParameters
        let path = "/slow"
        let method: HTTPMethod = .GET
    }

    private struct SlowPut: BaseRequest {
        typealias Parameters = EmptyParameters
        let path = "/slow"
        let method: HTTPMethod = .PUT
    }

    private struct Payload: Decodable { let ok: Bool }

    private func makeService(
        host: String,
        policy: RetryPolicy = .noRetry
    ) throws -> (APIService, URL) {
        let baseURL = try #require(URL(string: "https://\(host)"))
        let configuration = NetworkingConfiguration(baseURL: baseURL, protocolClasses: [MockURLProtocol.self])
        return (APIService(configuration: configuration, retryPolicy: policy), baseURL)
    }

    private func registerSlowMock(url: URL, method: HTTPMethod = .GET) {
        MockURLProtocol.register(MockNetworkExchange(
            method: method,
            url: url,
            response: MockResponse(statusCode: 200, data: Data(#"{"ok":true}"#.utf8)),
            latency: .seconds(5)
        ))
    }

    private func expectCancelledFast(
        _ body: @escaping @Sendable () async throws -> Void
    ) async {
        let start = ContinuousClock.now
        let task = Task {
            try await body()
        }
        try? await Task.sleep(for: .milliseconds(100))
        task.cancel()

        let outcome = await task.result
        let elapsed = start.duration(to: .now)

        switch outcome {
        case .success:
            Issue.record("la operación debía cancelarse, no completarse")
        case .failure(let error):
            #expect(error as? APIError == .cancelled, "esperaba .cancelled, llegó \(error)")
        }
        #expect(elapsed < .seconds(2), "la cancelación no fue inmediata (\(elapsed)) — la transferencia siguió viva")
    }

    @Test("execute se cancela de verdad")
    func executeCancels() async throws {
        let (service, baseURL) = try makeService(host: "cancel-exec.test")
        registerSlowMock(url: baseURL.appendingPathComponent("/slow"))

        await expectCancelledFast {
            let _: Payload = try await service.execute(request: SlowRequest())
        }
    }

    @Test("upload se cancela de verdad")
    func uploadCancels() async throws {
        let (service, baseURL) = try makeService(host: "cancel-upload.test")
        registerSlowMock(url: baseURL.appendingPathComponent("/slow"), method: .PUT)

        await expectCancelledFast {
            let _: Payload = try await service.upload(request: SlowPut(), data: Data("x".utf8))
        }
    }

    @Test("download se cancela de verdad")
    func downloadCancels() async throws {
        let (service, baseURL) = try makeService(host: "cancel-download.test")
        registerSlowMock(url: baseURL.appendingPathComponent("/slow"))

        await expectCancelledFast {
            _ = try await service.download(request: SlowRequest(), progress: nil)
        }
    }

    @Test("cancelar durante el backoff del retry → .cancelled sin segundo request")
    func cancelDuringBackoff() async throws {
        let host = "cancel-backoff.test"
        let policy = RetryPolicy(maxAttempts: 2, initialDelay: 5.0, maxDelay: 5.0)
        let (service, baseURL) = try makeService(host: host, policy: policy)
        MockURLProtocol.register(MockNetworkExchange(
            url: baseURL.appendingPathComponent("/slow"),
            response: MockResponse(statusCode: 500)
        ))

        await expectCancelledFast {
            let _: Payload = try await service.execute(request: SlowRequest())
        }
        let count = MockURLProtocol.recordedRequests.filter { $0.url?.host == host }.count
        #expect(count == 1, "no debe haber segundo request tras cancelar en el backoff")
    }
}
