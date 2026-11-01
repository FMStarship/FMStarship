// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "FMStarship",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "CStarshipProtocol"),
        .target(name: "CA64"),
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
        .executableTarget(name: "FMStarship", dependencies: ["StarshipCore", "StarshipSearch", "StarshipAnalysis", "StarshipFiles"]),
        .executableTarget(name: "fmprobe", dependencies: ["StarshipCore", "StarshipAnalysis", "CA64"]),
        .testTarget(name: "StarshipFilesTests", dependencies: ["StarshipFiles", "StarshipCore"]),
        .testTarget(name: "StarshipAnalysisTests", dependencies: ["StarshipAnalysis", "StarshipCore"]),
    ]
)
