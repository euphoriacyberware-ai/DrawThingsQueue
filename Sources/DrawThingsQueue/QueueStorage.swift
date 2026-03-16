//
//  QueueStorage.swift
//  DrawThingsQueue
//
//  Created by Brian Cantin on 2026-03-16.
//

import Foundation
import DrawThingsClient

// MARK: - QueueStorage

public final class QueueStorage: Sendable {
    public let storageLocation: URL

    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.storageLocation = fileURL
        } else {
            let appSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first!
            let dir = appSupport.appendingPathComponent("DrawThingsQueue", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.storageLocation = dir.appendingPathComponent("queue.json")
        }
    }

    public var exists: Bool {
        FileManager.default.fileExists(atPath: storageLocation.path)
    }

    public var fileSize: Int64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: storageLocation.path) else {
            return nil
        }
        return attrs[.size] as? Int64
    }

    public func saveRequests(_ requests: [GenerationRequest]) {
        let persistable = requests.map { PersistableRequest(from: $0) }
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(persistable)
            try data.write(to: storageLocation, options: .atomic)
        } catch {
            // Silently fail - persistence is best-effort
        }
    }

    public func loadRequests() -> [GenerationRequest] {
        guard exists else { return [] }
        do {
            let data = try Data(contentsOf: storageLocation)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let persistable = try decoder.decode([PersistableRequest].self, from: data)
            return persistable.compactMap { $0.toGenerationRequest() }
        } catch {
            return []
        }
    }

    public func clearStorage() {
        try? FileManager.default.removeItem(at: storageLocation)
    }
}

// MARK: - PersistableRequest

struct PersistableRequest: Codable {
    let id: UUID
    let prompt: String
    let negativePrompt: String
    let name: String
    let createdAt: Date
    let configuration: PersistableConfiguration
    // Images and hints are not persisted - they contain large binary data
    // that doesn't serialize well to JSON. Requests restored from disk
    // will have nil images and empty hints.

    init(from request: GenerationRequest) {
        self.id = request.id
        self.prompt = request.prompt
        self.negativePrompt = request.negativePrompt
        self.name = request.name
        self.createdAt = request.createdAt
        self.configuration = PersistableConfiguration(from: request.configuration)
    }

    func toGenerationRequest() -> GenerationRequest {
        GenerationRequest(
            id: id,
            prompt: prompt,
            negativePrompt: negativePrompt,
            configuration: configuration.toDrawThingsConfiguration(),
            name: name
        )
    }
}

// MARK: - PersistableConfiguration

struct PersistableConfiguration: Codable {
    // Core
    var width: Int32
    var height: Int32
    var steps: Int32
    var model: String
    var sampler: Int8
    var guidanceScale: Float
    var seed: Int64?
    var clipSkip: Int32
    var shift: Float

    // Batch
    var batchCount: Int32
    var batchSize: Int32
    var strength: Float

    // Guidance
    var imageGuidanceScale: Float
    var clipWeight: Float
    var guidanceEmbed: Float
    var speedUpWithGuidanceEmbed: Bool
    var cfgZeroStar: Bool
    var cfgZeroInitSteps: Int32

    // Compression
    var compressionArtifacts: Int8
    var compressionArtifactsQuality: Float

    // Mask/Inpaint
    var maskBlur: Float
    var maskBlurOutset: Int32
    var preserveOriginalAfterInpaint: Bool
    var enableInpainting: Bool

    // Quality
    var sharpness: Float
    var stochasticSamplingGamma: Float
    var aestheticScore: Float
    var negativeAestheticScore: Float

    // Image prior
    var negativePromptForImagePrior: Bool
    var imagePriorSteps: Int32

    // Crop/Size
    var cropTop: Int32
    var cropLeft: Int32
    var originalImageHeight: Int32
    var originalImageWidth: Int32
    var targetImageHeight: Int32
    var targetImageWidth: Int32
    var negativeOriginalImageHeight: Int32
    var negativeOriginalImageWidth: Int32

    // Upscaler
    var upscalerScaleFactor: Int32

    // Text encoder
    var resolutionDependentShift: Bool
    var t5TextEncoder: Bool
    var separateClipL: Bool
    var separateOpenClipG: Bool
    var separateT5: Bool

    // Tiled
    var tiledDiffusion: Bool
    var diffusionTileWidth: Int32
    var diffusionTileHeight: Int32
    var diffusionTileOverlap: Int32
    var tiledDecoding: Bool
    var decodingTileWidth: Int32
    var decodingTileHeight: Int32
    var decodingTileOverlap: Int32

    // HiRes Fix
    var hiresFix: Bool
    var hiresFixWidth: Int32
    var hiresFixHeight: Int32
    var hiresFixStrength: Float

    // Stage 2
    var stage2Steps: Int32
    var stage2Guidance: Float
    var stage2Shift: Float

    // TEA Cache
    var teaCache: Bool
    var teaCacheStart: Int32
    var teaCacheEnd: Int32
    var teaCacheThreshold: Float
    var teaCacheMaxSkipSteps: Int32

