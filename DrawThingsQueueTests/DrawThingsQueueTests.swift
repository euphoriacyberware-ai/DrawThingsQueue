//
//  DrawThingsQueueTests.swift
//  DrawThingsQueueTests
//
//  Created by Brian Cantin on 2026-03-14.
//

import Testing
@testable import DrawThingsQueue
import DrawThingsClient

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
}

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
