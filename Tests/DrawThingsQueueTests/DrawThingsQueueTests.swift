//
//  DrawThingsQueueTests.swift
//  DrawThingsQueueTests
//
//  Created by Brian Cantin on 2026-03-14.
//

import Testing
import Foundation
@testable import DrawThingsQueue
import DrawThingsClient

// MARK: - GenerationRequest Tests

struct GenerationRequestTests {

    @Test func requestHasUniqueID() {
        let request1 = GenerationRequest(prompt: "a cat")
        let request2 = GenerationRequest(prompt: "a dog")
        #expect(request1.id != request2.id)
    }

    @Test func requestStoresPrompt() {
        let request = GenerationRequest(
            prompt: "a beautiful sunset",
            negativePrompt: "ugly"
        )
        #expect(request.prompt == "a beautiful sunset")
        #expect(request.negativePrompt == "ugly")
    }

    @Test func requestDefaultValues() {
        let request = GenerationRequest(prompt: "test")
        #expect(request.negativePrompt == "")
        #expect(request.image == nil)
        #expect(request.mask == nil)
    }

    @Test func requestAutoGeneratesName() {
        let request = GenerationRequest(prompt: "a beautiful sunset over the ocean")
        #expect(request.name == "a beautiful sunset over the ocean")
    }

    @Test func requestAutoGeneratesNameTruncated() {
        let longPrompt = "a very long prompt that exceeds the fifty character limit and should be truncated at a word boundary"
        let request = GenerationRequest(prompt: longPrompt)
        #expect(request.name.count <= 53) // 50 + "..."
        #expect(request.name.hasSuffix("..."))
    }

    @Test func requestEmptyPromptName() {
        let request = GenerationRequest(prompt: "")
        #expect(request.name == "Untitled")
    }

    @Test func requestCustomName() {
        let request = GenerationRequest(prompt: "test", name: "My Custom Name")
        #expect(request.name == "My Custom Name")
    }
}

// MARK: - RequestStatus Tests

struct RequestStatusTests {

    @Test func pendingStatusHasPosition() {
        let status = RequestStatus.pending(position: 3)
        if case .pending(let position) = status {
            #expect(position == 3)
        } else {
            Issue.record("Expected pending status")
        }
    }
}

// MARK: - GenerationProgress Tests

@MainActor
struct GenerationProgressTests {

    @Test func defaultProgress() {
        let progress = GenerationProgress()
        #expect(progress.currentStep == 0)
        #expect(progress.totalSteps == 0)
        #expect(progress.progressFraction == 0)
        #expect(progress.progressPercentage == 0)
    }

    @Test func progressFraction() {
        let progress = GenerationProgress()
        progress.totalSteps = 20
        progress.currentStep = 10
        #expect(progress.progressFraction == 0.5)
        #expect(progress.progressPercentage == 50)
    }

    @Test func progressFractionZeroTotalSteps() {
        let progress = GenerationProgress()
        progress.totalSteps = 0
        progress.currentStep = 5
        #expect(progress.progressFraction == 0)
    }
}

// MARK: - HintBuilder Tests

struct HintBuilderTests {

    @Test func emptyBuilder() {
        let builder = HintBuilder()
        #expect(builder.isEmpty)
        #expect(builder.count == 0)
        let hints = builder.build()
        #expect(hints.isEmpty)
    }

    @Test func addSingleHint() {
        let builder = HintBuilder()
        let data = Data([0x01, 0x02, 0x03])
        builder.addDepthMap(data, weight: 0.8)
        #expect(builder.count == 1)
        #expect(!builder.isEmpty)

        let hints = builder.build()
        #expect(hints.count == 1)
        #expect(hints[0].hintType == "depth")
        #expect(hints[0].tensors.count == 1)
        #expect(hints[0].tensors[0].weight == 0.8)
    }

    @Test func addMultipleHintsOfSameType() {
        let builder = HintBuilder()
        let data1 = Data([0x01])
        let data2 = Data([0x02])
        builder.addMoodboardImages([data1, data2], weight: 0.5)
        #expect(builder.count == 2)

        let hints = builder.build()
        #expect(hints.count == 1) // Grouped by type
        #expect(hints[0].hintType == "shuffle")
        #expect(hints[0].tensors.count == 2)
    }

    @Test func addMultipleHintTypes() {
        let builder = HintBuilder()
        builder
            .addDepthMap(Data([0x01]))
            .addPose(Data([0x02]))
            .addCannyEdges(Data([0x03]))
        #expect(builder.count == 3)

        let hints = builder.build()
        #expect(hints.count == 3) // Different types
    }

