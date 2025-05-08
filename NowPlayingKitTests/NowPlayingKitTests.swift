//
//  NowPlayingKitTests.swift
//  NowPlayingKitTests
//
//  Created by Adrian Castro on 8/5/25.
//

import Testing
@testable import NowPlayingKit

struct NowPlayingKitTests {
    @Test func testNowPlayingManager() async throws {
        let manager = NowPlayingManager.shared
        do {
            let playbackData = try await manager.getCurrentPlayback()
            #expect(playbackData.title.isEmpty == false)
            #expect(playbackData.duration >= 0)
        } catch NowPlayingError.noCurrentEntry {
            print("No music playing")
        }
    }
}
