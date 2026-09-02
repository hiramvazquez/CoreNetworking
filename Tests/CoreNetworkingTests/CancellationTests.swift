import CoreNetworkingTestSupport
import Foundation
import Testing

@testable import CoreNetworking

/// Cancelación REAL: el mock entrega con latencia larga (5 s) y `stopLoading`
/// cancela la entrega pendiente. Si la cancelación del Task no cancelara la
/// transferencia, estos tests tardarían ≥5 s — se asserta el error Y el tiempo.
@Suite("Cancelación de execute / upload / download / backoff")
struct CancellationTests {
    private struct SlowRequest: BaseRequest {
        typealias Response = Payload
        let path = "/slow"
        let method: HTTPMethod = .get
    }

    private struct SlowPut: BaseRequest {
        typealias Response = Payload
        let path = "/slow"
        let method: HTTPMethod = .put
    }

    private struct Payload: Decodable, Sendable { let ok: Bool }

    private func makeService(
        host: String,
        policy: RetryPolicy = .noRetry
    ) throws -> (APIService, URL) {
        let baseURL = try #require(URL(string: "https://\(host)"))
        let configuration = NetworkingConfiguration(baseURL: baseURL, protocolClasses: [MockURLProtocol.self])
        return (APIService(configuration: configuration, retryPolicy: policy), baseURL)
    }

    private func registerSlowMock(url: URL, method: HTTPMethod = .get) {
        MockURLProtocol.register(
            MockNetworkExchange(
                method: method,
                url: url,
                response: MockResponse(statusCode: 200, data: Data(#"{"ok":true}"#.utf8)),
                latency: .seconds(5)
            )
        )
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
            let apiError = error as? APIError
            #expect(apiError?.code == .cancelled, "esperaba .cancelled, llegó \(error)")
        }
        #expect(elapsed < .seconds(2), "la cancelación no fue inmediata (\(elapsed)) — la transferencia siguió viva")
    }

    @Test("execute se cancela de verdad")
    func executeCancels() async throws {
        let (service, baseURL) = try makeService(host: "cancel-exec.test")
        registerSlowMock(url: baseURL.appendingPathComponent("/slow"))

        await expectCancelledFast {
            let _: Payload = try await service.execute(SlowRequest())
        }
    }

    @Test("upload se cancela de verdad")
    func uploadCancels() async throws {
        let (service, baseURL) = try makeService(host: "cancel-upload.test")
        registerSlowMock(url: baseURL.appendingPathComponent("/slow"), method: .put)

        await expectCancelledFast {
            let _: Payload = try await service.upload(request: SlowPut(), data: Data("x".utf8))
        }
    }

    @Test("data(for:) se cancela de verdad")
    func dataCancels() async throws {
        let (service, baseURL) = try makeService(host: "cancel-data.test")
        registerSlowMock(url: baseURL.appendingPathComponent("/slow"))

        await expectCancelledFast {
            _ = try await service.data(for: SlowRequest(), progress: nil)
        }
    }

    @Test("download(to:) se cancela de verdad, sin fichero huérfano en destination")
    func downloadToDiskCancels() async throws {
        let (service, baseURL) = try makeService(host: "cancel-download-disk.test")
        registerSlowMock(url: baseURL.appendingPathComponent("/slow"))
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("cn04-cancel-download-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: destination) }

        await expectCancelledFast {
            try await service.download(SlowRequest(), to: destination, progress: nil)
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test("cancelar durante el backoff del retry → .cancelled sin segundo request")
    func cancelDuringBackoff() async throws {
        let host = "cancel-backoff.test"
        let policy = RetryPolicy(maxAttempts: 2, initialDelay: .seconds(5), maxDelay: .seconds(5))
        let (service, baseURL) = try makeService(host: host, policy: policy)
        MockURLProtocol.register(
            MockNetworkExchange(
                url: baseURL.appendingPathComponent("/slow"),
                response: MockResponse(statusCode: 500)
            )
        )

        await expectCancelledFast {
            let _: Payload = try await service.execute(SlowRequest())
        }
        let count = MockURLProtocol.recordedRequests.filter { $0.url?.host == host }.count
        #expect(count == 1, "no debe haber segundo request tras cancelar en el backoff")
    }
}
