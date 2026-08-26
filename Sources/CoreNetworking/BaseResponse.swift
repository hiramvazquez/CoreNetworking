import Foundation

public protocol BaseResponse: Decodable {}

public struct EmptyResponse: BaseResponse {
    public init() {}
}
