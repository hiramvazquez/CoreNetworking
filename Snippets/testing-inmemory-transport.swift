// InMemoryTransport: sin URLSession, sin registro estático global — soporta
// secuencias de respuestas (500 → 500 → 200) para probar "reintento que acaba bien".
// ManualClock: el pipeline avanza solo cuando el test llama a advance(by:) — cero
// esperas reales, cero flakiness por carga de CI.
import CoreNetworking
import CoreNetworkingTestSupport
import Foundation

struct GetGames: BaseRequest {
    struct Response: Decodable, Sendable { let games: [String] }
    let path = "/games"
    let method = HTTPMethod.get
}

func retryEventuallySucceeds() async throws {
    let transport = InMemoryTransport()
    await transport.register(
        InMemoryTransport.Exchange(
            url: URL(string: "https://unit.test/games")!,
            responses: [
                .response(status: 500),
                .response(status: 500),
                .response(status: 200, body: Data(#"{"games":["chess"]}"#.utf8)),
            ]
        ))

    let clock = ManualClock()
    let service = APIService(
        configuration: NetworkingConfiguration(baseURL: URL(string: "https://unit.test")!),
        transport: transport,
        retryPolicy: RetryPolicy(maxAttempts: 3, initialDelay: .milliseconds(500)),
        clock: clock
    )

    let task = Task { () async throws(APIError) -> GetGames.Response in
        try await service.execute(GetGames())
    }

    // Dos reintentos antes del 200: dos backoffs que disparar a mano.
    await clock.waitUntilSleeping()
    clock.advance(by: .seconds(10))
    await clock.waitUntilSleeping()
    clock.advance(by: .seconds(10))

    let games = try await task.value
    let attempts = await transport.recorded.count
    assert(games.games == ["chess"])
    assert(attempts == 3)
}

try await retryEventuallySucceeds()
