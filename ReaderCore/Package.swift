// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ReaderCore",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "ReaderCore", targets: ["ReaderCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.0.0"),
        .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.6.0"),
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.16")
    ],
    targets: [
        .target(
            name: "ReaderCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "SwiftSoup", package: "SwiftSoup"),
                .product(name: "ZIPFoundation", package: "ZIPFoundation")
            ],
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "ReaderCoreTests",
            dependencies: ["ReaderCore"],
            resources: [.process("Fixtures")]
        )
    ]
)
