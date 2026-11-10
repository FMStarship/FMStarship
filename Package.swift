// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "FMStarship",
    platforms: [.macOS(.v14)],
    products: [
        // FM Starship inside Football Manager, loaded through FM's Steam launch options. A preview.
        // It carries the agent too, so the app and fmprobe can still read a game started this way.
        .library(name: "StarshipPlugin", type: .dynamic, targets: ["StarshipPluginStart", "StarshipPlugin", "StarshipAgent"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
    ],
    targets: [
        .target(name: "CStarshipProtocol"),
        // FM's rules run 15-25 % faster at -O2 than at the -Os SwiftPM builds releases with. Clang takes the last -O.
        .target(name: "CA64", cSettings: [.unsafeFlags(["-O2"], .when(configuration: .release))]),
        .target(name: "StarshipCore", dependencies: ["CStarshipProtocol", "CA64"]),
        .target(name: "StarshipSearch", dependencies: ["StarshipCore"]),
        .target(name: "StarshipAnalysis", dependencies: ["StarshipCore"]),
        // The module map lives inside StarshipFiles and links nothing itself; giving the linker
        // libzstd.a by path is what keeps Homebrew out of the finished app.
        .systemLibrary(name: "CZstd", path: "Sources/StarshipFiles/CZstd"),
        .target(
            name: "StarshipFiles",
            dependencies: ["StarshipCore", "CZstd"],
            exclude: ["CZstd"],
            linkerSettings: [.unsafeFlags(["/opt/homebrew/lib/libzstd.a"])]
        ),
        // The app's screens, shared by the app and the plugin. The app adds only its entry point and Sparkle,
        // which can't load inside FM.
        .target(
            name: "FMStarshipUI",
            dependencies: ["StarshipCore", "StarshipSearch", "StarshipAnalysis", "StarshipFiles"],
            path: "Sources/FMStarship"
        ),
        .executableTarget(
            name: "FMStarship",
            dependencies: ["FMStarshipUI", "StarshipCore", .product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/FMStarshipApp",
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .executableTarget(name: "fmprobe", dependencies: ["StarshipCore", "StarshipAnalysis", "CA64"]),
        .target(name: "StarshipPluginStart"),
        .target(name: "StarshipAgent", dependencies: ["CStarshipProtocol"], path: "agent", publicHeadersPath: "."),
        .target(name: "StarshipPlugin", dependencies: ["FMStarshipUI", "StarshipCore", "StarshipAnalysis", "StarshipFiles"]),
        .testTarget(name: "StarshipCoreTests", dependencies: ["StarshipCore"]),
        .testTarget(name: "StarshipFilesTests", dependencies: ["StarshipFiles", "StarshipCore"]),
        .testTarget(name: "StarshipSearchTests", dependencies: ["StarshipSearch", "StarshipCore"]),
        .testTarget(name: "StarshipAnalysisTests", dependencies: ["StarshipAnalysis", "StarshipCore"]),
        .testTarget(name: "StarshipPluginTests", dependencies: ["StarshipPlugin", "StarshipAnalysis", "StarshipCore"]),
    ]
)
