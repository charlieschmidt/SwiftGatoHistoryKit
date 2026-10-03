// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SwiftGatoHistoryKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "SwiftGatoHistoryKit",
            targets: ["SwiftGatoHistoryKit"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/PureSwift/TLVCoding", .upToNextMajor(from: "3.0.0")),
    ],
    targets: [
        .target(
            name: "SwiftGatoHistoryKit",
            dependencies: ["TLVCoding"]
        ),
        .testTarget(
            name: "SwiftGatoHistoryKitTests",
            dependencies: ["SwiftGatoHistoryKit"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
