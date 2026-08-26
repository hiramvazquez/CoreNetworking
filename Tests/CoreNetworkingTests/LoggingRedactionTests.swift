import Testing
import Foundation
@testable import CoreNetworking

@Suite("Logging: redacción de headers sensibles")
struct LoggingRedactionTests {
    @Test("Authorization/Cookie/Set-Cookie/api keys se redactan SIEMPRE, case-insensitive")
    func sensitiveHeadersAreRedacted() {
        let headers = [
            "Authorization": "Bearer secret-token",
            "authorization": "Bearer secret-token",
            "Cookie": "session=abc",
            "Set-Cookie": "session=abc",
            "X-API-Key": "sk-123",
            "Api-Key": "sk-123",
            "X-Auth-Token": "tok",
            "Proxy-Authorization": "Basic xyz",
            "My-Client-Secret": "shh"
        ]

        let redacted = HeaderRedactor.redact(headers)

        for (key, _) in headers {
            #expect(redacted[key] == "<redacted>", "el header \(key) debía redactarse")
        }
    }

    @Test("headers no sensibles pasan intactos")
    func benignHeadersPassThrough() {
        let headers = [
            "Content-Type": "application/json",
            "Accept": "application/json",
            "Keep-Alive": "timeout=5",
            "X-App-Version": "1.0"
        ]
        #expect(HeaderRedactor.redact(headers) == headers)
    }

    @Test("no existe configuración para des-redactar")
    func redactionIsNotConfigurable() {
        // La firma es estática y sin flags: si esto compila, no hay opt-out.
        let _: ([String: String]) -> [String: String] = HeaderRedactor.redact
    }
}