    // Causal inference
    var causalInferenceEnabled: Bool
    var causalInference: Int32
    var causalInferencePad: Int32

    // Video
    var fps: Int32
    var motionScale: Int32
    var guidingFrameNoise: Float
    var startFrameGuidance: Float
    var numFrames: Int32

    // Refiner
    var refinerModel: String?
    var refinerStart: Float
    var zeroNegativePrompt: Bool

    // Other
    var upscaler: String?
    var faceRestoration: String?
    var configName: String?
    var clipLText: String?
    var openClipGText: String?
    var t5Text: String?
    var seedMode: Int32

    // LoRAs and Controls
    var loras: [PersistableLoRA]
    var controls: [PersistableControl]

    init(from config: DrawThingsConfiguration) {
        self.width = config.width
        self.height = config.height
        self.steps = config.steps
        self.model = config.model
        self.sampler = config.sampler.rawValue
        self.guidanceScale = config.guidanceScale
        self.seed = config.seed
        self.clipSkip = config.clipSkip
        self.shift = config.shift
        self.batchCount = config.batchCount
        self.batchSize = config.batchSize
        self.strength = config.strength
        self.imageGuidanceScale = config.imageGuidanceScale
        self.clipWeight = config.clipWeight
        self.guidanceEmbed = config.guidanceEmbed
        self.speedUpWithGuidanceEmbed = config.speedUpWithGuidanceEmbed
        self.cfgZeroStar = config.cfgZeroStar
        self.cfgZeroInitSteps = config.cfgZeroInitSteps
        self.compressionArtifacts = config.compressionArtifacts.rawValue
        self.compressionArtifactsQuality = config.compressionArtifactsQuality
        self.maskBlur = config.maskBlur
        self.maskBlurOutset = config.maskBlurOutset
        self.preserveOriginalAfterInpaint = config.preserveOriginalAfterInpaint
        self.enableInpainting = config.enableInpainting
        self.sharpness = config.sharpness
        self.stochasticSamplingGamma = config.stochasticSamplingGamma
        self.aestheticScore = config.aestheticScore
        self.negativeAestheticScore = config.negativeAestheticScore
        self.negativePromptForImagePrior = config.negativePromptForImagePrior
        self.imagePriorSteps = config.imagePriorSteps
        self.cropTop = config.cropTop
        self.cropLeft = config.cropLeft
        self.originalImageHeight = config.originalImageHeight
        self.originalImageWidth = config.originalImageWidth
        self.targetImageHeight = config.targetImageHeight
        self.targetImageWidth = config.targetImageWidth
        self.negativeOriginalImageHeight = config.negativeOriginalImageHeight
        self.negativeOriginalImageWidth = config.negativeOriginalImageWidth
        self.upscalerScaleFactor = config.upscalerScaleFactor
        self.resolutionDependentShift = config.resolutionDependentShift
        self.t5TextEncoder = config.t5TextEncoder
        self.separateClipL = config.separateClipL
        self.separateOpenClipG = config.separateOpenClipG
        self.separateT5 = config.separateT5
        self.tiledDiffusion = config.tiledDiffusion
        self.diffusionTileWidth = config.diffusionTileWidth
        self.diffusionTileHeight = config.diffusionTileHeight
        self.diffusionTileOverlap = config.diffusionTileOverlap
        self.tiledDecoding = config.tiledDecoding
        self.decodingTileWidth = config.decodingTileWidth
        self.decodingTileHeight = config.decodingTileHeight
        self.decodingTileOverlap = config.decodingTileOverlap
        self.hiresFix = config.hiresFix
        self.hiresFixWidth = config.hiresFixWidth
        self.hiresFixHeight = config.hiresFixHeight
        self.hiresFixStrength = config.hiresFixStrength
        self.stage2Steps = config.stage2Steps
        self.stage2Guidance = config.stage2Guidance
        self.stage2Shift = config.stage2Shift
        self.teaCache = config.teaCache
        self.teaCacheStart = config.teaCacheStart
        self.teaCacheEnd = config.teaCacheEnd
        self.teaCacheThreshold = config.teaCacheThreshold
        self.teaCacheMaxSkipSteps = config.teaCacheMaxSkipSteps
        self.causalInferenceEnabled = config.causalInferenceEnabled
        self.causalInference = config.causalInference
        self.causalInferencePad = config.causalInferencePad
        self.fps = config.fps
        self.motionScale = config.motionScale
        self.guidingFrameNoise = config.guidingFrameNoise
        self.startFrameGuidance = config.startFrameGuidance
        self.numFrames = config.numFrames
        self.refinerModel = config.refinerModel
        self.refinerStart = config.refinerStart
        self.zeroNegativePrompt = config.zeroNegativePrompt
        self.upscaler = config.upscaler
        self.faceRestoration = config.faceRestoration
        self.configName = config.name
        self.clipLText = config.clipLText
        self.openClipGText = config.openClipGText
        self.t5Text = config.t5Text
        self.seedMode = config.seedMode
        self.loras = config.loras.map { PersistableLoRA(from: $0) }
        self.controls = config.controls.map { PersistableControl(from: $0) }
    }

