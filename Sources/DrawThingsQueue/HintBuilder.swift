//
//  HintBuilder.swift
//  DrawThingsQueue
//
//  Created by Brian Cantin on 2026-03-16.
//

import Foundation
import DrawThingsClient

// MARK: - HintType

public enum HintType: String, CaseIterable, Sendable {
    case shuffle
    case depth
    case pose
    case canny
    case scribble
    case color
    case lineart
    case softedge
    case seg
    case inpaint
    case ip2p
    case mlsd
    case tile
    case blur
    case lowquality
    case gray
    case custom
}

// MARK: - HintData

public struct HintData: Sendable {
    public let type: String
    public let imageData: Data
    public let weight: Float

    public init(type: String, imageData: Data, weight: Float = 1.0) {
        self.type = type
        self.imageData = imageData
        self.weight = weight
    }
}

// MARK: - HintBuilder

public final class HintBuilder {
    private var hints: [HintData] = []

    public init() {}

    public var count: Int { hints.count }
    public var isEmpty: Bool { hints.isEmpty }

    // MARK: - Typed Hint Methods

    @discardableResult
    public func addMoodboardImage(_ imageData: Data, weight: Float = 1.0) -> HintBuilder {
        addHint(type: .shuffle, imageData: imageData, weight: weight)
    }

    @discardableResult
    public func addMoodboardImages(_ images: [Data], weight: Float = 1.0) -> HintBuilder {
        for imageData in images {
            addHint(type: .shuffle, imageData: imageData, weight: weight)
        }
        return self
    }

    @discardableResult
    public func addDepthMap(_ imageData: Data, weight: Float = 1.0) -> HintBuilder {
        addHint(type: .depth, imageData: imageData, weight: weight)
    }

    @discardableResult
    public func addPose(_ imageData: Data, weight: Float = 1.0) -> HintBuilder {
        addHint(type: .pose, imageData: imageData, weight: weight)
    }

    @discardableResult
    public func addCannyEdges(_ imageData: Data, weight: Float = 1.0) -> HintBuilder {
        addHint(type: .canny, imageData: imageData, weight: weight)
    }

    @discardableResult
    public func addScribble(_ imageData: Data, weight: Float = 1.0) -> HintBuilder {
        addHint(type: .scribble, imageData: imageData, weight: weight)
    }

    @discardableResult
    public func addColorReference(_ imageData: Data, weight: Float = 1.0) -> HintBuilder {
        addHint(type: .color, imageData: imageData, weight: weight)
    }

    @discardableResult
    public func addLineArt(_ imageData: Data, weight: Float = 1.0) -> HintBuilder {
        addHint(type: .lineart, imageData: imageData, weight: weight)
    }

    // MARK: - Generic Hint Methods

    @discardableResult
    public func addHint(type: HintType, imageData: Data, weight: Float = 1.0) -> HintBuilder {
        hints.append(HintData(type: type.rawValue, imageData: imageData, weight: weight))
        return self
    }

    @discardableResult
    public func addHint(type: String, imageData: Data, weight: Float = 1.0) -> HintBuilder {
        hints.append(HintData(type: type, imageData: imageData, weight: weight))
        return self
    }

    @discardableResult
    public func clear() -> HintBuilder {
        hints.removeAll()
        return self
    }

    // MARK: - Build

    public func build() -> [HintProto] {
        var hintsByType: [String: [TensorAndWeight]] = [:]

        for hint in hints {
            // Convert raw image data (PNG/JPEG) to DTTensor format for the server
            guard let image = PlatformImage(data: hint.imageData),
                  let tensorData = try? ImageHelpers.imageToDTTensor(image, forceRGB: true) else {
                continue
            }
            var tensor = TensorAndWeight()
            tensor.tensor = tensorData
            tensor.weight = hint.weight
            hintsByType[hint.type, default: []].append(tensor)
        }

        return hintsByType.map { type, tensors in
            var proto = HintProto()
            proto.hintType = type
            proto.tensors = tensors
            return proto
        }
    }
}
