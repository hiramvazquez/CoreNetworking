import Foundation
import Testing

@testable import CoreNetworking
@testable import CoreNetworkingTestSupport

// The code blocks from CoreNetworking/README.md, copied as they appear (types nested
// inside a private enum namespace so they don't collide with the rest of the suite — the
// same pattern `RequestBuildingTests` uses with `private struct`, just shared across
// several README sections instead of one test). Any drift between the README and the
// real API fails to compile here instead of surfacing as a support ticket.
private enum READMEExamples {
    // MARK: - "2. Requests tipados"

    struct Game: Decodable, Sendable, Equatable {
        let id: Int
    }

    struct GetGames: BaseRequest {
        struct Response: Decodable, Sendable { let games: [Game] }
        let path = "/games"
        let method = HTTPMethod.get
    }

    struct CreateGame: BaseRequest {
        struct Body: Encodable, Sendable { let title: String }
        struct Response: Decodable, Sendable { let id: String }

        let path = "/games"
        let method = HTTPMethod.post
        let body: Body?

        init(title: String) { self.body = Body(title: title) }
    }

    struct DeleteGame: BaseRequest {
        let path: String
        let method = HTTPMethod.delete
        init(id: String) { self.path = "/games/\(id)" }
    }

    // MARK: - "Errores" — the app's own error envelope

    struct MyServerProblem: Decodable, Sendable {
        let detail: String
    }
}

// MARK: - "1. Configuración y servicio" — factories compile and are wired end to end

@Suite("README examples compile — Configuration")
struct READMEConfigurationTests {
    @Test("makeDecoder/makeEncoder/sessionConfiguration factories build without a service")
    func factoriesCompile() {
        let configuration = NetworkingConfiguration(
            baseURL: URL(string: "https://api.miapp.com")!,
            defaultHeaders: ["X-App-Version": "1.0"],
            makeDecoder: {
                let d = JSONDecoder()
                d.keyDecodingStrategy = .convertFromSnakeCase
                d.dateDecodingStrategy = .iso8601
                return d
            },
            makeEncoder: {
                let e = JSONEncoder()
                e.keyEncodingStrategy = .convertToSnakeCase
                e.dateEncodingStrategy = .iso8601
                return e
            },
            sessionConfiguration: {
                let c = NetworkingConfiguration.defaultSessionConfiguration()
                c.timeoutIntervalForResource = 120
                return c
            }
        )

        let service = APIService(configuration: configuration)
        _ = service
    }

    @Test("A transport built by hand, with pinning, wires into APIService")
    func transportInjectionCompiles() {
        let pinning = SSLPinningConfiguration(
            publicKeyHashes: [
                "r/mIkG3eEpVdm+u/ko/cwxzOMo1bk4TyHIlByibiA5E=",
                "Vjs8r4z+80wjNcr1YKepWQboSIRi63WsWXhIMN+eWys="
            ],
            hosts: .only(["api.miapp.com"])
        )
        let transport = URLSessionTransport(
            configuration: {
                let c = NetworkingConfiguration.defaultSessionConfiguration()
                c.timeoutIntervalForResource = 120
                return c
            }(),
            pinning: pinning
        )
        let configuration = NetworkingConfiguration(baseURL: URL(string: "https://api.miapp.com")!)
        let service = APIService(configuration: configuration, transport: transport)
        _ = service

        // "SSL Pinning programático" — the convenience init that skips a hand-built transport.
        let serviceWithConvenience = APIService(configuration: configuration, sslPinning: pinning)
        _ = serviceWithConvenience
    }
}

// MARK: - "3. Ejecutar", "Upload / Download", "Errores" — the pipeline end to end

