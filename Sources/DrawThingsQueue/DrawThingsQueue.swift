//
//  DrawThingsQueue.swift
//  DrawThingsQueue
//
//  Created by Brian Cantin on 2026-03-14.
//

import Foundation
import Combine
import AVFoundation
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
    public let name: String

    public init(
        id: UUID = UUID(),
        prompt: String,
        negativePrompt: String = "",
        configuration: DrawThingsConfiguration = DrawThingsConfiguration(),
        image: PlatformImage? = nil,
        mask: PlatformImage? = nil,
        hints: [HintProto] = [],
        name: String? = nil
    ) {
        self.id = id
        self.prompt = prompt
        self.negativePrompt = negativePrompt
        self.configuration = configuration
        self.image = image
        self.mask = mask
        self.hints = hints
        self.createdAt = Date()
        self.name = name ?? Self.generateName(from: prompt)
    }

    private static func generateName(from prompt: String) -> String {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Untitled" }
        if trimmed.count <= 50 { return trimmed }
        let prefix = String(trimmed.prefix(50))
        if let lastSpace = prefix.lastIndex(of: " ") {
            return String(prefix[prefix.startIndex..<lastSpace]) + "..."
        }
        return prefix + "..."
    }
}

// MARK: - GenerationResult

public struct GenerationResult: Identifiable {
    public let id: UUID
    public let images: [PlatformImage]
    public let audioData: [Data]
    public let request: GenerationRequest
    public let startedAt: Date
    public let completedAt: Date

    public var duration: TimeInterval {
        completedAt.timeIntervalSince(startedAt)
    }
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

// MARK: - JobEvent

public enum JobEvent {
    case requestAdded(GenerationRequest)
    case requestStarted(GenerationRequest)
    case requestProgress(GenerationRequest, GenerationProgress)
    case requestCompleted(GenerationResult)
    case requestFailed(GenerationError)
    case requestCancelled(UUID)
    case requestRemoved(UUID)
}

// MARK: - GenerationProgress

@MainActor
public class GenerationProgress: ObservableObject {
    @Published public var stage: GenerationStage = .textEncoding
    @Published public var previewImage: PlatformImage?
    @Published public var currentStep: Int = 0
    @Published public var totalSteps: Int = 0

    public var progressFraction: Double {
        guard totalSteps > 0 else { return 0 }
        return Double(currentStep) / Double(totalSteps)
    }

    public var progressPercentage: Int {
        Int(progressFraction * 100)
    }

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
    @Published public private(set) var isPaused: Bool = false
    @Published public var lastError: String?

    // MARK: Configuration

    public var maxCompletedResults: Int = 50
    public var maxRetries: Int = 3

    /// Optional closure to provide a model family for accurate preview/result image conversion.
    /// The closure receives the model file name (if known) and returns a LatentModelFamily.
    public var modelFamilyProvider: ((String?) -> LatentModelFamily?)? = nil

    // MARK: Event Publisher

    public let events = PassthroughSubject<JobEvent, Never>()

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

    private var service: DrawThingsService
    public var sharedSecret: String?
    private var processingTask: Task<Void, Never>?
    private var currentGenerationTask: Task<[Data], Error>?
    private var currentRequestCancelled = false
    private var resultsByID: [UUID: GenerationResult] = [:]
    private var errorsByID: [UUID: GenerationError] = [:]
    private var cancelledIDs: Set<UUID> = []
    private var signalContinuation: AsyncStream<Void>.Continuation?
    private var resultContinuations: [Int: AsyncStream<GenerationResult>.Continuation] = [:]
    private var nextStreamID: Int = 0
    private var retryCounts: [UUID: Int] = [:]
    private var storage: QueueStorage?
    private var currentStartedAt: Date?
    private var collectedAudioData: [Data] = []

    // MARK: Init

    public init(address: String, useTLS: Bool = true, sharedSecret: String? = nil, storage: QueueStorage? = nil) throws {
        self.service = try DrawThingsService(address: address, useTLS: useTLS)
        self.sharedSecret = sharedSecret
        self.storage = storage
    }

    /// Initialize with an externally-provided DrawThingsService instance.
    public init(service: DrawThingsService, sharedSecret: String? = nil, storage: QueueStorage? = nil) {
        self.service = service
        self.sharedSecret = sharedSecret
        self.storage = storage
    }

    /// Update the connection to a new server address, e.g. when the user switches profiles.
    public func updateConnection(address: String, useTLS: Bool = true, sharedSecret: String? = nil) throws {
        self.service = try DrawThingsService(address: address, useTLS: useTLS)
        self.sharedSecret = sharedSecret
    }

    /// Update the connection to use an externally-provided service.
    public func updateConnection(service: DrawThingsService, sharedSecret: String? = nil) {
        self.service = service
        self.sharedSecret = sharedSecret
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
        hints: [HintProto] = [],
        name: String? = nil
    ) -> GenerationRequest {
        let request = GenerationRequest(
            prompt: prompt,
            negativePrompt: negativePrompt,
            configuration: configuration,
            image: image,
            mask: mask,
            hints: hints,
            name: name
        )
        enqueue(request)
        return request
    }

