// swift-tools-version: 6.2
import PackageDescription

// Approachable Concurrency (Swift 6.2): los upcoming features que el language mode 6
// NO subsume todavía. El resto (DisableOutwardActorInference, InferSendableFromCaptures,
// GlobalActorIsolatedTypesUsability) ya son default en modo 6.
let swiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault")
]

let package = Package(
    name: "CoreNetworking",
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
