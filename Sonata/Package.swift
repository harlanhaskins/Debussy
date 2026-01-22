// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Sonata",
    platforms: [.iOS(.v26), .macOS(.v26), .visionOS(.v26)],
    products: [
        .library(name: "Sonata", targets: ["Sonata"]),
    ],
    dependencies: [
        .package(path: "../../SwiftClaude"),
        .package(url: "https://github.com/harlanhaskins/SwiftCEL.git", from: "0.1.0"),
        .package(url: "https://github.com/gonzalezreal/textual.git", from: "0.1.0"),
        .package(url: "https://github.com/apple/swift-collections", from: "1.3.0"),
    ],
    targets: [
        .target(name: "Sonata", dependencies: [
            .product(name: "SwiftClaude", package: "SwiftClaude"),
            .product(name: "SwiftCEL", package: "SwiftCEL"),
            .product(name: "Collections", package: "swift-collections"),
            .product(name: "Textual", package: "textual")
        ])
    ]
)
