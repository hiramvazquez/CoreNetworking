import CoreNetworking
import Foundation

/// Records every `willSend`/`didReceive`/`didFail` call it receives, in
/// order — the interceptor to test YOUR OWN interceptors and retriers
/// against, or to assert what the pipeline actually invoked (order, how many
/// times, which `context`) without writing a bespoke spy per test.
///
/// `actor`, not a lock-guarded class: `APIService` can call an interceptor
/// from more than one attempt concurrently (e.g. several requests racing),
/// so recording needs real synchronization.
///
/// ## Example
/// ```swift
/// let recorder = RecordingInterceptor()
/// let service = APIService(configuration: configuration, transport: transport, interceptors: [recorder])
/// _ = try await service.execute(GetGames())
///
/// let events = await recorder.events
/// #expect(events.count == 2) // willSend, didReceive
/// ```
public actor RecordingInterceptor: RequestInterceptor {
    /// One recorded call, in the order `APIService` made it.
    public enum Event: Sendable {
        case willSend(request: URLRequest, context: RequestContext)
        case didReceive(statusCode: Int, data: Data, context: RequestContext)
        case didFail(error: APIError, context: RequestContext)
    }

    public private(set) var events: [Event] = []

    /// Returned by `willSend` for every recorded request when non-`nil`.
    /// Lets a test exercise "willSend aborts" without a bespoke interceptor.
    private let willSendError: APIError?

    /// - Parameter willSendThrows: When set, every `willSend` call records
    ///   the event and then throws this error instead of returning the
    ///   request. Default: `nil` (never throws).
    public init(willSendThrows: APIError? = nil) {
        self.willSendError = willSendThrows
    }

    public func willSend(_ request: URLRequest, context: RequestContext) async throws(APIError) -> URLRequest {
        events.append(.willSend(request: request, context: context))
        if let willSendError {
            throw willSendError
        }
        return request
    }

    public func didReceive(_ response: HTTPURLResponse, data: Data, context: RequestContext) async {
        events.append(.didReceive(statusCode: response.statusCode, data: data, context: context))
    }

    public func didFail(_ error: APIError, context: RequestContext) async {
        events.append(.didFail(error: error, context: context))
    }
}
