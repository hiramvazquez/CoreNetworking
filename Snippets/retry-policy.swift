// RetryPolicy: cuántas veces, cuánto esperar, y un predicado tipado para decidir
// qué error merece un reintento.
import CoreNetworking
import Foundation

let configuration = NetworkingConfiguration(baseURL: URL(string: "https://api.miapp.com")!)

let policy = RetryPolicy(
    maxAttempts: 3,
    initialDelay: .milliseconds(500),
    shouldRetry: { error, _ in
        // No reintentar nunca un error propio del interceptor.
        error.isRetryable && error.code != .interceptor
    }
)

let service = APIService(configuration: configuration, retryPolicy: policy)
