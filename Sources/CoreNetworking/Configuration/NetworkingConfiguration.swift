//
//  NetworkingConfiguration.swift
//  HiramNetworking
//
//  Created by Hiram on 2025-10-13.
//

import Foundation

/// Protocolo base para definir la configuración de red de la aplicación.
///
/// Cada proyecto o entorno (por ejemplo, `CatalogApp`, `AdminApp`, `PreviewApp`)
/// puede implementar su propia versión de esta configuración sin modificar el paquete `HiramNetworking`.
///
/// ## Ejemplo de implementación:
/// ```swift
/// struct CatalogNetworkingConfiguration: NetworkingConfiguration {
///     var baseURL: URL { URL(string: "https://www.freetogame.com")! }
///     var defaultHeaders: [String : String] {
///         [ "Content-Type": "application/json", "X-App-Version": "1.0" ]
///     }
///     var environment: String { "production" }
/// }
///
/// // En AppDelegate o App inicial:
/// APIConfig.shared = CatalogNetworkingConfiguration()
/// ```
public protocol NetworkingConfiguration: Sendable {
    /// URL base del backend.
    var baseURL: URL { get }
    /// Headers comunes que se envían en todas las peticiones.
    var defaultHeaders: [String: String] { get }
    /// Nombre o tipo de entorno actual (por ejemplo, "staging" o "production").
    var environment: String { get }
}

/// Contenedor global de la configuración actual de red.
///
/// Este valor puede ser modificado en tiempo de ejecución para cambiar el entorno
/// o inyectar una configuración diferente (por ejemplo, durante tests o previews).
public enum APIConfig {
    private static var _shared: NetworkingConfiguration = DefaultNetworkingConfiguration()

    /// Configuración de red compartida y accesible desde cualquier parte del SDK.
    ///
    /// Por defecto usa `DefaultNetworkingConfiguration`, pero cada app debe
    /// establecer su propia implementación en el arranque.
    public static var shared: NetworkingConfiguration {
        get { _shared }
        set { _shared = newValue }
    }
}

/// Configuración por defecto (usada como fallback si la app no define una propia).
///
/// **Importante:** los proyectos reales deben reemplazarla con su propia
/// implementación estableciendo `APIConfig.shared` en el arranque.
public struct DefaultNetworkingConfiguration: NetworkingConfiguration {
    public let baseURL: URL
    public let defaultHeaders: [String : String]
    public let environment: String

    public init() {
        guard let url = URL(string: "https://example.com") else {
            fatalError("Invalid default base URL")
        }
        self.baseURL = url
        self.defaultHeaders = [
            "Content-Type": "application/json"
        ]
        self.environment = "default"
    }
}
