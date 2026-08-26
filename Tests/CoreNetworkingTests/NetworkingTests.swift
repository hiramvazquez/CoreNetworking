import XCTest
@testable import CoreNetworking

final class NetworkingTests: XCTestCase {
    func testMockedResponse() async throws {
        struct SampleRequest: BaseRequest {
            typealias Parameters = EmptyParameters
            var path: String { "/sample" }
            var method: HTTPMethod { .GET }
        }

        struct SampleResponse: BaseResponse {
            let value: Int
        }

        let baseURL = try XCTUnwrap(URL(string: "https://unit.test"))
        MockURLProtocol.register(
            MockNetworkExchange(
                url: baseURL.appendingPathComponent("/sample"),
                response: MockResponse(statusCode: 200, data: Data("{\"value\":1}".utf8))
            )
        )

        let configuration = NetworkingConfiguration(
            baseURL: baseURL,
            protocolClasses: [MockURLProtocol.self]
        )
        let client = APIService(configuration: configuration)

        let result: SampleResponse = try await client.execute(request: SampleRequest())
        XCTAssertEqual(result.value, 1)
    }
}
