import CoreNetworking
import Foundation
import os

// MARK: - MockResponse

/// A mocked HTTP response.
public struct MockResponse: Sendable, Equatable {
    public let statusCode: Int
    public let data: Data?
    /// Response headers. Include "Content-Length" to exercise download progress.
    public let headers: [String: String]

    public init(statusCode: Int, data: Data? = nil, headers: [String: String] = [:]) {
        self.statusCode = statusCode
        self.data = data
        self.headers = headers
    }
}

// MARK: - MockNetworkExchange

/// A registered mock: request matcher (method + URL) plus the outcome(s).
public struct MockNetworkExchange: Sendable {
    public let method: HTTPMethod
    public let url: URL
    /// Responses consumed in order, one per matching request; the last one
    /// repeats once exhausted (so a single-response registration behaves
    /// exactly like before: the same mock answers any number of requests).
    public let responses: [MockResponse]
    /// Transport-level failure to simulate instead of a response. Applies to
    /// every matching request (not sequenced) — for a mix of failures and
    /// successes, use `responses` with `MockResponse(statusCode: 5xx)`
    /// entries, or `InMemoryTransport` for unit tests.
    public let error: URLError?
    /// Optional artificial latency before delivering — useful to test
    /// cancellation. `stopLoading` cancels a pending delivery.
    public let latency: Duration?

    /// Registers a single, reusable response — the common case.
    public init(
        method: HTTPMethod = .get,
        url: URL,
        response: MockResponse,
        error: URLError? = nil,
        latency: Duration? = nil
    ) {
        self.init(method: method, url: url, responses: [response], error: error, latency: latency)
    }

    /// Registers a sequence of responses consumed in order (e.g. 500, 500,
    /// 200 to test "retry that eventually succeeds" through the real URL
    /// loading system).
    public init(
        method: HTTPMethod = .get,
        url: URL,
        responses: [MockResponse],
        error: URLError? = nil,
        latency: Duration? = nil
    ) {
        self.method = method
        self.url = url
        self.responses = responses
        self.error = error
        self.latency = latency
    }
}

// MARK: - MockURLProtocol

