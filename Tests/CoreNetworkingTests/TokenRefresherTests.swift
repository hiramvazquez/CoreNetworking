import Testing
import Foundation
@testable import CoreNetworking

/// Tests del `actor TokenRefresher` en aislamiento — sin `APIService` de por
/// medio. `RetrierTests.swift` lo cubre YA integrado en el pipeline
/// (`TokenRefreshRetrier`); aquí se prueba la deduplicación en sí misma.
@Suite("TokenRefresher: deduplica refreshes concurrentes")
struct TokenRefresherTests {
    private actor Counter {
        private(set) var value = 0
        func increment() { value += 1 }
    }

    @Test("10 llamadas concurrentes ejecutan `refresh` UNA sola vez")
    func dedupesConcurrentCalls() async throws {
        let counter = Counter()
        let refresher = TokenRefresher {
            await counter.increment()
            // Latencia simulada: da tiempo a que las otras 9 llamadas
            // lleguen y encuentren `inFlight` ya activo antes de que este
            // refresh termine — sin esto el test podría "pasar" sin probar
            // realmente la deduplicación bajo solape.
            try await Task.sleep(for: .milliseconds(20))
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask { try await refresher.refreshToken() }
            }
            try await group.waitForAll()
        }

        #expect(await counter.value == 1)
    }

    @Test("tras completar, la siguiente llamada dispara un refresh NUEVO")
    func refreshesAgainAfterCompletion() async throws {
        let counter = Counter()
        let refresher = TokenRefresher { await counter.increment() }

        try await refresher.refreshToken()
        try await refresher.refreshToken()

        #expect(await counter.value == 2, "un refresh completado no debe seguir 'en vuelo' para la siguiente llamada")
    }

    @Test("un refresh que falla se propaga a todos los que esperaban, y no deja el estado bloqueado")
    func failurePropagatesToAllWaitersAndClearsState() async throws {
        struct RefreshError: Error {}
        let counter = Counter()
        let refresher = TokenRefresher {
            await counter.increment()
            throw RefreshError()
        }

        await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<5 {
                group.addTask {
                    do {
                        try await refresher.refreshToken()
                        return false
                    } catch is RefreshError {
                        return true
                    } catch {
                        return false
                    }
                }
            }
            for await gotExpectedError in group {
                #expect(gotExpectedError, "cada llamador debe recibir el MISMO error del refresh en vuelo")
            }
        }
        #expect(await counter.value == 1, "5 llamadas concurrentes deduplican el refresh fallido en UNA sola ejecución")

        // El `defer` limpia `inFlight` tanto en éxito como en fallo: la
        // siguiente llamada dispara un refresh nuevo, no se queda esperando
        // uno que ya terminó (en error).
        await #expect(throws: RefreshError.self) {
            try await refresher.refreshToken()
        }
        #expect(await counter.value == 2)
    }
}
