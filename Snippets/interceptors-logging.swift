// Un interceptor propio: el mismo RequestContext (mismo id) fluye por las tres
// llamadas de un intento — correlaciona logs sin confundir requests concurrentes.
import CoreNetworking
import Foundation

struct RequestIDInterceptor: RequestInterceptor {
    func willSend(_ request: URLRequest, context: RequestContext) async throws(APIError) -> URLRequest {
        var request = request
        request.setValue(context.id.uuidString, forHTTPHeaderField: "X-Request-ID")
        return request
    }

    func didReceive(_ response: HTTPURLResponse, data: Data, context: RequestContext) async {
        // métrica: duración = ContinuousClock.now - context.startedAt
    }

    func didFail(_ error: APIError, context: RequestContext) async {
        // métrica de fallo, correlacionada por context.id
    }
}

let configuration = NetworkingConfiguration(baseURL: URL(string: "https://api.miapp.com")!)
let service = APIService(
    configuration: configuration,
    interceptors: [RequestIDInterceptor(), LoggingInterceptor()]
)
