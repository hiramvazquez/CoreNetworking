import CoreNetworking
import Foundation
import os

/// In-memory stub of `APIServiceProtocol` for unit-testing consumers.
///
/// Stubs are keyed by REQUEST TYPE, not by call order: `stub(_:returning:)`
/// registers what `execute`/`upload`/`download` return for that particular
/// `BaseRequest` type, and `stub(_:throwing:)` registers what they throw
/// instead. This replaces a single untyped `result: Any?` — a mismatched
/// type used to fall through to a misleading `.invalidResponse`; now the
/// mismatch cannot happen because the stub is looked up by the exact request
/// type being executed.
///
/// ## Example
/// ```swift
/// let mock = MockAPIService()
/// mock.stub(GetGamesRequest.self, returning: [Game(id: 1)])
/// mock.stub(DeleteGameRequest.self, throwing: .stub(code: .httpStatus, statusCode: 404))
/// ```
public final class MockAPIService: APIServiceProtocol, @unchecked Sendable {
    // @unchecked Sendable JUSTIFICADO: el diccionario guarda `Any` (no
    // comprobable como Sendable por el compilador) y TODO acceso pasa por el
    // lock `state` (OSAllocatedUnfairLock). No hay otra propiedad mutable.
    private struct Stub {
        var value: Any? = nil
        var error: APIError? = nil
    }

    private let state = OSAllocatedUnfairLock(uncheckedState: [ObjectIdentifier: Stub]())

    public init() {}

    /// Registers the value `execute`/`upload` (matched against `Response`) or
    /// `download` (matched against `Data`) return for requests of this type.
    public func stub<Request: BaseRequest, Value>(_ requestType: Request.Type, returning value: Value) {
        state.withLockUnchecked { $0[ObjectIdentifier(requestType), default: Stub()].value = value }
    }

    /// Registers the error thrown for requests of this type (takes
    /// precedence over a `returning` stub for the same type).
    public func stub<Request: BaseRequest>(_ requestType: Request.Type, throwing error: APIError) {
        state.withLockUnchecked { $0[ObjectIdentifier(requestType), default: Stub()].error = error }
    }

    public func execute<Request: BaseRequest>(
        _ request: Request
    ) async throws(APIError) -> Request.Response {
        try stubbedValue(for: Request.self)
    }

    public func execute<Request: BaseRequest, Value: Decodable & Sendable>(
        _ request: Request,
        as type: Value.Type
    ) async throws(APIError) -> Value {
        try stubbedValue(for: Request.self)
    }

    public func upload<Request: BaseRequest>(
        _ request: Request,
        data: Data,
        progress: (@Sendable (Double) -> Void)?
    ) async throws(APIError) -> Request.Response {
        try stubbedValue(for: Request.self)
    }

    public func upload<Request: BaseRequest, Value: Decodable & Sendable>(
        _ request: Request,
        data: Data,
        as type: Value.Type,
        progress: (@Sendable (Double) -> Void)?
    ) async throws(APIError) -> Value {
        try stubbedValue(for: Request.self)
    }

    public func data<Request: BaseRequest>(
        for request: Request,
        progress: (@Sendable (Double) -> Void)?
    ) async throws(APIError) -> Data {
        try stubbedValue(for: Request.self)
    }

    /// `download` returns `Void` (the content lives at `destination`, not in
    /// the return value), so it does not go through `stubbedValue`: register
    /// `stub(_:throwing:)` to simulate a failed download; with no stub
    /// registered, or one registered with `stub(_:returning:)`, it succeeds
    /// without writing anything to `destination` — a consumer test that
    /// needs real file content should use `APIService` with
    /// `InMemoryTransport`/`URLSessionTransport` instead of this mock.
    public func download<Request: BaseRequest>(
        _ request: Request,
        to destination: URL,
        progress: (@Sendable (Double) -> Void)?
    ) async throws(APIError) {
        let stub = state.withLockUnchecked { $0[ObjectIdentifier(Request.self)] }
        if let error = stub?.error {
            throw error
        }
    }

    private func stubbedValue<Request: BaseRequest, Value>(for requestType: Request.Type) throws(APIError) -> Value {
        guard let stub = state.withLockUnchecked({ $0[ObjectIdentifier(requestType)] }) else {
            throw APIError(code: .unstubbed, underlying: UnstubbedRequest(request: requestType, expected: Value.self))
        }
        if let error = stub.error { throw error }
        if let value = stub.value as? Value { return value }
        throw APIError(code: .unstubbed, underlying: UnstubbedRequest(request: requestType, expected: Value.self))
    }
}

// MARK: - APIError.Code.unstubbed

extension APIError.Code {
    /// Thrown by `MockAPIService` when a request type has no stub
    /// registered, or the one registered doesn't match the type asked for.
    /// `.invalidResponse` used to stand in for this and misled — nothing
    /// about a response was invalid, the test forgot to (or couldn't) stub
    /// the call. `Code` is an open set (see `APIError.Code`), which is
    /// exactly what lets test support define its own without touching the
    /// package's.
    public static let unstubbed = Self("testSupport.unstubbed")
}

/// `underlying` of an `APIError(code: .unstubbed)`: names the request type
/// and the type the caller expected back, so the failure message says
/// exactly what to stub instead of just "no stub".
private struct UnstubbedRequest: Error, CustomStringConvertible {
    let request: Any.Type
    let expected: Any.Type

    var description: String {
        "No stub registered for \(request) matching \(expected) — call stub(_:returning:) or stub(_:throwing:) first."
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
