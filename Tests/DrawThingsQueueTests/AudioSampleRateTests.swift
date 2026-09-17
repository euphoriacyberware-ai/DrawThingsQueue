//
//  AudioSampleRateTests.swift
//  DrawThingsQueueTests
//

import Testing
@testable import DrawThingsQueue

@Suite("Audio sample rate heuristic")
struct AudioSampleRateTests {

    @Test("MiniMax H3 is 32kHz")
    func minimax() {
        #expect(DrawThingsQueue.defaultAudioSampleRate(forModelFile: "minimax_h3_i8x.ckpt") == 32000)
    }

    @Test("LongCat Avatar is 16kHz")
    func longcat() {
        #expect(DrawThingsQueue.defaultAudioSampleRate(forModelFile: "longcat_video_avatar_v1.5_q8p.ckpt") == 16000)
    }

    @Test("LTX-2 is 24kHz, LTX-2.3 is 48kHz")
    func ltx() {
        #expect(DrawThingsQueue.defaultAudioSampleRate(forModelFile: "ltx_2_19b_q8p.ckpt") == 24000)
        #expect(DrawThingsQueue.defaultAudioSampleRate(forModelFile: "ltx_2.3_22b_q8p.ckpt") == 48000)
        #expect(DrawThingsQueue.defaultAudioSampleRate(forModelFile: "ltx_2_3_22b_q8p.ckpt") == 48000)
    }

    @Test("Unknown models default to 24kHz")
    func unknown() {
        #expect(DrawThingsQueue.defaultAudioSampleRate(forModelFile: "wan_v2.2_5b_q8p.ckpt") == 24000)
    }
}