/// Deterministic `URLProtocol` for intercepting requests in tests, through
/// the real URL loading system — for the few integration tests that need
/// that (header merging, redirections, the pinning delegate). For unit tests,
/// prefer `InMemoryTransport`: no static/global registry to fight Swift
/// Testing's parallel execution, no "one host per test" discipline.
///
/// - Registration is synchronous (no fire-and-forget tasks): once `register`
///   returns, the mock is visible to the next request.
/// - Matching is by HTTP method + URL.
/// - Responses are consumed in order (`responses`); the last one repeats
///   once exhausted, so a single-response registration answers any number of
///   requests, same as before — until `removeAll()`.
/// - Every handled request is recorded (`recordedRequests`) so tests can
///   assert exact request counts (retry) and headers.
///
/// ## Example
/// ```swift
/// MockURLProtocol.register(MockNetworkExchange(
///     url: URL(string: "https://unit.test/games")!,
///     response: MockResponse(statusCode: 200, data: json)
/// ))
/// let configuration = NetworkingConfiguration(
///     baseURL: URL(string: "https://unit.test")!,
///     protocolClasses: [MockURLProtocol.self]
/// )
/// ```
/// `@unchecked Sendable` JUSTIFICADO: `URLProtocol` no es `Sendable` para el compilador,
/// pero el URL loading system mantiene viva la instancia hasta finish/stopLoading y los
/// callbacks de `client` son seguros desde cualquier hilo; el único estado mutable propio
/// (`pendingDelivery`) va bajo `OSAllocatedUnfairLock`. Declarado en la clase (no en una
/// extensión): el análisis de regiones de `sending` solo lo reconoce así.
public final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    private struct MatchKey: Hashable, Sendable {
        let method: String
        let url: URL
    }

    private struct RegistryState: Sendable {
        var exchanges: [MatchKey: MockNetworkExchange] = [:]
        var cursors: [MatchKey: Int] = [:]
        var recorded: [URLRequest] = []
        /// Entregas con latencia que `stopLoading` canceló ANTES de entregarse, por
        /// método+URL. Ver `cancelledDeliveries(method:url:)`.
        var cancelledDeliveries: [MatchKey: Int] = [:]
    }

    private static let registry = OSAllocatedUnfairLock(initialState: RegistryState())

    // `uncheckedState`: `DispatchWorkItem` no es `Sendable`; solo se toca bajo este lock.
    private let pendingDelivery = OSAllocatedUnfairLock<DispatchWorkItem?>(uncheckedState: nil)

    // MARK: Registration API

    /// Registers a mock. Overwrites any previous mock for the same
    /// method+URL and resets its cursor into `responses`.
    public static func register(_ exchange: MockNetworkExchange) {
        let key = MatchKey(method: exchange.method.rawValue, url: exchange.url)
        registry.withLock {
            $0.exchanges[key] = exchange
            $0.cursors[key] = 0
        }
    }

    /// Removes all mocks and recorded requests.
    public static func removeAll() {
        registry.withLock { $0 = RegistryState() }
    }

    /// Every request this protocol handled, in order.
    public static var recordedRequests: [URLRequest] {
        registry.withLock { $0.recorded }
    }

    /// Cuántas entregas con `latency` canceló `stopLoading` para ese método+URL ANTES
    /// de que llegaran a entregarse.
    ///
    /// Es la señal OBSERVABLE de que el URL loading system desmontó de verdad la
    /// transferencia en vuelo — lo que hace una cancelación real. Sustituye a medir el
    /// reloj ("tardó menos que la latencia del mock, luego se canceló"), que es la misma
    /// afirmación por vía indirecta y se rompe en cuanto la máquina va cargada: en el
    /// simulador de un runner de CI, cancelaciones correctas tardaban ~4 s y hacían
    /// fallar un presupuesto de 2 s.
    ///
    /// Una entrega que llegó a ejecutarse NO cuenta aquí aunque después llegue un
    /// `stopLoading` (entrega y cancelación se reclaman en exclusión mutua), así que el
    /// contador solo sube cuando hubo cancelación genuina.
    ///
    /// Aísla por URL, igual que los mocks: un contador global sería inservible con las
    /// suites en paralelo.
    public static func cancelledDeliveries(method: HTTPMethod = .get, url: URL) -> Int {
        let key = MatchKey(method: method.rawValue, url: url)
        return registry.withLock { $0.cancelledDeliveries[key, default: 0] }
    }

    /// Espera a que `cancelledDeliveries(method:url:)` llegue a `count`, con un timeout
    /// explícito. Devuelve `false` si expira — nunca cuelga.
    ///
    /// El sondeo es un detalle de implementación: lo que se espera es la señal, no un
    /// tiempo fijo. El caso bueno sale en el primer sondeo o el segundo; el malo tarda
    /// exactamente `timeout` y falla por el motivo correcto, no por un `sleep` que se
    /// quedó corto.
    public static func waitForCancelledDelivery(
        method: HTTPMethod = .get,
        url: URL,
        count: Int = 1,
        timeout: Duration = .seconds(10)
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while true {
            if cancelledDeliveries(method: method, url: url) >= count { return true }
            if ContinuousClock.now >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    // MARK: URLProtocol

    public override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    public override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    public override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let method = request.httpMethod ?? "GET"
        let handledRequest = request

        let matched = Self.registry.withLock { state -> (MockNetworkExchange, MockResponse)? in
            state.recorded.append(handledRequest)
            let key = MatchKey(method: method, url: url)
            guard let exchange = state.exchanges[key] else { return nil }
            let index = state.cursors[key, default: 0]
            state.cursors[key] = index + 1
            let response = exchange.responses[min(index, exchange.responses.count - 1)]
            return (exchange, response)
        }

        guard let (exchange, response) = matched else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }

        if let latency = exchange.latency {
            // `DispatchWorkItem` y no `Task`: el closure de un `Task` es `sending` y el
            // análisis de regiones rechaza capturar `self` aunque sea `@unchecked Sendable`
            // (Xcode 26.3 lo reporta como error). Un work item es `@Sendable` y se cancela
            // igual desde `stopLoading`.
            let work = DispatchWorkItem { [self] in
                // Reclama la entrega: si `stopLoading` ya se llevó el work item, esta
                // ejecución no entrega nada. Así entrega y cancelación se excluyen
                // mutuamente incluso si `cancel()` llega con el item ya arrancado, y el
                // contador de `cancelledDeliveries` no puede contar una entrega que sí
                // ocurrió.
                let claimed = pendingDelivery.withLockUnchecked { pending -> Bool in
                    guard pending != nil else { return false }
                    pending = nil
                    return true
                }
                guard claimed else { return }
                self.deliver(exchange, response: response)
            }
            pendingDelivery.withLockUnchecked { $0 = work }
            let seconds =
                Double(latency.components.seconds) + Double(latency.components.attoseconds) / 1e18
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: work)
        } else {
            deliver(exchange, response: response)
        }
    }

    public override func stopLoading() {
        let cancelled = pendingDelivery.withLockUnchecked { pending -> Bool in
            guard let work = pending else { return false }
            work.cancel()
            pending = nil
            return true
        }
        // Solo cuenta si había una entrega pendiente que ESTE `stopLoading` se llevó por
        // delante: un `stopLoading` tras una entrega ya consumada no es una cancelación.
        guard cancelled, let url = request.url else { return }
        let key = MatchKey(method: request.httpMethod ?? "GET", url: url)
        Self.registry.withLock { $0.cancelledDeliveries[key, default: 0] += 1 }
    }

    // MARK: Delivery

    private func deliver(_ exchange: MockNetworkExchange, response: MockResponse) {
        if let error = exchange.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }

        guard
            let httpResponse = HTTPURLResponse(
                url: exchange.url,
                statusCode: response.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: response.headers
            )
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
        if let data = response.data {
            client?.urlProtocol(self, didLoad: data)
        }
        client?.urlProtocolDidFinishLoading(self)
    }
}
