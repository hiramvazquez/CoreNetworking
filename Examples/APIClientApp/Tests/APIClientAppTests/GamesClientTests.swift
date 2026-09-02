import CoreNetworking
import CoreNetworkingTestSupport
import Foundation
import Testing

@testable import APIClientApp

@Suite struct GamesClientTests {
    @Test func fetchGamesMapsDTOToDomain() async throws {
        let mock = MockAPIService()
        mock.stub(GetGames.self, returning: GetGames.Response(games: [GameDTO(id: "1", title: "Chess")]))
        let client = GamesClient(api: mock)

        let games = try await client.fetchGames()

        #expect(games == [Game(id: "1", title: "Chess")])
    }

    @Test func fetchGamesMapsNotFoundToDomainError() async throws {
        let mock = MockAPIService()
        mock.stub(GetGames.self, throwing: .stub(code: .httpStatus, statusCode: 404))
        let client = GamesClient(api: mock)

        await #expect(throws: GamesError.notFound) {
            try await client.fetchGames()
        }
    }

    @Test func createGameSendsTitleAndMapsResponse() async throws {
        let mock = MockAPIService()
        mock.stub(CreateGame.self, returning: CreateGame.Response(id: "42", title: "Chess"))
        let client = GamesClient(api: mock)

        let created = try await client.createGame(title: "Chess")

        #expect(created == Game(id: "42", title: "Chess"))
    }

    @Test func fetchGamesRetriesThroughRealPipeline() async throws {
        let transport = InMemoryTransport()
        await transport.register(
            InMemoryTransport.Exchange(
                url: URL(string: "https://unit.test/games")!,
                responses: [
                    .response(status: 500),
                    .response(status: 200, body: Data(#"{"games":[{"id":"1","title":"Chess"}]}"#.utf8))
                ]
            )
        )

        let clock = ManualClock()
        let service = APIService(
            configuration: NetworkingConfiguration(baseURL: URL(string: "https://unit.test")!),
            transport: transport,
            retryPolicy: RetryPolicy(maxAttempts: 2, initialDelay: .milliseconds(1)),
            clock: clock
        )
        let client = GamesClient(api: service)

        async let games = client.fetchGames()

        await clock.waitUntilSleeping()
        clock.advance(by: .seconds(1))

        #expect(try await games == [Game(id: "1", title: "Chess")])
    }
}
