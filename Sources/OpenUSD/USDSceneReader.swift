import Foundation

public protocol USDSceneReader: Sendable {
    func read(from data: Data, options: USDReadingOptions) throws -> USDScene
}

public extension USDSceneReader {
    func read(from data: Data) throws -> USDScene {
        try read(from: data, options: .default)
    }
}
