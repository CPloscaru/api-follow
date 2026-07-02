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
            // Resources/menubar-icon.svg is intentionally NOT declared
            // here via SPM's `resources:` — SPM's generated Bundle.module
            // accessor looks for the resource bundle directly at the
            // .app's root (Bundle.main.bundleURL), which sits outside
            // Contents/ and broke codesign's sealing ("unsealed contents
            // present in the bundle root"). Instead, build-app.sh copies
            // the SVG straight into Contents/Resources/ (the standard
            // macOS location) and MenuBarLabelView reads it from
            // Bundle.main.resourceURL — proper bundle structure, no
            // SPM resource-bundle indirection needed for one file.
            exclude: ["Info.plist", "Resources/menubar-icon.svg"],
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
