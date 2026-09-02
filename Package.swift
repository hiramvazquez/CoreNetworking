// swift-tools-version: 6.2
import PackageDescription

// Approachable Concurrency (Swift 6.2): los upcoming features que el language mode 6
// NO subsume todavía. El resto (DisableOutwardActorInference, InferSendableFromCaptures,
// GlobalActorIsolatedTypesUsability) ya son default en modo 6.
// El rigor es una propiedad de COMO SE DESARROLLA el paquete, no del artefacto que
// se publica. Xcode compila las dependencias remotas con `-suppress-warnings` (los
// warnings de una libreria de terceros no son accionables para quien la consume), y
// eso choca de frente con `-warnings-as-errors`:
//
//     error: Conflicting options '-warnings-as-errors' and '-suppress-warnings'
//
// Un paquete no debe imponer su nivel 0 a terceros. Por eso el modo estricto se
// activa por entorno: aqui dentro (y en el CI del propio paquete) esta encendido;
// para quien lo consume, ausente. Mismo patron que AppFoundation/Package.swift.
let modoEstricto = Context.environment["SWIFT_STRICT_WARNINGS"] != nil

var swiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault")
]

if modoEstricto {
    // Modo estricto (nivel 0): el compilador es el primer reviewer.
    swiftSettings.append(.treatAllWarnings(as: .error))
}

let package = Package(
    name: "CoreNetworking",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "CoreNetworking", targets: ["CoreNetworking"]),
        // Mocks y helpers de test: producto SEPARADO para que jamás viajen en
        // el binario de producción. Solo lo enlazan test targets y previews.
        .library(name: "CoreNetworkingTestSupport", targets: ["CoreNetworkingTestSupport"])
    ],
    targets: [
        .target(
            name: "CoreNetworking",
            resources: [.process("Resources")],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "CoreNetworkingTestSupport",
            dependencies: ["CoreNetworking"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "CoreNetworkingTests",
            dependencies: ["CoreNetworking", "CoreNetworkingTestSupport"],
            swiftSettings: swiftSettings
        )
    ],
    swiftLanguageModes: [.v6]
)
