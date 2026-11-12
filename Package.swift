// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "BitPolish",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Software updates (sparkle-project.org, MIT License). Pinned.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    targets: [
        // Pure logic (log parsing, rate and bit-depth choice, priming layout, file matching, formatting),
        // shared by the app and the checks.
        .target(name: "BitPolishCore", path: "Sources/BitPolishCore"),
        // The menu-bar app.
        .executableTarget(name: "BitPolish",
                          dependencies: ["BitPolishCore", .product(name: "Sparkle", package: "Sparkle")],
                          path: "Sources/BitPolish",
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        // `swift run BitPolishChecks`: checks for BitPolishCore that run with
        // only the Command Line Tools (no XCTest or Swift Testing needed).
        .executableTarget(name: "BitPolishChecks", dependencies: ["BitPolishCore"], path: "Sources/BitPolishChecks"),
    ],
    swiftLanguageModes: [.v5]
)
