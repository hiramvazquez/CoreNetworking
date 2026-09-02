import Testing
import Foundation
import os
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
@testable import CoreNetworking
import CoreNetworkingTestSupport

/// Colector thread-safe para closures de progreso @Sendable.
final class ProgressLog: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: [Double]())
    func append(_ value: Double) { state.withLock { $0.append(value) } }
    var values: [Double] { state.withLock { $0 } }
}

/// Servidor HTTP/1.1 mínimo en loopback (socket POSIX real), para probar
/// `download(to:)` a través del `URLSessionTransport` DE VERDAD.
///
/// `MockURLProtocol` no sirve para esto — verificado empíricamente: una
/// download task servida por un `URLProtocol` a medida nunca dispara
/// `URLSessionDownloadDelegate.urlSession(_:downloadTask:didFinishDownloadingTo:)`
/// (el mecanismo de "escribe en un temporal y avisa" es interno al stack de
/// transporte real, un `URLProtocol` lo puentea). Sin ese callback,
/// `TaskDelegate` nunca mueve nada a `destination`. Un socket real en
/// 127.0.0.1 sí atraviesa el camino de descarga completo.
final class LoopbackHTTPServer: @unchecked Sendable {
    let port: UInt16
    private let listenSocket: Int32

    init(statusCode: Int = 200, headers: [String: String] = [:], body: Data) throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0   // el sistema asigna un puerto libre

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            close(fd)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        guard listen(fd, 1) == 0 else {
            close(fd)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }

        var assigned = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &assigned) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                getsockname(fd, sockaddrPointer, &length)
            }
        }

        self.listenSocket = fd
        self.port = UInt16(bigEndian: assigned.sin_port)

        var headerText = "HTTP/1.1 \(statusCode) \(HTTPURLResponse.localizedString(forStatusCode: statusCode))\r\n"
        headerText += "Content-Length: \(body.count)\r\n"
        headerText += "Connection: close\r\n"
        for (key, value) in headers {
            headerText += "\(key): \(value)\r\n"
        }
        headerText += "\r\n"
        let payload = Data(headerText.utf8) + body

        let socketFD = listenSocket
        Thread.detachNewThread {
            let clientFD = accept(socketFD, nil, nil)
            guard clientFD >= 0 else { return }
            var requestBuffer = [UInt8](repeating: 0, count: 4096)
            _ = recv(clientFD, &requestBuffer, requestBuffer.count, 0)
            payload.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let sent = write(clientFD, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                    guard sent > 0 else { break }
                    offset += sent
                }
            }
            shutdown(clientFD, Int32(SHUT_WR))
            close(clientFD)
            close(socketFD)
        }
    }

    var url: URL { URL(string: "http://127.0.0.1:\(port)/file")! }
}

@Suite("Upload / data / download por el pipeline compartido")
struct TransferTests {
    private struct UploadResult: Decodable, Sendable, Equatable { let id: Int }

    private struct PutUpload: BaseRequest {
        typealias Response = UploadResult
        let path = "/upload"
        let method: HTTPMethod = .put
    }

    private struct PostUpload: BaseRequest {
        typealias Response = UploadResult
        let path = "/upload"
        let method: HTTPMethod = .post
    }

    private struct FileRequest: BaseRequest {
        let path = "/file"
        let method: HTTPMethod = .get
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

    // MARK: - Upload

    @Test("upload decodifica la respuesta")
    func uploadHappyPath() async throws {
        let host = "xfer-upload.test"
        let (service, baseURL) = try makeService(host: host)
        MockURLProtocol.register(MockNetworkExchange(
            method: .put,
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
            method: .put,
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
            method: .post,
            url: baseURL.appendingPathComponent("/upload"),
            response: MockResponse(statusCode: 500)
        ))

        await #expect(throws: APIError.self) {
            let _: UploadResult = try await service.upload(request: PostUpload(), data: Data())
        }
        #expect(requestCount(host: host) == 1)
    }

    // MARK: - data(for:) — en memoria

    @Test("data(for:) devuelve los bytes y el progreso llega monótono a 1.0")
    func dataWithProgress() async throws {
        let host = "xfer-data.test"
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
        let data = try await service.data(for: FileRequest()) { log.append($0) }

        #expect(data == payload)
        let values = log.values
        #expect(values.last == 1.0, "el progreso debe terminar en 1.0")
        #expect(values == values.sorted(), "el progreso debe ser monótono")
        #expect(values.allSatisfy { $0 >= 0 && $0 <= 1 })
    }

    @Test("data(for:) sin Content-Length: sin fracciones intermedias pero termina en 1.0")
    func dataWithoutContentLength() async throws {
        let host = "xfer-data-nolen.test"
        let (service, baseURL) = try makeService(host: host)
        let payload = Data("hola".utf8)
        MockURLProtocol.register(MockNetworkExchange(
            url: baseURL.appendingPathComponent("/file"),
            response: MockResponse(statusCode: 200, data: payload)
        ))

        let log = ProgressLog()
        let data = try await service.data(for: FileRequest()) { log.append($0) }
        #expect(data == payload)
        #expect(log.values == [1.0])
    }

