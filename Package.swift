// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "CleanSwitcher",
    platforms: [
        .macOS(.v12)
    ],
    targets: [
        .executableTarget(
            name: "CleanSwitcher",
            path: "Sources/CleanSwitcher",
            linkerSettings: [
                .linkedFramework("Carbon")
            ]
        )
    ]
)
