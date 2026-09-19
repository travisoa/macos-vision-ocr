// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "macos-vision-ocr",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "ocr", targets: ["OCR"])],
    targets: [
        .executableTarget(
            name: "OCR",
            path: ".",
            exclude: ["Tests", "script", "build", "README.md", "build.sh"],
            sources: ["ocr.swift", "Sources"]
        ),
        .testTarget(
            name: "OCRTests",
            dependencies: ["OCR"],
            path: "Tests",
            exclude: ["cli_tests.py", "run.sh", "ocr_smoke.sh", "fixtures"]
        )
    ],
    // The engine still supports macOS 13. Swift 6 concurrency migration is a
    // separate change from adopting package-based builds and native tests.
    swiftLanguageModes: [.v5]
)
