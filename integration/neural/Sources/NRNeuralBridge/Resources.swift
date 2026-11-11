import Foundation
import NRNeuralABI

enum NeuralResources {
    static var directory: URL? {
        guard let path = NRNeuralImagePath() else { return nil }
        return URL(fileURLWithPath: String(cString: path)).deletingLastPathComponent()
    }
    static var bundle: Bundle? {
        directory.flatMap { Bundle(url: $0.appendingPathComponent("NRNeuralBridgeResources.bundle")) }
    }
    static func validate() throws {
        guard let directory,
              FileManager.default.fileExists(atPath: directory.appendingPathComponent("mlx.metallib").path),
              bundle?.url(forResource: "Shaders", withExtension: "metal") != nil else {
            throw PortError.message("Neural resources are missing beside libNRNeuralBridge.dylib (mlx.metallib and NRNeuralBridgeResources.bundle).")
        }
    }
}

// The exact upstream MetalFrames.swift references Bundle.module. Supplying this
// accessor avoids SwiftPM's absolute build-directory fallback and Bundle.main,
// which belongs to Cyberpunk when the library is injected. No upstream edits.
extension Bundle {
    static var module: Bundle { NeuralResources.bundle ?? .main }
}
