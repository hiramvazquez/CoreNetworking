import XCTest
@testable import CoreNetworking

final class NetworkingTests: XCTestCase {
    func testMockedResponse() async throws {
        struct SampleRequest: BaseRequest, MockableRequest {
            typealias Parameters = EmptyParameters
            var path: String { "/sample" }
            var method: HTTPMethod { .GET }
            var mockedData: Data? { "{\"value\":1}".data(using: .utf8) }
        }

        struct SampleResponse: BaseResponse {
            let value: Int
        }

        let client = APIService()
        let result: SampleResponse = try await client.execute(request: SampleRequest())
        XCTAssertEqual(result.value, 1)
    }
}
