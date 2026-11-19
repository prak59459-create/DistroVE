// swift-tools-version: 5.9
// 開発・テスト用のパッケージ。iPad アプリ本体は DistroVE.swiftpm（Swift Playgrounds で開く）。
// Core（純 Swift）と Engine（AVFoundation / Core Image）を DistroKit として Linux / macOS でビルド・テストする。
// UI と App は iOS 専用のためここでは除外する。
import PackageDescription

let package = Package(
    name: "DistroKit",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "DistroKit", targets: ["DistroKit"])
    ],
    targets: [
        .target(
            name: "DistroKit",
            path: "DistroVE.swiftpm/Sources",
            exclude: ["App", "UI"]
        ),
        .testTarget(
            name: "DistroKitTests",
            dependencies: ["DistroKit"],
            path: "Tests/DistroKitTests"
        )
    ]
)
