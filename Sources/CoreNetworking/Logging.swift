import Foundation
import os

/// Loggers del paquete, por categoría. `print()` no es logging.
///
/// El subsystem cuelga del bundle de la app que consume el paquete
/// (`com.miapp.corenetworking`) para que en Console se filtre junto al resto
/// de sus logs; sin bundle (CLI, tests) queda `corenetworking`.
enum NetLog {
    static let subsystem = Bundle.main.bundleIdentifier.map { "\($0).corenetworking" } ?? "corenetworking"

    static let network = Logger(subsystem: subsystem, category: "network")
    static let retry = Logger(subsystem: subsystem, category: "retry")
    static let pinning = Logger(subsystem: subsystem, category: "pinning")
}

/// Redacción de headers sensibles para logging.
///
/// NO es configurable a propósito: no existe flag para des-redactar.
/// Sobre-redactar es seguro; filtrar una credencial no.
enum HeaderRedactor {
    private static let sensitiveHeaderNames: Set<String> = [
        "authorization",
        "proxy-authorization",
        "authentication",
        "cookie",
        "set-cookie",
        "x-api-key",
        "api-key",
        "x-auth-token"
    ]

    /// Marcadores que redactan por coincidencia parcial (case-insensitive).
    private static let sensitiveMarkers = ["token", "secret", "apikey", "api-key", "password"]

    static func redact(_ headers: [String: String]) -> [String: String] {
        headers.reduce(into: [:]) { result, header in
            let name = header.key.lowercased()
            let isSensitive = sensitiveHeaderNames.contains(name) || sensitiveMarkers.contains(where: name.contains)
            result[header.key] = isSensitive ? "<redacted>" : header.value
        }
    }
}
