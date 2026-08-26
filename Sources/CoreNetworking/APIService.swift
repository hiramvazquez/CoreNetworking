import Foundation

/// Production API service.
///
/// - One `URLSession` owned by the service, created in `init` with a dedicated
///   delegate object for SSL pinning (never `self`).
/// - Upload/download use the native async URLSession APIs: cancelling the task
///   cancels the transfer, and both go through the same pipeline as `execute`
///   (interceptors + retry + error mapping).
/// - No test/mock heuristics: mock `URLProtocol` classes are injected through
///   `NetworkingConfiguration.protocolClasses`.
/// - Every public method throws `APIError` (typed throws).
///
/// ## Example
/// ```swift
/// let service = APIService(
///     configuration: NetworkingConfiguration(baseURL: apiBaseURL),
///     retryPolicy: .conservative,
///     interceptors: [LoggingInterceptor()]
/// )
/// let games: [Game] = try await service.execute(request: GetGamesRequest())
/// ```
public final class APIService: APIServiceProtocol {
    private let configuration: NetworkingConfiguration
    private let session: URLSession
    private let retryPolicy: RetryPolicy
    private let interceptors: [any RequestInterceptor]

    /// Creates an API service.
    ///
    /// - Parameters:
    ///   - configuration: Immutable networking configuration (base URL, default
    ///     headers, optional mock protocol classes). Required — there is no
    ///     global fallback.
    ///   - retryPolicy: Retry configuration.
    ///   - interceptors: Request/Response interceptors (invoked in order).
    ///   - sslPinning: SSL pinning configuration (default: none — system TLS
    ///     validation only).
    public init(
        configuration: NetworkingConfiguration,
        retryPolicy: RetryPolicy = RetryPolicy(),
        interceptors: [any RequestInterceptor] = [],
        sslPinning: SSLPinningConfiguration? = nil
    ) {
        self.configuration = configuration
        self.retryPolicy = retryPolicy
        self.interceptors = interceptors

        let sessionConfiguration = URLSessionConfiguration.default
        if let protocolClasses = configuration.protocolClasses {
            sessionConfiguration.protocolClasses = protocolClasses
        }
        // Una sola sesión, creada aquí, con un objeto delegate propio (no self).
        // La sesión retiene a su delegate hasta que se invalida (ver deinit).
        self.session = URLSession(
            configuration: sessionConfiguration,
            delegate: PinningSessionDelegate(pinning: sslPinning),
            delegateQueue: nil
        )
    }

    deinit {
        // La URLSession retiene fuerte a su delegate; sin esto, sesión y delegate
        // se fugan al soltar el servicio.
        session.finishTasksAndInvalidate()
    }

    // MARK: - Execute

    public func execute<Request: BaseRequest, Response: Decodable>(
        request: Request
    ) async throws(APIError) -> Response {
        let (data, _) = try await performWithRetry(request) { [session] urlRequest in
            try await session.data(for: urlRequest)
        }
        return try Self.decode(Response.self, from: data)
    }

    // MARK: - Upload

