import Foundation
import CoreNetworking
import os

/// In-memory stub of `APIServiceProtocol` for unit-testing consumers.
///
/// Configure `result` (the value to return) or `error` (the `APIError` to
/// throw) and inject it wherever an `APIServiceProtocol` is expected.
public final class MockAPIService: APIServiceProtocol, @unchecked Sendable {
    // @unchecked Sendable JUSTIFICADO: el estado guarda `Any?` (no comprobable
    // como Sendable por el compilador) y TODO acceso pasa por el lock `state`
    // (OSAllocatedUnfairLock). No hay otra propiedad mutable.
    private struct Stubs {
        var result: Any?
        var error: APIError?
    }

    private let state = OSAllocatedUnfairLock(uncheckedState: Stubs())

    public init() {}

    /// Value returned by `execute`/`upload` (must match `Response`) or by
    /// `download` (must be `Data`).
    public var result: Any? {
        get { state.withLockUnchecked { $0.result } }
        set { state.withLockUnchecked { $0.result = newValue } }
    }

    /// Error thrown by every method when non-nil (takes precedence over `result`).
    public var error: APIError? {
        get { state.withLockUnchecked { $0.error } }
        set { state.withLockUnchecked { $0.error = newValue } }
    }

    public func execute<Request: BaseRequest>(
        _ request: Request
    ) async throws(APIError) -> Request.Response {
        try stubbedValue()
    }

    public func execute<Request: BaseRequest, Value: Decodable & Sendable>(
        _ request: Request,
        as type: Value.Type
    ) async throws(APIError) -> Value {
        try stubbedValue()
    }

    public func upload<Request: BaseRequest, Response: Decodable>(
        request: Request,
        data: Data,
        progress: (@Sendable (Double) -> Void)?
    ) async throws(APIError) -> Response {
        try stubbedValue()
    }

    public func download<Request: BaseRequest>(
        request: Request,
        progress: (@Sendable (Double) -> Void)?
    ) async throws(APIError) -> Data {
        try stubbedValue()
    }

    private func stubbedValue<Value>() throws(APIError) -> Value {
        let stubs = state.withLockUnchecked { $0 }
        if let error = stubs.error { throw error }
        if let value = stubs.result as? Value { return value }
        throw APIError(code: .invalidResponse)
    }
}

// MARK: - APIError stub

public extension APIError {
    /// Convenience constructor for tests: builds a minimal but valid
    /// `APIError` without going through the pipeline.
    ///
    /// `APIError` is deliberately not `Equatable` (see the type's doc
    /// comment): compare `error.code`, `error.statusCode` or `error.category`
    /// instead of the whole value.
    static func stub(
        code: Code,
        statusCode: Int? = nil,
        headers: [String: String] = [:],
        body: Data = Data(),
        request: RequestSummary? = nil,
        underlying: (any Error)? = nil
    ) -> APIError {
        let response = statusCode.map {
            ResponseSummary(statusCode: $0, headers: headers, body: body)
        }
        return APIError(code: code, request: request, response: response, underlying: underlying)
    }
}
