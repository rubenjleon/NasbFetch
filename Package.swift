// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "NasbFetch",
    platforms: [.macOS(.v12)],
    dependencies: [
        .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.7.0")
    ],
    targets: [
        .executableTarget(
            name: "NasbFetch",
            dependencies: ["SwiftSoup"]
        ),
    ]
)
