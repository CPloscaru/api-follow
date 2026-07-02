// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "APIFollow",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "APIFollow", targets: ["APIFollow"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.29.0")
    ],
    targets: [
        .executableTarget(
            name: "APIFollow",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            exclude: ["Info.plist"],
            resources: [
                .copy("Resources/menubar-icon.svg")
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/APIFollow/Info.plist",
                ])
            ]
        ),
        .testTarget(
            name: "APIFollowTests",
            dependencies: ["APIFollow"]
        ),
    ]
)
