// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "NRNeuralBridge",
    platforms: [.macOS(.v26)],
    products: [.library(name: "NRNeuralBridge", type: .dynamic, targets: ["NRNeuralBridge"])],
    dependencies: [.package(path: "../../vendor/MLX-DLSS")],
    targets: [
        .target(name: "NRNeuralABI", publicHeadersPath: "include"),
        .target(name: "ScreenCore"),
        .target(name: "NRNeuralBridge", dependencies: [
            "NRNeuralABI", "ScreenCore",
            .product(name: "DLSSCore", package: "MLX-DLSS"),
            .product(name: "DLSSMLX", package: "MLX-DLSS"),
            .product(name: "DLSSMedia", package: "MLX-DLSS")
        ], linkerSettings: [.linkedFramework("MetalKit"), .linkedFramework("CoreVideo")])
    ], swiftLanguageModes: [.v5]
)
