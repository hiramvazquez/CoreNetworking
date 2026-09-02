import Testing
import Foundation
import os
@testable import CoreNetworking
import CoreNetworkingTestSupport

/// Colector thread-safe para closures de progreso @Sendable.
final class ProgressLog: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: [Double]())
    func append(_ value: Double) { state.withLock { $0.append(value) } }
    var values: [Double] { state.withLock { $0 } }
}

@Suite("Upload y download por el pipeline compartido")
struct TransferTests {
    private struct UploadResult: Decodable, Equatable { let id: Int }

    private struct PutUpload: BaseRequest {
        typealias Parameters = EmptyParameters
        let path = "/upload"
        let method: HTTPMethod = .PUT
    }

    private struct PostUpload: BaseRequest {
        typealias Parameters = EmptyParameters
        let path = "/upload"
        let method: HTTPMethod = .POST
    }

    private struct DownloadRequest: BaseRequest {
        typealias Parameters = EmptyParameters
        let path = "/file"
        let method: HTTPMethod = .GET
    }

    private func makeService(
        host: String,
        maxAttempts: Int = 1
    ) throws -> (APIService, URL) {
        let baseURL = try #require(URL(string: "https://\(host)"))
        let configuration = NetworkingConfiguration(baseURL: baseURL, protocolClasses: [MockURLProtocol.self])
        let policy = RetryPolicy(maxAttempts: maxAttempts, initialDelay: .milliseconds(10), maxDelay: .milliseconds(50))
        return (APIService(configuration: configuration, retryPolicy: policy), baseURL)
    }

    private func requestCount(host: String) -> Int {
        MockURLProtocol.recordedRequests.filter { $0.url?.host == host }.count
    }

    @Test("upload decodifica la respuesta")
    func uploadHappyPath() async throws {
        let host = "xfer-upload.test"
        let (service, baseURL) = try makeService(host: host)
        MockURLProtocol.register(MockNetworkExchange(
            method: .PUT,
            url: baseURL.appendingPathComponent("/upload"),
            response: MockResponse(statusCode: 200, data: Data(#"{"id":42}"#.utf8))
        ))

        let result: UploadResult = try await service.upload(
            request: PutUpload(),
            data: Data("payload".utf8)
        )
        #expect(result == UploadResult(id: 42))
        #expect(requestCount(host: host) == 1)
    }

    @Test("upload PUT (idempotente) pasa por el retry: 2 requests con maxAttempts=2")
    func uploadGoesThroughRetry() async throws {
        let host = "xfer-upload-retry.test"
        let (service, baseURL) = try makeService(host: host, maxAttempts: 2)
        MockURLProtocol.register(MockNetworkExchange(
            method: .PUT,
            url: baseURL.appendingPathComponent("/upload"),
            response: MockResponse(statusCode: 500)
        ))

        await #expect(throws: APIError.self) {
            let _: UploadResult = try await service.upload(request: PutUpload(), data: Data())
        }
        #expect(requestCount(host: host) == 2)
    }

    @Test("upload POST NO reintenta por defecto (mismo gate de idempotencia)")
    func uploadPostDoesNotRetry() async throws {
        let host = "xfer-upload-post.test"
        let (service, baseURL) = try makeService(host: host, maxAttempts: 3)
        MockURLProtocol.register(MockNetworkExchange(
            method: .POST,
            url: baseURL.appendingPathComponent("/upload"),
            response: MockResponse(statusCode: 500)
        ))

        await #expect(throws: APIError.self) {
            let _: UploadResult = try await service.upload(request: PostUpload(), data: Data())
        }
        #expect(requestCount(host: host) == 1)
    }

    @Test("download devuelve los bytes y el progreso llega monótono a 1.0")
    func downloadWithProgress() async throws {
        let host = "xfer-download.test"
        let (service, baseURL) = try makeService(host: host)
        let payload = Data(repeating: 0xAB, count: 256 * 1024)
        MockURLProtocol.register(MockNetworkExchange(
            url: baseURL.appendingPathComponent("/file"),
            response: MockResponse(
                statusCode: 200,
                data: payload,
                headers: ["Content-Length": String(payload.count)]
            )
        ))

        let log = ProgressLog()
        let data = try await service.download(request: DownloadRequest()) { log.append($0) }

        #expect(data == payload)
        let values = log.values
        #expect(values.last == 1.0, "el progreso debe terminar en 1.0")
        #expect(values == values.sorted(), "el progreso debe ser monótono")
        #expect(values.allSatisfy { $0 >= 0 && $0 <= 1 })
    }

    @Test("download sin Content-Length: sin fracciones intermedias pero termina en 1.0")
    func downloadWithoutContentLength() async throws {
        let host = "xfer-download-nolen.test"
        let (service, baseURL) = try makeService(host: host)
        let payload = Data("hola".utf8)
        MockURLProtocol.register(MockNetworkExchange(
            url: baseURL.appendingPathComponent("/file"),
            response: MockResponse(statusCode: 200, data: payload)
        ))

        let log = ProgressLog()
        let data = try await service.download(request: DownloadRequest()) { log.append($0) }
        #expect(data == payload)
        #expect(log.values == [1.0])
    }

    @Test("download non-2xx → error de status con el body del servidor")
    func downloadHTTPError() async throws {
        let host = "xfer-download-404.test"
        let (service, baseURL) = try makeService(host: host)
        MockURLProtocol.register(MockNetworkExchange(
            url: baseURL.appendingPathComponent("/file"),
            response: MockResponse(statusCode: 404)
        ))

        do {
            _ = try await service.download(request: DownloadRequest(), progress: nil)
            Issue.record("debía fallar con 404")
        } catch {
            #expect(error.code == .httpStatus)
            #expect(error.statusCode == 404)
        }
    }
}