    @Test("data(for:) non-2xx → error de status con el body del servidor")
    func dataHTTPError() async throws {
        let host = "xfer-data-404.test"
        let (service, baseURL) = try makeService(host: host)
        MockURLProtocol.register(MockNetworkExchange(
            url: baseURL.appendingPathComponent("/file"),
            response: MockResponse(statusCode: 404)
        ))

        do {
            _ = try await service.data(for: FileRequest(), progress: nil)
            Issue.record("debía fallar con 404")
        } catch {
            #expect(error.code == .httpStatus)
            #expect(error.statusCode == 404)
        }
    }

    /// CN-07: `download` iteraba `AsyncBytes` byte a byte (una llamada async
    /// POR BYTE) — órdenes de magnitud más lento que recibir chunks. Este
    /// test no mide un límite estricto (sería flaky en CI), pero 5 MB
    /// byte-a-byte tarda segundos incluso en el simulador más rápido; 0,2 s
    /// es generoso para "recibe por chunks" y estrecho para "recibe por byte".
    @Test("data(for:) de 5 MB no es lenta (regresión: nada de 'for try await byte')")
    func dataLargePayloadIsFast() async throws {
        let host = "xfer-data-5mb.test"
        let (service, baseURL) = try makeService(host: host)
        let payload = Data(repeating: 0xCD, count: 5 * 1024 * 1024)
        MockURLProtocol.register(MockNetworkExchange(
            url: baseURL.appendingPathComponent("/file"),
            response: MockResponse(
                statusCode: 200,
                data: payload,
                headers: ["Content-Length": String(payload.count)]
            )
        ))

        let start = ContinuousClock.now
        let data = try await service.data(for: FileRequest(), progress: nil)
        let elapsed = start.duration(to: .now)

        #expect(data.count == payload.count)
        #expect(elapsed < .milliseconds(200), "data(for:) de 5 MB tardó \(elapsed) — ¿volvió el bucle byte a byte?")
    }

    // MARK: - download(to:) — a disco

    @Test("download(to:) deja el fichero en destination y no queda temporal huérfano")
    func downloadToDiskWritesDestination() async throws {
        let payload = Data(repeating: 0xEF, count: 128 * 1024)
        let server = try LoopbackHTTPServer(
            headers: ["Content-Length": String(payload.count)],
            body: payload
        )
        let configuration = NetworkingConfiguration(baseURL: URL(string: "http://127.0.0.1:\(server.port)")!)
        let service = APIService(configuration: configuration, retryPolicy: .noRetry)

        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cn04-download-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }
        let destination = tempDirectory.appendingPathComponent("payload.bin")

        let filesBefore = try FileManager.default.contentsOfDirectory(atPath: tempDirectory.path)
        #expect(filesBefore.isEmpty)

        let log = ProgressLog()
        try await service.download(FileRequest(), to: destination) { log.append($0) }

        #expect(FileManager.default.fileExists(atPath: destination.path))
        let written = try Data(contentsOf: destination)
        #expect(written == payload)

        let filesAfter = try FileManager.default.contentsOfDirectory(atPath: tempDirectory.path)
        #expect(filesAfter == ["payload.bin"], "no debe quedar ningún fichero temporal huérfano junto al destino")

        let values = log.values
        #expect(values.last == 1.0)
        #expect(values == values.sorted())
    }

    @Test("download(to:) non-2xx → error de status, sin fichero en destination")
    func downloadToDiskHTTPError() async throws {
        let host = "xfer-download-disk-404.test"
        let (service, baseURL) = try makeService(host: host)
        MockURLProtocol.register(MockNetworkExchange(
            url: baseURL.appendingPathComponent("/file"),
            response: MockResponse(statusCode: 404, data: Data("not found".utf8))
        ))

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("cn04-download-404-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: destination) }

        do {
            try await service.download(FileRequest(), to: destination, progress: nil)
            Issue.record("debía fallar con 404")
        } catch {
            #expect(error.code == .httpStatus)
            #expect(error.statusCode == 404)
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path), "un download fallido no debe dejar nada en destination")
    }

    @Test("download(to:) sustituye un fichero existente en destination")
    func downloadToDiskReplacesExistingFile() async throws {
        let payload = Data(repeating: 0x11, count: 4096)
        let server = try LoopbackHTTPServer(body: payload)
        let configuration = NetworkingConfiguration(baseURL: URL(string: "http://127.0.0.1:\(server.port)")!)
        let service = APIService(configuration: configuration, retryPolicy: .noRetry)

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("cn04-download-replace-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: destination) }
        try Data("contenido viejo".utf8).write(to: destination)

        try await service.download(FileRequest(), to: destination, progress: nil)

        let written = try Data(contentsOf: destination)
        #expect(written == payload)
    }
}
