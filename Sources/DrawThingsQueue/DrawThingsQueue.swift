//
//  DrawThingsQueue.swift
//  DrawThingsQueue
//
//  Created by Brian Cantin on 2026-03-14.
//

import Foundation
import Combine
import DrawThingsClient

#if os(macOS)
import AppKit
#else
import UIKit
#endif

// MARK: - GenerationRequest

public struct GenerationRequest: Identifiable {
    public let id: UUID
    public let prompt: String
    public let negativePrompt: String
    public let configuration: DrawThingsConfiguration
    public let image: PlatformImage?
    public let mask: PlatformImage?
    public let hints: [HintProto]
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        prompt: String,
        negativePrompt: String = "",
        configuration: DrawThingsConfiguration = DrawThingsConfiguration(),
        image: PlatformImage? = nil,
        mask: PlatformImage? = nil,
        hints: [HintProto] = []
    ) {
        self.id = id
        self.prompt = prompt
        self.negativePrompt = negativePrompt
        self.configuration = configuration
        self.image = image
        self.mask = mask
        self.hints = hints
        self.createdAt = Date()
    }
}

// MARK: - GenerationResult

public struct GenerationResult: Identifiable {
    public let id: UUID
    public let images: [PlatformImage]
    public let request: GenerationRequest
    public let completedAt: Date
}

// MARK: - GenerationError

public struct GenerationError: Error, Identifiable {
    public let id: UUID
    public let request: GenerationRequest
    public let underlyingError: Error
    public let occurredAt: Date
}

// MARK: - RequestStatus

public enum RequestStatus {
    case pending(position: Int)
    case generating
    case completed(GenerationResult)
    case failed(GenerationError)
    case cancelled
}

// MARK: - GenerationProgress

@MainActor
public class GenerationProgress: ObservableObject {
    @Published public var stage: GenerationStage = .textEncoding
    @Published public var previewImage: PlatformImage?

    public init() {}
}

// MARK: - DrawThingsQueue

@MainActor
public class DrawThingsQueue: ObservableObject {

    // MARK: Published State

    @Published public private(set) var pendingRequests: [GenerationRequest] = []
    @Published public private(set) var currentRequest: GenerationRequest?
    @Published public private(set) var currentProgress: GenerationProgress?
    @Published public private(set) var isProcessing: Bool = false
    @Published public private(set) var completedResults: [GenerationResult] = []
    @Published public private(set) var errors: [GenerationError] = []

    // MARK: Configuration

    public var maxCompletedResults: Int = 50

    // MARK: Results AsyncStream

