//
//  Companion.swift
//  iRPC
//
//  Created by Sören Stabenow on 06.05.25.
//

import FlyingFox
import SwiftUI

public class Companion {
    // Singleton instance for easy access
    public static let shared = Companion()
    
    private var server: FlyingFox.HTTPServer?
    private let port: UInt16 = 6969
    
    // Store the latest music data from companion app
    private var _latestMusicData: MusicData?
    private var presenceTimer: Timer?
    
    /// Music Data received via the companion server
    public struct MusicData: Codable, CustomStringConvertible {
        let title: String
        let artist: String
        let album: String
        let duration: Int
        let position: Int
        let receivedAt: Date
        
        init(title: String, artist: String, album: String, duration: Int, position: Int) {
            self.title = title
            self.artist = artist
            self.album = album
            self.duration = duration
            self.position = position
            self.receivedAt = Date()
        }
        
        public var description: String {
            return "\(title) by \(artist) (\(position)/\(duration))"
        }
    }
    
    // Thread-safe access to latest music data
    public var latestMusicData: MusicData? {
        get { _latestMusicData }
    }
    
    // Convert companion MusicData to MusicInfo for Discord RPC
    public func toMusicInfo(from music: MusicData) -> MusicInfo {
        // Calculate current position based on elapsed time since we received the data
        let elapsedSinceReceived = Date().timeIntervalSince(music.receivedAt)
        let currentPosition = min(
            TimeInterval(music.position) + elapsedSinceReceived,
            TimeInterval(music.duration)
        )
        
        return MusicInfo(
            title: music.title,
            artist: music.artist,
            album: music.album,
            duration: TimeInterval(music.duration),
            position: currentPosition
        )
    }
    
    // Check if we have valid music data that hasn't ended
    public var hasActiveMusicData: Bool {
        guard let music = _latestMusicData else { return false }
        
        // Calculate if song has finished playing
        let elapsedSinceReceived = Date().timeIntervalSince(music.receivedAt)
        let currentPosition = TimeInterval(music.position) + elapsedSinceReceived
        
        return currentPosition < TimeInterval(music.duration)
    }
    
    private init() {
        // Private initializer for singleton pattern
    }
    
    public func startServer() async throws {
        // Don't start if already running
        guard server == nil else { return }
        
        // Remove any existing observer to avoid duplicates
        NotificationCenter.default.removeObserver(
            self,
            name: .stopCompanionServer,
            object: nil
        )
        
        // Add new observer
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleStopServerNotification),
            name: .stopCompanionServer,
            object: nil
        )
        
        self.server = HTTPServer(port: self.port)
        self.log("Starting Companion Server on port \(self.port)")
        
        await server?.appendRoute("/music/apple") { [weak self] request in
            guard let self = self else {
                return HTTPResponse(statusCode: .internalServerError)
            }
            return await self.applemusic(request: request)
        }
        
        try await server?.run()
    }
    
    private func applemusic(request: HTTPRequest) async -> HTTPResponse {
        do {
            let body = try await request.bodyData
            let decoder = JSONDecoder()
            let receivedData = try decoder.decode(MusicData.self, from: body)
            
            // Create new MusicData with current timestamp
            let music = MusicData(
                title: receivedData.title,
                artist: receivedData.artist,
                album: receivedData.album,
                duration: receivedData.duration,
                position: receivedData.position
            )
            
            self.log("Received Apple Music data: \(music)")
            
            // Update our stored music data
            self._latestMusicData = music
            
            // Cancel existing timer if any
            self.presenceTimer?.invalidate()
            
            // Calculate when song will end and set timer to clear presence
            let remainingTime = Double(music.duration - music.position)
            if remainingTime > 0 {
                self.presenceTimer = Timer.scheduledTimer(withTimeInterval: remainingTime + 1, repeats: false) { [weak self] _ in
                    self?.clearExpiredData()
                }
            }
            
            // Notify the app to update Discord presence
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .refreshDiscordPresence, object: nil)
            }
            
            return HTTPResponse(statusCode: .ok)
        } catch {
            self.log("Error processing music data: \(error)", level: .error)
            return HTTPResponse(statusCode: .internalServerError)
        }
    }
    
    private func clearExpiredData() {
        if let music = _latestMusicData {
            self.log("Song \(music.title) has ended, clearing companion data")
            _latestMusicData = nil
            
            // Notify the app to refresh presence (which will clear it if no local music)
            NotificationCenter.default.post(name: .refreshDiscordPresence, object: nil)
        }
    }
    
    @objc private func handleStopServerNotification() {
        Task {
            await destroy()
        }
    }
    
    @objc private func destroy() async {
        self.log("Shutting down companion server...", level: .warning)
        
        // Clean up timer first
        if let timer = self.presenceTimer {
            timer.invalidate()
            self.presenceTimer = nil
        }
        
        // Clear music data
        self._latestMusicData = nil
        
        // Create a local reference and set our instance var to nil
        // to prevent multiple shutdown attempts
        guard let serverToStop = self.server else {
            self.log("Server already stopped or was never started", level: .warning)
            return
        }
        self.server = nil
        
        // Add a small delay to ensure any pending operations complete
        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms delay
        
        do {
            try await serverToStop.stop(timeout: 2)
            self.log("Companion server stopped successfully")
        } catch {
            // Just log the error but don't treat as critical
            self.log("Non-critical error during server shutdown: \(error)", level: .warning)
        }
        
        // Make sure we remove observer to prevent memory leaks
        NotificationCenter.default.removeObserver(
            self,
            name: .stopCompanionServer,
            object: nil
        )
    }
    
    // MARK: - Logging
    private enum LogLevel: String { case info = "INFO", warning = "WARN", error = "ERROR" }
    
    private func log(_ message: String, level: LogLevel = .info) {
        print("[Companion][\(level.rawValue)] \(message)")
    }
}