    func toDrawThingsConfiguration() -> DrawThingsConfiguration {
        DrawThingsConfiguration(
            width: width,
            height: height,
            steps: steps,
            model: model,
            sampler: SamplerType(rawValue: sampler) ?? .dpmpp2mkarras,
            guidanceScale: guidanceScale,
            seed: seed,
            clipSkip: clipSkip,
            loras: loras.map { $0.toLoRAConfig() },
            controls: controls.map { $0.toControlConfig() },
            shift: shift,
            batchCount: batchCount,
            batchSize: batchSize,
            strength: strength,
            imageGuidanceScale: imageGuidanceScale,
            clipWeight: clipWeight,
            guidanceEmbed: guidanceEmbed,
            speedUpWithGuidanceEmbed: speedUpWithGuidanceEmbed,
            cfgZeroStar: cfgZeroStar,
            cfgZeroInitSteps: cfgZeroInitSteps,
            compressionArtifacts: CompressionMethod(rawValue: compressionArtifacts) ?? .disabled,
            compressionArtifactsQuality: compressionArtifactsQuality,
            maskBlur: maskBlur,
            maskBlurOutset: maskBlurOutset,
            preserveOriginalAfterInpaint: preserveOriginalAfterInpaint,
            enableInpainting: enableInpainting,
            sharpness: sharpness,
            stochasticSamplingGamma: stochasticSamplingGamma,
            aestheticScore: aestheticScore,
            negativeAestheticScore: negativeAestheticScore,
            negativePromptForImagePrior: negativePromptForImagePrior,
            imagePriorSteps: imagePriorSteps,
            cropTop: cropTop,
            cropLeft: cropLeft,
            originalImageHeight: originalImageHeight,
            originalImageWidth: originalImageWidth,
            targetImageHeight: targetImageHeight,
            targetImageWidth: targetImageWidth,
            negativeOriginalImageHeight: negativeOriginalImageHeight,
            negativeOriginalImageWidth: negativeOriginalImageWidth,
            upscalerScaleFactor: upscalerScaleFactor,
            resolutionDependentShift: resolutionDependentShift,
            t5TextEncoder: t5TextEncoder,
            separateClipL: separateClipL,
            separateOpenClipG: separateOpenClipG,
            separateT5: separateT5,
            tiledDiffusion: tiledDiffusion,
            diffusionTileWidth: diffusionTileWidth,
            diffusionTileHeight: diffusionTileHeight,
            diffusionTileOverlap: diffusionTileOverlap,
            tiledDecoding: tiledDecoding,
            decodingTileWidth: decodingTileWidth,
            decodingTileHeight: decodingTileHeight,
            decodingTileOverlap: decodingTileOverlap,
            hiresFix: hiresFix,
            hiresFixWidth: hiresFixWidth,
            hiresFixHeight: hiresFixHeight,
            hiresFixStrength: hiresFixStrength,
            stage2Steps: stage2Steps,
            stage2Guidance: stage2Guidance,
            stage2Shift: stage2Shift,
            teaCache: teaCache,
            teaCacheStart: teaCacheStart,
            teaCacheEnd: teaCacheEnd,
            teaCacheThreshold: teaCacheThreshold,
            teaCacheMaxSkipSteps: teaCacheMaxSkipSteps,
            causalInferenceEnabled: causalInferenceEnabled,
            causalInference: causalInference,
            causalInferencePad: causalInferencePad,
            fps: fps,
            motionScale: motionScale,
            guidingFrameNoise: guidingFrameNoise,
            startFrameGuidance: startFrameGuidance,
            numFrames: numFrames,
            refinerModel: refinerModel,
            refinerStart: refinerStart,
            zeroNegativePrompt: zeroNegativePrompt,
            upscaler: upscaler,
            faceRestoration: faceRestoration,
            name: configName,
            clipLText: clipLText,
            openClipGText: openClipGText,
            t5Text: t5Text,
            seedMode: seedMode
        )
    }
}

// MARK: - PersistableLoRA

struct PersistableLoRA: Codable {
    let file: String
    let weight: Float
    let mode: Int8

    init(from lora: LoRAConfig) {
        self.file = lora.file
        self.weight = lora.weight
        self.mode = lora.mode.rawValue
    }

    func toLoRAConfig() -> LoRAConfig {
        LoRAConfig(
            file: file,
            weight: weight,
            mode: LoRAMode(rawValue: mode) ?? .all
        )
    }
}

// MARK: - PersistableControl

struct PersistableControl: Codable {
    let file: String
    let weight: Float
    let guidanceStart: Float
    let guidanceEnd: Float
    let controlMode: Int8

    init(from control: ControlConfig) {
        self.file = control.file
        self.weight = control.weight
        self.guidanceStart = control.guidanceStart
        self.guidanceEnd = control.guidanceEnd
        self.controlMode = control.controlMode.rawValue
    }

    func toControlConfig() -> ControlConfig {
        ControlConfig(
            file: file,
            weight: weight,
            guidanceStart: guidanceStart,
            guidanceEnd: guidanceEnd,
            controlMode: ControlMode(rawValue: controlMode) ?? .balanced
        )
    }
}
