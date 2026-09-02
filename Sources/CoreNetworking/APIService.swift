import Foundation

/// Production API service.
///
/// - No `URLSession` of its own: every request goes through an injected
///   `HTTPTransport` (`URLSessionTransport` by default via the convenience
///   `init`, `InMemoryTransport` in unit tests). The transport — not this
///   type — owns the session and its lifetime.
/// - Upload/download go through the same transport and pipeline as `execute`
///   (interceptors + retry + error mapping); cancelling the task cancels the
///   transfer.
/// - Retry sleeps through an injected `Clock<Duration>` (`ContinuousClock` by
///   default, `ManualClock` in tests) — no real wall-clock waits in tests.
/// - Every public method throws `APIError` (typed throws).
///
/// ## Example
/// ```swift
/// let service = APIService(
///     configuration: NetworkingConfiguration(baseURL: apiBaseURL),
///     retryPolicy: .conservative,
///     interceptors: [LoggingInterceptor()]
/// )
/// let games: [Game] = try await service.execute(GetGamesRequest())
/// ```
public final class APIService: APIServiceProtocol {
    private let configuration: NetworkingConfiguration
    private let transport: any HTTPTransport
    private let retryPolicy: RetryPolicy
    private let interceptors: [any RequestInterceptor]
    private let retriers: [any RequestRetrier]
    private let clock: any Clock<Duration>

    /// Creates an API service with an explicit transport.
    ///
    /// This is the designated init: `transport` has no default because the
    /// choice belongs to the consumer — production code picks
    /// `URLSessionTransport` (or use the `sslPinning:` convenience `init`
    /// below), tests pick `InMemoryTransport`.
    ///
    /// - Parameters:
    ///   - configuration: Immutable networking configuration (base URL,
    ///     default headers, decoder factory). Required — there is no global
    ///     fallback.
    ///   - transport: What actually sends the request. No default.
    ///   - retryPolicy: Retry configuration.
    ///   - interceptors: Request/Response interceptors (invoked in order).
    ///   - retriers: Consulted, in order, BEFORE `retryPolicy` on every
    ///     failed attempt — the first that doesn't answer `.doNotRetry`
    ///     decides (see `RequestRetrier`). Default: `[]`, i.e. `retryPolicy`
    ///     alone decides, same as before `RequestRetrier` existed.
    ///   - clock: Clock used to sleep between retries (default:
    ///     `ContinuousClock()`). Inject a `ManualClock` in tests to advance
    ///     backoff without waiting on the wall clock.
    public init(
        configuration: NetworkingConfiguration,
        transport: any HTTPTransport,
        retryPolicy: RetryPolicy = RetryPolicy(),
        interceptors: [any RequestInterceptor] = [],
        retriers: [any RequestRetrier] = [],
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.configuration = configuration
        self.transport = transport
        self.retryPolicy = retryPolicy
        self.interceptors = interceptors
        self.retriers = retriers
        self.clock = clock
    }

    /// Convenience: builds a `URLSessionTransport` from `configuration` and
    /// `sslPinning` — same call shape as before `HTTPTransport` existed.
    ///
    /// - Parameter sslPinning: SSL pinning configuration (default: none —
    ///   system TLS validation only).
    public convenience init(
        configuration: NetworkingConfiguration,
        retryPolicy: RetryPolicy = RetryPolicy(),
        interceptors: [any RequestInterceptor] = [],
        retriers: [any RequestRetrier] = [],
        sslPinning: SSLPinningConfiguration? = nil
    ) {
        // La fábrica es de `configuration` (`NetworkingConfiguration.sessionConfiguration`),
        // no `.default` a pelo: es lo que hace que `sessionConfiguration` llegue
        // a la `URLSession` real que construye `URLSessionTransport`.
        let sessionConfiguration = configuration.sessionConfiguration()
        if let protocolClasses = configuration.protocolClasses {
            sessionConfiguration.protocolClasses = protocolClasses
        }
        self.init(
            configuration: configuration,
            transport: URLSessionTransport(configuration: sessionConfiguration, pinning: sslPinning),
            retryPolicy: retryPolicy,
            interceptors: interceptors,
            retriers: retriers
        )
    }

    // MARK: - Execute

    public func execute<Request: BaseRequest>(
        _ request: Request
    ) async throws(APIError) -> Request.Response {
        let (data, response, summary) = try await performWithRetry(request) { [transport] urlRequest in
            try await transport.send(urlRequest, progress: nil)
        }
        return try Self.decode(Request.Response.self, from: data, request: summary, response: response, using: configuration.makeDecoder)
    }

