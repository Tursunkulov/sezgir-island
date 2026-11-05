// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "SezgirIsland",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "SezgirIsland",
            path: "Sources/SezgirIsland",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("ServiceManagement"),
            ]
        )
    ]
)
