// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "InputMethodAutoChange",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "InputMethodAutoChange",
            path: "Sources/InputMethodAutoChange",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "InputMethodAutoChangeTests",
            dependencies: ["InputMethodAutoChange"],
            path: "Tests/InputMethodAutoChangeTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
