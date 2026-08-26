#if canImport(XCTest) || DEBUG
import Foundation

public final class MockAPIService: APIServiceProtocol {
    public var result: Any?
    public var error: Error?

    public init() {}
    
    public func upload<Request, Response>(request: Request, data: Data, progress: (@Sendable (Double) -> Void)?) async throws -> Response where Request : BaseRequest, Response : Decodable {
        if let error { throw error }
        if let result = result as? Response {
            return result
        }
        throw APIError.invalidResponse
    }
    
    public func download<Request>(request: Request, progress: (@Sendable (Double) -> Void)?) async throws -> Data where Request : BaseRequest {
        if let error { throw error }
        if let result = result as? Data {
            return result
        }
        throw APIError.invalidResponse
    }

    public func execute<Request: BaseRequest, Response: Decodable>(request: Request) async throws -> Response {
        if let error { throw error }
        if let result = result as? Response {
            return result
        }
        throw APIError.invalidResponse
    }
}
#endif