    public var results: AsyncStream<GenerationResult> {
        AsyncStream { continuation in
            let id = nextStreamID
            nextStreamID += 1
            resultContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.resultContinuations.removeValue(forKey: id)
                }
            }
        }
    }

    // MARK: Private

    private let service: DrawThingsService
    private var processingTask: Task<Void, Never>?
    private var currentGenerationTask: Task<[Data], Error>?
    private var currentRequestCancelled = false
    private var resultsByID: [UUID: GenerationResult] = [:]
    private var errorsByID: [UUID: GenerationError] = [:]
    private var cancelledIDs: Set<UUID> = []
    private var signalContinuation: AsyncStream<Void>.Continuation?
    private var resultContinuations: [Int: AsyncStream<GenerationResult>.Continuation] = [:]
    private var nextStreamID: Int = 0

    // MARK: Init

    public init(address: String, useTLS: Bool = true) throws {
        self.service = try DrawThingsService(address: address, useTLS: useTLS)
    }

    deinit {
        processingTask?.cancel()
        signalContinuation?.finish()
        for (_, continuation) in resultContinuations {
            continuation.finish()
        }
    }

    // MARK: Enqueue

    @discardableResult
    public func enqueue(
        prompt: String,
        negativePrompt: String = "",
        configuration: DrawThingsConfiguration = DrawThingsConfiguration(),
        image: PlatformImage? = nil,
        mask: PlatformImage? = nil,
        hints: [HintProto] = []
    ) -> GenerationRequest {
        let request = GenerationRequest(
            prompt: prompt,
            negativePrompt: negativePrompt,
            configuration: configuration,
            image: image,
            mask: mask,
            hints: hints
        )
        pendingRequests.append(request)
        ensureProcessingStarted()
        signalContinuation?.yield(())
        return request
    }

    // MARK: Result Retrieval

    public func result(for id: UUID) -> GenerationResult? {
        resultsByID[id]
    }

    public func status(for id: UUID) -> RequestStatus? {
        if cancelledIDs.contains(id) {
            return .cancelled
        }
        if let current = currentRequest, current.id == id {
            return .generating
        }
        if let index = pendingRequests.firstIndex(where: { $0.id == id }) {
            return .pending(position: index)
        }
        if let result = resultsByID[id] {
            return .completed(result)
        }
        if let error = errorsByID[id] {
            return .failed(error)
        }
        return nil
    }

    // MARK: Cancellation

    @discardableResult
    public func cancel(id: UUID) -> Bool {
        if let index = pendingRequests.firstIndex(where: { $0.id == id }) {
            pendingRequests.remove(at: index)
            cancelledIDs.insert(id)
            return true
        }
        if let current = currentRequest, current.id == id {
            currentRequestCancelled = true
            currentGenerationTask?.cancel()
            return true
        }
        return false
    }

    public func cancelAll() {
        for request in pendingRequests {
            cancelledIDs.insert(request.id)
        }
        pendingRequests.removeAll()
        if let current = currentRequest {
            cancelledIDs.insert(current.id)
            currentRequestCancelled = true
            currentGenerationTask?.cancel()
        }
    }

    // MARK: Housekeeping

    public func clearCompleted() {
        completedResults.removeAll()
        resultsByID.removeAll()
    }

    public func clearErrors() {
        errors.removeAll()
        errorsByID.removeAll()
    }

    // MARK: Processing Loop

    private func ensureProcessingStarted() {
        guard processingTask == nil else { return }

        let signal = AsyncStream<Void> { continuation in
            self.signalContinuation = continuation
        }

        processingTask = Task { [weak self] in
            for await _ in signal {
                guard let self else { return }
                await self.processQueue()
            }
        }
    }

    private func processQueue() async {
        while !pendingRequests.isEmpty {
            guard !Task.isCancelled else { return }

            let request = pendingRequests.removeFirst()

            if cancelledIDs.contains(request.id) {
                continue
            }

            currentRequest = request
            currentProgress = GenerationProgress()
            isProcessing = true
            currentRequestCancelled = false

            do {
                let configData = try request.configuration.toFlatBufferData()

                let imageData: Data? = if let image = request.image {
                    try ImageHelpers.imageToDTTensor(image, forceRGB: true)
                } else {
                    nil
                }

                let maskData: Data? = if let mask = request.mask {
                    try ImageHelpers.imageToDTTensor(mask, forceRGB: true)
                } else {
                    nil
                }

                let generationTask = Task<[Data], Error> {
                    try await self.service.generateImage(
                        prompt: request.prompt,
                        negativePrompt: request.negativePrompt,
                        configuration: configData,
                        image: imageData,
                        mask: maskData,
                        hints: request.hints,
                        progressHandler: { [weak self] signpost in
                            await MainActor.run {
                                self?.updateProgress(signpost)
                            }
                        },
                        previewHandler: { [weak self] previewData in
                            await MainActor.run {
                                self?.updatePreview(previewData)
                            }
                        }
                    )
                }

                currentGenerationTask = generationTask
                let resultData = try await generationTask.value
                currentGenerationTask = nil

                if currentRequestCancelled {
                    cancelledIDs.insert(request.id)
                } else {
                    let images = try resultData.map { try ImageHelpers.dtTensorToImage($0) }
                    let result = GenerationResult(
                        id: request.id,
                        images: images,
                        request: request,
                        completedAt: Date()
                    )

                    completedResults.append(result)
                    resultsByID[result.id] = result
                    trimCompletedResults()

                    for (_, continuation) in resultContinuations {
                        continuation.yield(result)
                    }
                }

            } catch is CancellationError {
                cancelledIDs.insert(request.id)
            } catch {
                if !currentRequestCancelled {
                    let genError = GenerationError(
                        id: request.id,
                        request: request,
                        underlyingError: error,
                        occurredAt: Date()
                    )
                    errors.append(genError)
                    errorsByID[genError.id] = genError
                } else {
                    cancelledIDs.insert(request.id)
                }
            }

            currentRequest = nil
            currentProgress = nil
            currentGenerationTask = nil
            isProcessing = pendingRequests.isEmpty ? false : true
        }

        isProcessing = false
    }

    // MARK: Progress Updates

    private func updateProgress(_ signpost: ImageGenerationSignpostProto?) {
        guard let signpost = signpost, let progress = currentProgress else { return }

        switch signpost.signpost {
        case .textEncoded:
            progress.stage = .textEncoding
        case .imageEncoded:
            progress.stage = .imageEncoding
        case .sampling(let sampling):
            progress.stage = .sampling(step: Int(sampling.step))
        case .imageDecoded:
            progress.stage = .imageDecoding
        case .secondPassImageEncoded:
            progress.stage = .secondPassImageEncoding
        case .secondPassSampling(let sampling):
            progress.stage = .secondPassSampling(step: Int(sampling.step))
        case .secondPassImageDecoded:
            progress.stage = .secondPassImageDecoding
        case .faceRestored:
            progress.stage = .faceRestoration
        case .imageUpscaled:
            progress.stage = .imageUpscaling
        default:
            break
        }
    }

    private func updatePreview(_ previewData: Data) {
        guard let progress = currentProgress else { return }
        if let image = try? ImageHelpers.dtTensorToImage(previewData) {
            progress.previewImage = image
        }
    }

    private func trimCompletedResults() {
        while completedResults.count > maxCompletedResults {
            let removed = completedResults.removeFirst()
            resultsByID.removeValue(forKey: removed.id)
        }
    }
}