    public func upload<Request: BaseRequest, Response: Decodable>(
        request: Request,
        data uploadData: Data,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws(APIError) -> Response {
        let (data, _) = try await performWithRetry(request) { [session] urlRequest in
            // API nativa: la cancelación del Task cancela la transferencia.
            // El body va SOLO como argumento de upload (no duplicado en httpBody).
            // Delegate por-task para el progreso; los auth challenges caen al
            // delegate de sesión (pinning) porque este no los implementa.
            let taskDelegate = progress.map { UploadProgressDelegate(onProgress: $0) }
            return try await session.upload(for: urlRequest, from: uploadData, delegate: taskDelegate)
        }
        return try Self.decode(Response.self, from: data)
    }

    // MARK: - Download

    public func download<Request: BaseRequest>(
        request: Request,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws(APIError) -> Data {
        // Se usa `session.bytes(for:)` y no `download(for:)` porque la API de este
        // método devuelve `Data` en memoria (no una URL de archivo): descargar a
        // disco para releerlo sería trabajo extra, y el stream nos da cancelación
        // nativa + progreso sin delegate.
        let (data, _) = try await performWithRetry(request) { [session] urlRequest in
            let (bytes, response) = try await session.bytes(for: urlRequest)

            let expectedLength = response.expectedContentLength
            var data = Data()
            if expectedLength > 0 {
                data.reserveCapacity(Int(expectedLength))
            }

            let progressGranularity = 64 * 1024
            for try await byte in bytes {
                data.append(byte)
                if expectedLength > 0, data.count % progressGranularity == 0 {
                    progress?(min(1.0, Double(data.count) / Double(expectedLength)))
                }
            }
            progress?(1.0)
            return (data, response)
        }
        return data
    }

    // MARK: - Shared Pipeline

    /// Runs one request through the shared pipeline with retry.
    ///
    /// Pipeline per attempt: build URLRequest → interceptors `willSend` →
    /// transport → interceptors `didReceive` → status validation.
    ///
    /// Retry rules:
    /// - `retryPolicy.maxAttempts` counts TOTAL requests (3 ⇒ 3 requests).
    /// - Only idempotent methods retry by default; POST/PATCH need the
    ///   request's `allowsNonIdempotentRetry` opt-in.
    /// - A server `Retry-After` takes precedence over the jittered backoff.
    private func performWithRetry<Request: BaseRequest>(
        _ request: Request,
        transport: (URLRequest) async throws -> (Data, URLResponse)
    ) async throws(APIError) -> (data: Data, response: HTTPURLResponse) {
        let methodAllowsRetry = request.method.isIdempotent || request.allowsNonIdempotentRetry
        var attemptsMade = 0
        while true {
            do {
                return try await performOnce(request, transport: transport)
            } catch {
                attemptsMade += 1
                let shouldRetry = attemptsMade < retryPolicy.maxAttempts &&
                                  methodAllowsRetry &&
                                  retryPolicy.shouldRetry(error, attemptsMade)
                guard shouldRetry else { throw error }

                let delay = error.retryAfterDelay ?? retryPolicy.jitteredDelay(for: attemptsMade - 1)
                NetLog.retry.debug(
                    "retry \(attemptsMade, privacy: .public)/\(self.retryPolicy.maxAttempts - 1, privacy: .public) en \(String(format: "%.2f", delay), privacy: .public)s — \(String(describing: error), privacy: .public)"
                )
                do {
                    try await Task.sleep(for: .seconds(delay))
                } catch {
                    throw APIError.cancelled
                }
            }
        }
    }

    /// Executes a single attempt through the pipeline.
    private func performOnce<Request: BaseRequest>(
        _ request: Request,
        transport: (URLRequest) async throws -> (Data, URLResponse)
    ) async throws(APIError) -> (data: Data, response: HTTPURLResponse) {
        var urlRequest = try buildURLRequest(from: request)

        for interceptor in interceptors {
            urlRequest = await interceptor.willSend(urlRequest)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport(urlRequest)
        } catch let urlError as URLError {
            let apiError = APIError.map(urlError)
            await notifyInterceptorsOfFailure(urlRequest, error: apiError)
            throw apiError
        } catch is CancellationError {
            let apiError = APIError.cancelled
            await notifyInterceptorsOfFailure(urlRequest, error: apiError)
            throw apiError
        } catch {
            let apiError = (error as? APIError) ?? .unknown
            await notifyInterceptorsOfFailure(urlRequest, error: apiError)
            throw apiError
        }

        for interceptor in interceptors {
            await interceptor.didReceive(response, data: data)
        }

        // didFail se notifica en TODOS los caminos de error del pipeline:
        // transporte (arriba), respuesta inválida y status non-2xx.
        guard let httpResponse = response as? HTTPURLResponse else {
            let apiError = APIError.invalidResponse
            await notifyInterceptorsOfFailure(urlRequest, error: apiError)
            throw apiError
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let apiError = APIError.map(data: data, response: httpResponse)
            await notifyInterceptorsOfFailure(urlRequest, error: apiError)
            throw apiError
        }

        return (data, httpResponse)
    }

    private static func decode<Response: Decodable>(
        _ type: Response.Type,
        from data: Data
    ) throws(APIError) -> Response {
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch let decodingError as DecodingError {
            throw APIError.decodingError(decodingError)
        } catch {
            throw APIError.unknown
        }
    }

    // MARK: - Helper Methods

    /// Builds a URLRequest from a BaseRequest with all features applied.
    private func buildURLRequest<Request: BaseRequest>(
        from request: Request
    ) throws(APIError) -> URLRequest {
        guard var urlComponents = URLComponents(
            url: configuration.baseURL.appendingPathComponent(request.path),
            resolvingAgainstBaseURL: true
        ) else {
            throw APIError.invalidURL
        }

        if let queryItems = request.queryItems, !queryItems.isEmpty {
            urlComponents.queryItems = queryItems
        }

        guard let url = urlComponents.url else {
            throw APIError.invalidURL
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.timeoutInterval = request.timeoutInterval

        // Merge headers: default headers first, request headers overwrite.
        for (key, value) in configuration.defaultHeaders {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }
        for (key, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }

        if let parameters = request.parameters {
            do {
                urlRequest.httpBody = try JSONEncoder().encode(parameters)
            } catch let encodingError as EncodingError {
                throw APIError.encodingError(encodingError)
            } catch {
                throw APIError.unknown
            }
        }

        return urlRequest
    }

    /// Notifies all interceptors of a request failure.
    private func notifyInterceptorsOfFailure(_ request: URLRequest, error: Error) async {
        for interceptor in interceptors {
            await interceptor.didFail(request, error: error)
        }
    }
}