    @Test func clearHints() {
        let builder = HintBuilder()
        builder.addDepthMap(Data([0x01]))
        builder.clear()
        #expect(builder.isEmpty)
        #expect(builder.build().isEmpty)
    }

    @Test func customHintType() {
        let builder = HintBuilder()
        builder.addHint(type: "my_custom_hint", imageData: Data([0x01]), weight: 0.9)
        let hints = builder.build()
        #expect(hints.count == 1)
        #expect(hints[0].hintType == "my_custom_hint")
    }

    @Test func chainableAPI() {
        let hints = HintBuilder()
            .addDepthMap(Data([0x01]))
            .addPose(Data([0x02]))
            .addScribble(Data([0x03]))
            .build()
        #expect(hints.count == 3)
    }
}

// MARK: - QueueStorage Tests

struct QueueStorageTests {

    @Test func saveAndLoadRequests() {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_queue_\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let storage = QueueStorage(fileURL: tempURL)

        let config = DrawThingsConfiguration(
            width: 768,
            height: 768,
            steps: 30,
            model: "test_model.safetensors",
            guidanceScale: 8.0,
            seed: 42
        )

        let request = GenerationRequest(
            prompt: "a test prompt",
            negativePrompt: "bad quality",
            configuration: config,
            name: "Test Job"
        )

        storage.saveRequests([request])
        #expect(storage.exists)

        let loaded = storage.loadRequests()
        #expect(loaded.count == 1)
        #expect(loaded[0].id == request.id)
        #expect(loaded[0].prompt == "a test prompt")
        #expect(loaded[0].negativePrompt == "bad quality")
        #expect(loaded[0].name == "Test Job")
        #expect(loaded[0].configuration.width == 768)
        #expect(loaded[0].configuration.height == 768)
        #expect(loaded[0].configuration.steps == 30)
        #expect(loaded[0].configuration.model == "test_model.safetensors")
        #expect(loaded[0].configuration.guidanceScale == 8.0)
        #expect(loaded[0].configuration.seed == 42)
    }

    @Test func loadFromEmptyStorage() {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("nonexistent_\(UUID().uuidString).json")
        let storage = QueueStorage(fileURL: tempURL)
        #expect(!storage.exists)

        let loaded = storage.loadRequests()
        #expect(loaded.isEmpty)
    }

    @Test func clearStorage() {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_clear_\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let storage = QueueStorage(fileURL: tempURL)
        let request = GenerationRequest(prompt: "test")
        storage.saveRequests([request])
        #expect(storage.exists)

        storage.clearStorage()
        #expect(!storage.exists)
    }

    @Test func saveMultipleRequests() {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_multi_\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let storage = QueueStorage(fileURL: tempURL)

        let requests = [
            GenerationRequest(prompt: "first"),
            GenerationRequest(prompt: "second"),
            GenerationRequest(prompt: "third"),
        ]

        storage.saveRequests(requests)
        let loaded = storage.loadRequests()
        #expect(loaded.count == 3)
        #expect(loaded[0].prompt == "first")
        #expect(loaded[1].prompt == "second")
        #expect(loaded[2].prompt == "third")
    }

    @Test func persistsLoRAConfig() {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_lora_\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let storage = QueueStorage(fileURL: tempURL)
        let config = DrawThingsConfiguration(
            loras: [LoRAConfig(file: "test_lora.safetensors", weight: 0.8)]
        )
        let request = GenerationRequest(prompt: "test", configuration: config)

        storage.saveRequests([request])
        let loaded = storage.loadRequests()
        #expect(loaded[0].configuration.loras.count == 1)
        #expect(loaded[0].configuration.loras[0].file == "test_lora.safetensors")
        #expect(loaded[0].configuration.loras[0].weight == 0.8)
    }

    @Test func fileSize() {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_size_\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let storage = QueueStorage(fileURL: tempURL)
        #expect(storage.fileSize == nil)

        storage.saveRequests([GenerationRequest(prompt: "test")])
        #expect(storage.fileSize != nil)
        #expect(storage.fileSize! > 0)
    }
}

// MARK: - JobEvent Tests

struct JobEventTests {

    @Test func requestAddedEvent() {
        let request = GenerationRequest(prompt: "test")
        let event = JobEvent.requestAdded(request)
        if case .requestAdded(let r) = event {
            #expect(r.id == request.id)
        } else {
            Issue.record("Expected requestAdded event")
        }
    }

    @Test func requestCancelledEvent() {
        let id = UUID()
        let event = JobEvent.requestCancelled(id)
        if case .requestCancelled(let cancelledID) = event {
            #expect(cancelledID == id)
        } else {
            Issue.record("Expected requestCancelled event")
        }
    }
}