    public func enqueue(_ request: GenerationRequest) {
        // Auto-assign a random seed if not set, so the seed is known and reproducible
        var req = request
        let needsSeed = req.configuration.seed == nil || req.configuration.seed! < 0
        if needsSeed {
            req = GenerationRequest(
                id: req.id,
                prompt: req.prompt,
                negativePrompt: req.negativePrompt,
                configuration: {
                    var config = req.configuration
                    config.seed = Int64(UInt32.random(in: 0...UInt32.max))
                    return config
                }(),
                image: req.image,
                mask: req.mask,
                hints: req.hints,
                name: req.name
            )
        }
        pendingRequests.append(req)
        events.send(.requestAdded(req))
        persist()
        ensureProcessingStarted()
        signalContinuation?.yield(())
    }

    public func enqueue(_ requests: [GenerationRequest]) {
        for request in requests {
            pendingRequests.append(request)
            events.send(.requestAdded(request))
        }
        persist()
        ensureProcessingStarted()
        signalContinuation?.yield(())
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
            events.send(.requestCancelled(id))
            persist()
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
            events.send(.requestCancelled(request.id))
        }
        pendingRequests.removeAll()
        if let current = currentRequest {
            cancelledIDs.insert(current.id)
            currentRequestCancelled = true
            currentGenerationTask?.cancel()
        }
        persist()
    }

    // MARK: Pause / Resume

    public func pause() {
        isPaused = true
    }

    public func resume() {
        isPaused = false
        lastError = nil
        signalContinuation?.yield(())
    }

    public func pauseForReconnection(error: String) {
        lastError = error
        isPaused = true
    }

    // MARK: Retry

    public func canRetry(for requestID: UUID) -> Bool {
        guard errorsByID[requestID] != nil else { return false }
        return (retryCounts[requestID] ?? 0) < maxRetries
    }

    public func retryCount(for requestID: UUID) -> Int {
        retryCounts[requestID] ?? 0
    }

    @discardableResult
    public func retry(_ requestID: UUID) -> Bool {
        guard let genError = errorsByID[requestID],
              canRetry(for: requestID) else { return false }

        retryCounts[requestID, default: 0] += 1

        // Remove from errors
        errors.removeAll { $0.id == requestID }
        errorsByID.removeValue(forKey: requestID)

        // Re-enqueue the original request
        let request = genError.request
        pendingRequests.append(request)
        events.send(.requestAdded(request))
        persist()
        ensureProcessingStarted()
        signalContinuation?.yield(())
        return true
    }

    // MARK: Reordering

    public func moveRequests(from source: IndexSet, to destination: Int) {
        pendingRequests.move(fromOffsets: source, toOffset: destination)
        persist()
    }

    // MARK: Housekeeping

    public func clearCompleted() {
        completedResults.removeAll()
        resultsByID.removeAll()
    }

    public func clearErrors() {
        errors.removeAll()
        errorsByID.removeAll()
        retryCounts.removeAll()
    }

    public func clearAll() {
        cancelAll()
        clearCompleted()
        clearErrors()
    }

    public func remove(_ requestID: UUID) {
        if let index = pendingRequests.firstIndex(where: { $0.id == requestID }) {
            pendingRequests.remove(at: index)
            events.send(.requestRemoved(requestID))
            persist()
        } else if resultsByID[requestID] != nil {
            completedResults.removeAll { $0.id == requestID }
            resultsByID.removeValue(forKey: requestID)
            events.send(.requestRemoved(requestID))
        } else if errorsByID[requestID] != nil {
            errors.removeAll { $0.id == requestID }
            errorsByID.removeValue(forKey: requestID)
            retryCounts.removeValue(forKey: requestID)
            events.send(.requestRemoved(requestID))
        }
    }

    // MARK: Persistence

    public func loadPersistedRequests() {
        guard let storage else { return }
        let loaded = storage.loadRequests()
        for request in loaded {
            pendingRequests.append(request)
        }
        if !loaded.isEmpty {
            ensureProcessingStarted()
            signalContinuation?.yield(())
        }
    }

