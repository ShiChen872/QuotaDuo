// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "QuotaDuo",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "QuotaDuo",
            path: "Sources/QuotaDuo"
        )
    ]
)
