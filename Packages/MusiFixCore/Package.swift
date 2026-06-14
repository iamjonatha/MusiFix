// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MusiFixCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MusiFixCore", targets: ["MusiFixCore"]),
        .library(name: "Persistence", targets: ["Persistence"]),
        .executable(name: "MusiFixPoc", targets: ["MusiFixPoc"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
    ],
    targets: [
        // ObjC wrapper attorno a ScriptingBridge di Music.app
        .target(
            name: "MusicBridge",
            path: "Sources/MusicBridge",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("ScriptingBridge"),
                .linkedFramework("AppKit"),
                .linkedFramework("Foundation"),
            ]
        ),

        // Persistenza: schema SQLite GRDB, migrazioni, DAO
        .target(
            name: "Persistence",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Sources/Persistence",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // Libreria Swift principale
        .target(
            name: "MusiFixCore",
            dependencies: [
                "MusicBridge",
                "Persistence",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Sources/MusiFixCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // Eseguibile PoC Fase 0
        .executableTarget(
            name: "MusiFixPoc",
            dependencies: ["MusiFixCore"],
            path: "Sources/MusiFixPoc",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        .testTarget(
            name: "MusiFixCoreTests",
            dependencies: [
                "MusiFixCore",
                "Persistence",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Tests/MusiFixCoreTests"
        ),
    ]
)
