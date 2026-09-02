import CoreNetworking
import CoreNetworkingTestSupport
import Foundation
import Testing

// MARK: - PRD-AF-07: `EndpointService`

private struct GetProfileRequest: BaseRequest {
    struct Response: Decodable, Sendable, Equatable {
        let name: String
    }

    let path = "/profile"
    let method = HTTPMethod.get
}

/// The exact shape `ARQUITECTURA-KIT-2026-09-02.md` §1-2 documents: a `Service` holds
/// `api` and gets `call(_:)` for free.
private struct ProfileService: EndpointService {
    let api: any APIServiceProtocol

    func fetchProfile() async throws(APIError) -> GetProfileRequest.Response {
        try await call(GetProfileRequest())
    }
}

@Suite("EndpointService (PRD-AF-07)")
struct EndpointServiceTests {
    @Test("call(_:) forwards to api.execute and returns its decoded Response")
    func callForwardsToExecute() async throws {
        let mock = MockAPIService()
        mock.stub(GetProfileRequest.self, returning: GetProfileRequest.Response(name: "Hiram"))
        let service = ProfileService(api: mock)

        let response = try await service.fetchProfile()

        #expect(response == GetProfileRequest.Response(name: "Hiram"))
    }

    @Test("call(_:) propagates the underlying APIError unchanged")
    func callPropagatesError() async throws {
        let mock = MockAPIService()
        mock.stub(GetProfileRequest.self, throwing: .stub(code: .httpStatus, statusCode: 404))
        let service = ProfileService(api: mock)

        do {
            _ = try await service.fetchProfile()
            Issue.record("Expected fetchProfile() to throw")
        } catch {
            #expect(error.code == .httpStatus)
            #expect(error.statusCode == 404)
        }
    }

    @Test("call(_:) works against the real pipeline through InMemoryTransport")
    func callWorksAgainstRealPipeline() async throws {
        let transport = InMemoryTransport()
        let baseURL = URL(string: "https://unit.test")!
        await transport.register(
            InMemoryTransport.Exchange(
                url: baseURL.appendingPathComponent("profile"),
                response: .response(status: 200, body: #"{"name":"Hiram"}"#.data(using: .utf8)!)
            )
        )
        let api = APIService(
            configuration: NetworkingConfiguration(baseURL: baseURL),
            transport: transport,
            clock: ManualClock()
        )
        let service = ProfileService(api: api)

        let response = try await service.fetchProfile()

        #expect(response == GetProfileRequest.Response(name: "Hiram"))
    }
}