@Suite("README examples compile and behave — Execute / Errors")
struct READMEExecuteAndErrorsTests {
    @Test("execute(_:) returns the request's declared Response")
    func executeReturnsDeclaredResponse() async throws {
        let transport = InMemoryTransport()
        let url = URL(string: "https://unit.test/games")!
        await transport.register(
            InMemoryTransport.Exchange(
                url: url,
                response: .response(status: 200, body: #"{"games":[{"id":1}]}"#.data(using: .utf8)!)
            )
        )
        let service = APIService(
            configuration: NetworkingConfiguration(baseURL: URL(string: "https://unit.test")!),
            transport: transport
        )

        let games = try await service.execute(READMEExamples.GetGames()).games
        #expect(games == [READMEExamples.Game(id: 1)])
    }

    @Test("execute(_:as:) decodes something other than the request's declared Response")
    func executeAsOverrideDecodesAlternateType() async throws {
        struct RawGamesEnvelope: Decodable, Sendable { let games: [READMEExamples.Game] }

        let transport = InMemoryTransport()
        let url = URL(string: "https://unit.test/games")!
        await transport.register(
            InMemoryTransport.Exchange(
                url: url,
                response: .response(status: 200, body: #"{"games":[{"id":7}]}"#.data(using: .utf8)!)
            )
        )
        let service = APIService(
            configuration: NetworkingConfiguration(baseURL: URL(string: "https://unit.test")!),
            transport: transport
        )

        let raw = try await service.execute(READMEExamples.GetGames(), as: RawGamesEnvelope.self)
        #expect(raw.games == [READMEExamples.Game(id: 7)])
    }

    @Test("category switch and decodeBody(_:) — the app decodes its own error envelope")
    func categorySwitchAndDecodeBody() async {
        let transport = InMemoryTransport()
        let url = URL(string: "https://unit.test/games")!
        await transport.register(
            InMemoryTransport.Exchange(
                url: url,
                response: .response(
                    status: 422,
                    body: #"{"detail":"invalid title"}"#.data(using: .utf8)!
                )
            )
        )
        let service = APIService(
            configuration: NetworkingConfiguration(baseURL: URL(string: "https://unit.test")!),
            transport: transport
        )

        do {
            _ = try await service.execute(READMEExamples.GetGames())
            Issue.record("Expected a thrown APIError")
        } catch {
            switch error.category {
            case .offline, .unauthorized, .untrustedServer:
                Issue.record("Unexpected category \(error.category)")
            default:
                let problem = try? error.decodeBody(READMEExamples.MyServerProblem.self)
                #expect(problem?.detail == "invalid title")
            }
        }
    }

    @Test("CoreNetworkingTestSupport.APIError.stub — no pipeline required")
    func apiErrorStub() {
        let error = APIError.stub(code: .httpStatus, statusCode: 422, body: Data())
        #expect(error.code == .httpStatus)
        #expect(error.statusCode == 422)
    }
}

// MARK: - "Retry" — shouldRetry predicate and Clock injection

@Suite("README examples compile and behave — Retry")
struct READMERetryTests {
    @Test("shouldRetry predicate excludes .interceptor errors as documented")
    func shouldRetryExcludesInterceptorErrors() {
        let policy = RetryPolicy(shouldRetry: { error, _ in error.isRetryable && error.code != .interceptor })
        let interceptorFailure = APIError.stub(code: .interceptor)
        let serverFailure = APIError.stub(code: .httpStatus, statusCode: 503)

        #expect(!policy.shouldRetry(interceptorFailure, 1))
        #expect(policy.shouldRetry(serverFailure, 1))
    }

    @Test("A 500 → 500 → 200 sequence over InMemoryTransport with ManualClock ends in success")
    func retrySequenceEndsInSuccess() async throws {
        let transport = InMemoryTransport()
        let url = URL(string: "https://unit.test/games")!
        await transport.register(
            InMemoryTransport.Exchange(
                url: url,
                responses: [
                    .response(status: 500),
                    .response(status: 500),
                    .response(status: 200, body: #"{"games":[]}"#.data(using: .utf8)!)
                ]
            )
        )

        let clock = ManualClock()
        let service = APIService(
            configuration: NetworkingConfiguration(baseURL: URL(string: "https://unit.test")!),
            transport: transport,
            retryPolicy: RetryPolicy(maxAttempts: 3, initialDelay: .milliseconds(1)),
            clock: clock
        )

        async let games: [READMEExamples.Game] = service.execute(READMEExamples.GetGames()).games

        await clock.waitUntilSleeping()
        clock.advance(by: .seconds(1))
        await clock.waitUntilSleeping()
        clock.advance(by: .seconds(1))

        #expect(try await games.isEmpty)
        #expect(await transport.recorded.count == 3)
    }
}

// MARK: - "Interceptores", "Reintento por interceptor (RequestRetrier)"

@Suite("README examples compile and behave — Interceptors and RequestRetrier")
struct READMEInterceptorTests {
    @Test("RecordingInterceptor records willSend then didReceive, in order")
    func recordingInterceptorRecordsCalls() async throws {
        let transport = InMemoryTransport()
        let url = URL(string: "https://unit.test/games")!
        await transport.register(
            InMemoryTransport.Exchange(
                url: url,
                response: .response(status: 200, body: #"{"games":[]}"#.data(using: .utf8)!)
            )
        )
        let recorder = RecordingInterceptor()
        let service = APIService(
            configuration: NetworkingConfiguration(baseURL: URL(string: "https://unit.test")!),
            transport: transport,
            interceptors: [recorder]
        )

        _ = try await service.execute(READMEExamples.GetGames())

        let events = await recorder.events
        #expect(events.count == 2)
        guard case .willSend = events[0] else {
            Issue.record("Expected willSend first")
            return
        }
        guard case .didReceive = events[1] else {
            Issue.record("Expected didReceive second")
            return
        }
    }

    @Test("A RequestRetrier is consulted before RetryPolicy on a failed attempt")
    func requestRetrierDecidesBeforeRetryPolicy() async throws {
        struct AlwaysRetryOnce: RequestRetrier {
            func retry(_ error: APIError, context: RequestContext) async -> RetryDecision {
                context.attempt == 1 ? .retry : .doNotRetry
            }
        }

        let transport = InMemoryTransport()
        let url = URL(string: "https://unit.test/games")!
        await transport.register(
            InMemoryTransport.Exchange(
                // 400 is NOT in `APIError.isRetryable`'s default set — `RetryPolicy` alone
                // would give up after the first attempt. The retrier is what makes this
                // succeed, exactly as the README describes ("consultado ANTES que
                // RetryPolicy"); `maxAttempts: 2` still bounds it (README: "RetryPolicy.
                // maxAttempts acota ambos caminos").
                url: url,
                responses: [.response(status: 400), .response(status: 200, body: #"{"games":[]}"#.data(using: .utf8)!)]
            )
        )
        let clock = ManualClock()
        let service = APIService(
            configuration: NetworkingConfiguration(baseURL: URL(string: "https://unit.test")!),
            transport: transport,
            retryPolicy: RetryPolicy(maxAttempts: 2),
            retriers: [AlwaysRetryOnce()],
            clock: clock
        )

        async let games: [READMEExamples.Game] = service.execute(READMEExamples.GetGames()).games
        await clock.waitUntilSleeping()
        clock.advance(by: .seconds(1))

        #expect(try await games.isEmpty)
        #expect(await transport.recorded.count == 2)
    }
}

// MARK: - "Autenticación y refresh de token"

@Suite("README examples compile and behave — Auth / TokenRefresher")
struct READMEAuthTests {
    @Test("BearerTokenInterceptor + TokenRefreshRetrier: a 401 refreshes and retries once")
    func bearerTokenAndRefreshRetrierEndInSuccess() async throws {
        actor TokenStore {
            private(set) var currentToken = "expired"
            func save(_ token: String) { currentToken = token }
        }
        let tokenStore = TokenStore()

        let refresher = TokenRefresher {
            await tokenStore.save("fresh-token")
        }

        let transport = InMemoryTransport()
        let url = URL(string: "https://unit.test/games")!
        await transport.register(
            InMemoryTransport.Exchange(
                url: url,
                responses: [.response(status: 401), .response(status: 200, body: #"{"games":[]}"#.data(using: .utf8)!)]
            )
        )
        let clock = ManualClock()
        let service = APIService(
            configuration: NetworkingConfiguration(baseURL: URL(string: "https://unit.test")!),
            transport: transport,
            interceptors: [BearerTokenInterceptor { await tokenStore.currentToken }],
            retriers: [TokenRefreshRetrier(refresher: refresher)],
            clock: clock
        )

        async let games: [READMEExamples.Game] = service.execute(READMEExamples.GetGames()).games
        await clock.waitUntilSleeping()
        clock.advance(by: .seconds(1))

        #expect(try await games.isEmpty)
        let recorded = await transport.recorded
        #expect(recorded.count == 2)
        #expect(recorded.last?.value(forHTTPHeaderField: "Authorization") == "Bearer fresh-token")
    }
}

// MARK: - "MockAPIService" — stubs by request type

@Suite("README examples compile and behave — MockAPIService")
struct READMEMockAPIServiceTests {
    @Test("Stubs are looked up by request type, never confused with another request")
    func stubsAreTypedByRequest() async throws {
        let mock = MockAPIService()
        mock.stub(READMEExamples.GetGames.self, returning: READMEExamples.GetGames.Response(games: [.init(id: 1)]))
        mock.stub(READMEExamples.DeleteGame.self, throwing: .stub(code: .httpStatus, statusCode: 404))

        let games = try await mock.execute(READMEExamples.GetGames())
        #expect(games.games == [READMEExamples.Game(id: 1)])

        await #expect(throws: APIError.self) {
            try await mock.execute(READMEExamples.DeleteGame(id: "1"))
        }
    }
}
