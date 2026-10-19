// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "HappierKit",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "HappierKit", targets: ["HappierKit"]),
    ],
    dependencies: [
        // NaCl box / secretbox / sign (X25519 + XSalsa20-Poly1305, Ed25519). CryptoKit covers AES-GCM and HMAC.
        .package(url: "https://github.com/jedisct1/swift-sodium.git", from: "0.9.1"),
    ],
    targets: [
        .target(
            name: "HappierKit",
            dependencies: [.product(name: "Clibsodium", package: "swift-sodium")]
        ),
        .testTarget(
            name: "HappierKitTests",
            dependencies: ["HappierKit"]
        ),
    ]
)
