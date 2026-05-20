// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Maily",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MailyCore", targets: ["MailyCore"]),
        .library(name: "MailyUI", targets: ["MailyUI"]),
        .executable(name: "MailyApp", targets: ["MailyApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.29.0"),
    ],
    targets: [
        .target(
            name: "MailyCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
        ),
        .target(
            name: "MailyUI",
            dependencies: ["MailyCore"]
        ),
        .executableTarget(
            name: "MailyApp",
            dependencies: ["MailyCore", "MailyUI"]
        ),
        .testTarget(
            name: "MailyCoreTests",
            dependencies: ["MailyCore"]
        ),
        .testTarget(
            name: "MailyUITests",
            dependencies: ["MailyUI", "MailyCore"]
        ),
    ]
)
