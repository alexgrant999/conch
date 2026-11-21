// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Conch",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.99.3")
    ],
    targets: [
        .executableTarget(
            name: "Conch",
            dependencies: [.product(name: "SwiftTerm", package: "SwiftTerm")],
            path: "Sources/Conch"
        )
    ]
)
