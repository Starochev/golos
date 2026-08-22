// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Golos",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Автообновления: тянет appcast.xml из релизов GitHub и ставит
        // новую версию, проверив подпись EdDSA.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")
    ],
    targets: [
        .executableTarget(
            name: "Golos",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/Golos",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
