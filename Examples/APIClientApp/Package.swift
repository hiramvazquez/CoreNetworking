// swift-tools-version: 6.2
import PackageDescription

// APIClientApp — consumidor mínimo de CoreNetworking, sin AppFoundation: la prueba de que
// el paquete se adopta solo, sin el kit de arquitectura del paquete hermano.
let swiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault")
]

let package = Package(
    name: "APIClientApp",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "APIClientApp",
            targets: ["APIClientApp"]
        )
    ],
    dependencies: [
        // Solo en este monorepo: `path:` al paquete hermano. Un consumidor real usa:
        //   .package(url: "https://github.com/hiram0816/spm-pro.git", from: "1.0.0"),
        .package(path: "../..")
    ],
    targets: [
        .target(
            name: "APIClientApp",
            dependencies: [
                .product(name: "CoreNetworking", package: "CoreNetworking")
            ],
            path: "Sources/APIClientApp",
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "APIClientAppTests",
            dependencies: [
                "APIClientApp",
                .product(name: "CoreNetworkingTestSupport", package: "CoreNetworking")
            ],
            path: "Tests/APIClientAppTests",
            swiftSettings: swiftSettings
        )
    ]
)