    public func execute<Request: BaseRequest, Value: Decodable & Sendable>(
        _ request: Request,
        as type: Value.Type
    ) async throws(APIError) -> Value {
        let (data, response, summary) = try await performWithRetry(request) { [transport] urlRequest in
            try await transport.send(urlRequest, progress: nil)
        }
        return try Self.decode(Value.self, from: data, request: summary, response: response, using: configuration.makeDecoder)
    }

    // MARK: - Upload

    public func upload<Request: BaseRequest, Response: Decodable>(
        request: Request,
        data uploadData: Data,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws(APIError) -> Response {
        let (data, response, summary) = try await performWithRetry(request) { [transport] urlRequest in
            // El body va en `httpBody`, no en un parámetro de upload aparte
            // (CN-04 lo cambia por `upload(for:from:)` con delegate). El
            // progreso, si lo hay, es el único lado (upload) de `TransferProgress`.
            var urlRequest = urlRequest
            urlRequest.httpBody = uploadData
            let transferProgress = progress.map { TransferProgress(onUpload: $0) }
            return try await transport.send(urlRequest, progress: transferProgress)
        }
        return try Self.decode(Response.self, from: data, request: summary, response: response, using: configuration.makeDecoder)
    }

    // MARK: - Download

    public func download<Request: BaseRequest>(
        request: Request,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws(APIError) -> Data {
        // Sigue en memoria (no a disco) hasta CN-04: el transporte devuelve
        // `Data` completa, con progreso reportado por el lado `onDownload` de
        // `TransferProgress` mientras llega.
        let (data, _, _) = try await performWithRetry(request) { [transport] urlRequest in
            let transferProgress = progress.map { TransferProgress(onDownload: $0) }
            return try await transport.send(urlRequest, progress: transferProgress)
        }
        return data
    }

    // MARK: - Shared Pipeline

    /// Wraps a failed attempt together with the `RequestContext` it failed
    /// under — `performWithRetry` needs the context to consult `retriers`;
    /// `performOnce` is the only thing that has it (it's created after
    /// `buildURLRequest`, which can fail with a bare `APIError` and no
    /// context at all — see the `catch let apiError as APIError` branch
    /// below).
    private struct AttemptFailure: Error {
        let error: APIError
        let context: RequestContext
    }

    /// Runs one request through the shared pipeline with retry.
    ///
    /// Pipeline per attempt: build URLRequest → interceptors `willSend` →
    /// transport → interceptors `didReceive` → status validation → on error:
    /// `didFail` → `retriers` (first that doesn't answer `.doNotRetry`
    /// decides) → if none did, `retryPolicy`.
    ///
    /// Retry rules:
    /// - `retryPolicy.maxAttempts` counts TOTAL requests (3 ⇒ 3 requests),
    ///   and bounds BOTH the `retriers` and the `retryPolicy` path.
    /// - A `retriers` decision does not care about HTTP method idempotency
    ///   (a 401/refresh retry never reached the server the first time,
    ///   there is nothing to duplicate); the `retryPolicy` fallback still
    ///   does — only idempotent methods retry by default, POST/PATCH need
    ///   the request's `allowsNonIdempotentRetry` opt-in.
    /// - `RetryDecision.retryAfter` overrides both a server `Retry-After`
    ///   and the jittered backoff; `.retry` (from a retrier OR the default
    ///   `retryPolicy` path) still prefers `Retry-After` over the backoff.
    private func performWithRetry<Request: BaseRequest>(
        _ request: Request,
        transport: (URLRequest) async throws -> (Data, URLResponse)
    ) async throws(APIError) -> (data: Data, response: HTTPURLResponse, request: APIError.RequestSummary) {
        let methodAllowsRetry = request.method.isIdempotent || request.allowsNonIdempotentRetry
        var attemptsMade = 0
        while true {
            attemptsMade += 1
            do {
                return try await performOnce(request, attempt: attemptsMade, transport: transport)
            } catch let failure as AttemptFailure {
                let error = failure.error
                guard attemptsMade < retryPolicy.maxAttempts else { throw error }

                let delay: Duration
                if let decision = await firstRetrierDecision(for: error, context: failure.context) {
                    switch decision {
                    case .retryAfter(let explicit):
                        delay = explicit
                    case .retry:
                        delay = error.retryAfter ?? retryPolicy.jitteredDelay(for: attemptsMade - 1)
                    case .doNotRetry:
                        // `firstRetrierDecision` never returns `.doNotRetry`.
                        throw error
                    }
                } else {
                    guard methodAllowsRetry, retryPolicy.shouldRetry(error, attemptsMade) else { throw error }
                    delay = error.retryAfter ?? retryPolicy.jitteredDelay(for: attemptsMade - 1)
                }

                NetLog.retry.debug(
                    "retry \(attemptsMade, privacy: .public)/\(self.retryPolicy.maxAttempts - 1, privacy: .public) en \(String(describing: delay), privacy: .public) — \(String(describing: error), privacy: .public)"
                )
                try await sleepOrThrowCancelled(delay, requestSummary: error.request)
            } catch let apiError as APIError {
                // `buildURLRequest` falló antes de crear un `RequestContext`:
                // ningún interceptor ni retrier llegó a verlo (no hubo
                // `willSend`), así que solo `retryPolicy` decide.
                guard attemptsMade < retryPolicy.maxAttempts,
                      methodAllowsRetry,
                      retryPolicy.shouldRetry(apiError, attemptsMade) else { throw apiError }

                let delay = apiError.retryAfter ?? retryPolicy.jitteredDelay(for: attemptsMade - 1)
                NetLog.retry.debug(
                    "retry \(attemptsMade, privacy: .public)/\(self.retryPolicy.maxAttempts - 1, privacy: .public) en \(String(describing: delay), privacy: .public) — \(String(describing: apiError), privacy: .public)"
                )
                try await sleepOrThrowCancelled(delay, requestSummary: apiError.request)
            } catch {
                // Ni `AttemptFailure` ni `APIError`: no debería ocurrir (todo
                // lo que `performOnce` lanza es uno de los dos), pero el
                // error original nunca se pierde si pasa.
                throw APIError(code: .unexpected, underlying: error)
            }
        }
    }

    /// Sleeps `delay` on `clock`, mapping cancellation to `APIError(.cancelled)`.
    private func sleepOrThrowCancelled(
        _ delay: Duration,
        requestSummary: APIError.RequestSummary?
    ) async throws(APIError) {
        do {
            try await clock.sleep(for: delay)
        } catch let cancellation {
            throw APIError(code: .cancelled, request: requestSummary, underlying: cancellation)
        }
    }

    /// Consults `retriers` in order; the first decision that isn't
    /// `.doNotRetry` wins and no further retrier (nor `retryPolicy`) is
    /// asked. `nil` means every retrier answered `.doNotRetry` (or there are
    /// none) — the caller falls back to `retryPolicy`.
    private func firstRetrierDecision(for error: APIError, context: RequestContext) async -> RetryDecision? {
        for retrier in retriers {
            let decision = await retrier.retry(error, context: context)
            if decision != .doNotRetry {
                return decision
            }
        }
        return nil
    }

    /// Executes a single attempt through the pipeline. Throws `AttemptFailure`
    /// (error + the `RequestContext` it failed under) for anything that
    /// happens once `buildURLRequest` succeeded, or a bare `APIError` if
    /// `buildURLRequest` itself failed (no context exists yet).
    private func performOnce<Request: BaseRequest>(
        _ request: Request,
        attempt: Int,
        transport: (URLRequest) async throws -> (Data, URLResponse)
    ) async throws -> (data: Data, response: HTTPURLResponse, request: APIError.RequestSummary) {
        var urlRequest = try buildURLRequest(from: request)
        let context = RequestContext(request: urlRequest, attempt: attempt)

        for interceptor in interceptors {
            do {
                urlRequest = try await interceptor.willSend(urlRequest, context: context)
            } catch {
                // `error` ya es `APIError` (typed throws de `willSend`): lo
                // que el interceptor lanzó viaja intacto en `underlying`.
                let apiError = APIError(code: .interceptor, request: APIError.RequestSummary(urlRequest), underlying: error)
                await notifyInterceptorsOfFailure(apiError, context: context)
                throw AttemptFailure(error: apiError, context: context)
            }
        }

        let summary = APIError.RequestSummary(urlRequest)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport(urlRequest)
        } catch let urlError as URLError {
            // `.cancelled` es la cancelación del llamador. El pinning que
            // rechaza un certificado también llega como `.cancelled` desde
            // Foundation: distinguirlo (→ `.untrustedServer`) exige el delegate
            // por tarea de CN-04; el código ya existe para que nada lo confunda.
            let code: APIError.Code = urlError.code == .cancelled ? .cancelled : .transport
            let apiError = APIError(code: code, request: summary, underlying: urlError)
            await notifyInterceptorsOfFailure(apiError, context: context)
            throw AttemptFailure(error: apiError, context: context)
        } catch let cancellation as CancellationError {
            let apiError = APIError(code: .cancelled, request: summary, underlying: cancellation)
            await notifyInterceptorsOfFailure(apiError, context: context)
            throw AttemptFailure(error: apiError, context: context)
        } catch {
            // Un APIError del transporte se respeta; cualquier otro error viaja
            // ENTERO en `underlying`. Nunca se pierde.
            let apiError = (error as? APIError) ?? APIError(code: .unexpected, request: summary, underlying: error)
            await notifyInterceptorsOfFailure(apiError, context: context)
            throw AttemptFailure(error: apiError, context: context)
        }

        // `didReceive` exige `HTTPURLResponse` (no `URLResponse`, que
        // obligaba a castear en cada interceptor): si la respuesta no lo es,
        // no hay nada válido que pasarle — directo a `.invalidResponse`.
        guard let httpResponse = response as? HTTPURLResponse else {
            let apiError = APIError(code: .invalidResponse, request: summary)
            await notifyInterceptorsOfFailure(apiError, context: context)
            throw AttemptFailure(error: apiError, context: context)
        }

        for interceptor in interceptors {
            await interceptor.didReceive(httpResponse, data: data, context: context)
        }

        // didFail se notifica en TODOS los caminos de error del pipeline:
        // transporte (arriba), respuesta inválida y status non-2xx.
        guard (200..<300).contains(httpResponse.statusCode) else {
            // Status, headers y body tal cual: el sobre de error lo decodifica
            // el consumidor con `decodeBody`, no este paquete.
            let apiError = APIError(
                code: .httpStatus,
                request: summary,
                response: APIError.ResponseSummary(response: httpResponse, body: data)
            )
            await notifyInterceptorsOfFailure(apiError, context: context)
            throw AttemptFailure(error: apiError, context: context)
        }

        return (data, httpResponse, summary)
    }

    /// Decodes the response body. `Response == Empty` always succeeds with
    /// `Empty()`, regardless of what the server actually sent (HEAD, DELETE
    /// and every 204 land here without inspecting `data`). Any other
    /// `Response` with an empty body — most commonly a 204/205 the request
    /// didn't expect — is `.decoding`, not a silently-conjured value: the
    /// caller asked for a type and nothing arrived to decode. Any other
    /// failure — a `DecodingError` or anything else the decoder throws — also
    /// becomes `.decoding`; the body stays attached via `response` so the
    /// consumer can inspect what actually came back.
    private static func decode<Response: Decodable>(
        _ type: Response.Type,
        from data: Data,
        request: APIError.RequestSummary,
        response: HTTPURLResponse,
        using makeDecoder: @Sendable () -> JSONDecoder
    ) throws(APIError) -> Response {
        if let empty = Empty() as? Response {
            return empty
        }
        guard !data.isEmpty else {
            throw APIError(
                code: .decoding,
                request: request,
                response: APIError.ResponseSummary(response: response, body: data),
                underlying: DecodingError.valueNotFound(
                    Response.self,
                    DecodingError.Context(
                        codingPath: [],
                        debugDescription: "Expected a body to decode \(Response.self), got an empty body (status \(response.statusCode))."
                    )
                )
            )
        }
        do {
            return try makeDecoder().decode(Response.self, from: data)
        } catch {
            throw APIError(
                code: .decoding,
                request: request,
                response: APIError.ResponseSummary(response: response, body: data),
                underlying: error
            )
        }
    }

    // MARK: - Helper Methods

    /// Builds a URLRequest from a BaseRequest with all features applied.
    private func buildURLRequest<Request: BaseRequest>(
        from request: Request
    ) throws(APIError) -> URLRequest {
        guard var urlComponents = URLComponents(
            url: configuration.baseURL.appending(path: request.path),
            resolvingAgainstBaseURL: true
        ) else {
            throw APIError(code: .invalidURL, request: APIError.RequestSummary(method: request.method, url: nil))
        }

        if !request.queryItems.isEmpty {
            urlComponents.queryItems = request.queryItems
        }

        guard let url = urlComponents.url else {
            throw APIError(code: .invalidURL, request: APIError.RequestSummary(method: request.method, url: nil))
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.timeoutInterval = request.timeout.timeInterval

        // Accept siempre; Content-Type SOLO si hay body (un GET sin body no
        // describe un Content-Type porque no envía contenido). Ambos son la
        // base: los defaults de la configuración y los headers del request
        // (en ese orden) pueden sobrescribirlos.
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        if request.body != nil {
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        // Merge headers: default headers first, request headers overwrite.
        for (key, value) in configuration.defaultHeaders {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }
        for (key, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }

        if let body = request.body {
            do {
                urlRequest.httpBody = try configuration.makeEncoder().encode(body)
            } catch {
                // El error original (EncodingError u otro) nunca se pierde.
                throw APIError(
                    code: .encoding,
                    request: APIError.RequestSummary(method: request.method, url: url),
                    underlying: error
                )
            }
        }

        return urlRequest
    }

    /// Notifies all interceptors of a request failure.
    private func notifyInterceptorsOfFailure(_ error: APIError, context: RequestContext) async {
        for interceptor in interceptors {
            await interceptor.didFail(error, context: context)
        }
    }
}