    private func persist() {
        storage?.saveRequests(pendingRequests)
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

            if isPaused {
                return
            }

            let request = pendingRequests.removeFirst()
            persist()

            if cancelledIDs.contains(request.id) {
                continue
            }

            currentRequest = request
            let progress = GenerationProgress()
            progress.totalSteps = Int(request.configuration.steps)
            currentProgress = progress
            isProcessing = true
            currentRequestCancelled = false
            currentStartedAt = Date()
            collectedAudioData = []

            events.send(.requestStarted(request))

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
                        sharedSecret: self.sharedSecret,
                        progressHandler: { [weak self] signpost in
                            await MainActor.run {
                                self?.updateProgress(signpost)
                            }
                        },
                        previewHandler: { [weak self] previewData in
                            await MainActor.run {
                                self?.updatePreview(previewData)
                            }
                        },
                        audioHandler: { [weak self] audioTensorData in
                            await MainActor.run {
                                do {
                                    let buffer = try AudioHelpers.ccvTensorToAudioBuffer(audioTensorData)
                                    let wavData = try AudioHelpers.audioBufferToWAVData(buffer)
                                    self?.collectedAudioData.append(wavData)
                                    print("[DrawThingsQueue] Audio collected: \(wavData.count) bytes (\(buffer.frameLength) frames, \(buffer.format.channelCount) channels)")
                                } catch {
                                    print("[DrawThingsQueue] Audio conversion failed: \(error)")
                                    print("[DrawThingsQueue] Audio tensor size: \(audioTensorData.count) bytes")
                                    // Dump first 68 bytes of header for debugging
                                    if audioTensorData.count >= 68 {
                                        let headerBytes = audioTensorData.prefix(68)
                                        let header = headerBytes.withUnsafeBytes { ptr -> [UInt32] in
                                            (0..<17).map { ptr.load(fromByteOffset: $0 * 4, as: UInt32.self) }
                                        }
                                        print("[DrawThingsQueue] Header[0] identifier: 0x\(String(header[0], radix: 16))")
                                        print("[DrawThingsQueue] Header[2] format: 0x\(String(header[2], radix: 16))")
                                        print("[DrawThingsQueue] Header[3] dataType: 0x\(String(header[3], radix: 16))")
                                        print("[DrawThingsQueue] Header[5] dim0: \(header[5])")
                                        print("[DrawThingsQueue] Header[6] height: \(header[6])")
                                        print("[DrawThingsQueue] Header[7] width: \(header[7])")
                                        print("[DrawThingsQueue] Header[8] channels: \(header[8])")
                                    }
                                }
                            }
                        }
                    )
                }

                currentGenerationTask = generationTask
                let resultData = try await generationTask.value
                currentGenerationTask = nil

                if currentRequestCancelled {
                    cancelledIDs.insert(request.id)
                    events.send(.requestCancelled(request.id))
                } else {
                    let modelFamily = modelFamilyProvider?(request.configuration.model)
                    let images = try resultData.map { try ImageHelpers.dtTensorToImage($0, modelFamily: modelFamily) }
                    let result = GenerationResult(
                        id: request.id,
                        images: images,
                        audioData: collectedAudioData,
                        request: request,
                        startedAt: currentStartedAt ?? Date(),
                        completedAt: Date()
                    )

                    completedResults.append(result)
                    resultsByID[result.id] = result
                    trimCompletedResults()

                    events.send(.requestCompleted(result))

                    for (_, continuation) in resultContinuations {
                        continuation.yield(result)
                    }
                }

            } catch is CancellationError {
                cancelledIDs.insert(request.id)
                events.send(.requestCancelled(request.id))
            } catch {
                if !currentRequestCancelled {
                    if isConnectivityError(error) {
                        // Connectivity error: re-queue and pause
                        pendingRequests.insert(request, at: 0)
                        pauseForReconnection(error: "Connection lost: \(error.localizedDescription)")
                    } else {
                        let genError = GenerationError(
                            id: request.id,
                            request: request,
                            underlyingError: error,
                            occurredAt: Date()
                        )
                        errors.append(genError)
                        errorsByID[genError.id] = genError
                        events.send(.requestFailed(genError))
                    }
                } else {
                    cancelledIDs.insert(request.id)
                    events.send(.requestCancelled(request.id))
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
            progress.currentStep = Int(sampling.step)
        case .imageDecoded:
            progress.stage = .imageDecoding
        case .secondPassImageEncoded:
            progress.stage = .secondPassImageEncoding
        case .secondPassSampling(let sampling):
            progress.stage = .secondPassSampling(step: Int(sampling.step))
            progress.currentStep = Int(sampling.step)
        case .secondPassImageDecoded:
            progress.stage = .secondPassImageDecoding
        case .faceRestored:
            progress.stage = .faceRestoration
        case .imageUpscaled:
            progress.stage = .imageUpscaling
        default:
            break
        }

        if let request = currentRequest {
            events.send(.requestProgress(request, progress))
        }
    }

    private func updatePreview(_ previewData: Data) {
        guard let progress = currentProgress else { return }
        let modelFamily = modelFamilyProvider?(currentRequest?.configuration.model)
        if let image = try? ImageHelpers.dtTensorToImage(previewData, modelFamily: modelFamily) {
            progress.previewImage = image
        }
    }

    private func trimCompletedResults() {
        while completedResults.count > maxCompletedResults {
            let removed = completedResults.removeFirst()
            resultsByID.removeValue(forKey: removed.id)
        }
    }

    private func isConnectivityError(_ error: Error) -> Bool {
        let description = error.localizedDescription.lowercased()
        return description.contains("connection") ||
               description.contains("network") ||
               description.contains("unavailable") ||
               description.contains("timeout") ||
               description.contains("refused") ||
               description.contains("reset")
    }
}
