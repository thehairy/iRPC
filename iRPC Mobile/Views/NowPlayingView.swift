//
//  NowPlayingView.swift
//  iRPC
//
//  Created by Adrian Castro on 19/5/25.
//

import SwiftUI
import NowPlayingKit

public enum PlaybackDisplayState: Equatable {
    case loading
    case noMusic
    case playing(NowPlayingData)
    
    // Determine state based on NowPlayingData
    static func from(nowPlaying: NowPlayingData) -> PlaybackDisplayState {
        if nowPlaying.id.isEmpty {
            switch nowPlaying.title {
            case "Loading...":
                return .loading
            case "No song playing":
                return .noMusic
            default:
                // Last played songs still have content but no active ID
                if !nowPlaying.title.isEmpty && !nowPlaying.artist.isEmpty {
                    return .playing(nowPlaying)
                } else {
                    return .noMusic
                }
            }
        } else {
            // If there's an ID, it's definitely a real track
            return .playing(nowPlaying)
        }
    }
    
    // Custom implementation of Equatable since NowPlayingData may not conform to Equatable
    public static func == (lhs: PlaybackDisplayState, rhs: PlaybackDisplayState) -> Bool {
        switch (lhs, rhs) {
        case (.loading, .loading):
            return true
        case (.noMusic, .noMusic):
            return true
        case (.playing(let lhsData), .playing(let rhsData)):
            // Compare relevant properties rather than the entire object
            return lhsData.id == rhsData.id && 
                   lhsData.title == rhsData.title &&
                   lhsData.artist == rhsData.artist
        default:
            return false
        }
    }
}

public struct NowPlayingView: View {
    let nowPlaying: NowPlayingData
    let manager: NowPlayingManager
    let isLastPlayed: Bool
    
    // Compute the display state from data
    private var displayState: PlaybackDisplayState {
        return PlaybackDisplayState.from(nowPlaying: nowPlaying)
    }
    
    // Updated initializer with default parameter
    public init(nowPlaying: NowPlayingData, manager: NowPlayingManager, isLastPlayed: Bool = false) {
        self.nowPlaying = nowPlaying
        self.manager = manager
        self.isLastPlayed = isLastPlayed
    }

    public var body: some View {
        Section {
            switch displayState {
            case .loading:
                LoadingView()
            case .noMusic:
                EmptyMusicStateView()
            case .playing(let data):
                PlayingContentView(nowPlaying: data, isLastPlayed: isLastPlayed)
            }
        }
        // Add tracking to debug state transitions if needed
        .onChange(of: displayState) { _, newState in
            switch newState {
            case .loading: 
                print("🎵 NowPlayingView: Showing loading state")
            case .noMusic:
                print("🎵 NowPlayingView: Showing no music state")
            case .playing(let data):
                print("🎵 NowPlayingView: Showing playing state - \(data.title)")
            }
        }
    }
    
    private func LoadingView() -> some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text("Loading Music...")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
    }
    
    private func EmptyMusicStateView() -> some View {
        VStack(spacing: 16) {
            Image(systemName: "music.note.list")
                .font(.system(size: 50))
                .foregroundStyle(.secondary)
            
            Text("No Music Playing")
                .font(.title3)
                .bold()
            
            Text("Play a song to see it here")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
    }
    
    private func PlayingContentView(nowPlaying: NowPlayingData, isLastPlayed: Bool) -> some View {
        VStack(alignment: .center, spacing: 16) {
            // Show last played banner if applicable
            if isLastPlayed {
                LastPlayedBadge()
            }
            
            if let artworkURL = nowPlaying.artworkURL {
                ArtworkView(url: artworkURL)
            }
            
            SongInfoView(title: nowPlaying.title, artist: nowPlaying.artist, album: nowPlaying.album)
            
            // Only show progress if not showing last played
            if !isLastPlayed {
                PlaybackProgressView(playbackTime: nowPlaying.playbackTime, duration: nowPlaying.duration)
            }
        }
        .listRowInsets(EdgeInsets())
        .padding()
    }
    
    private func LastPlayedBadge() -> some View {
        HStack {
            Image(systemName: "clock.arrow.circlepath")
            Text("Last Played")
                .font(.caption)
                .bold()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.secondary.opacity(0.2))
        .cornerRadius(20)
    }
    
    private func ArtworkView(url: URL) -> some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(height: 300)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            default:
                RoundedRectangle(cornerRadius: 12)
                    .fill(.secondary.opacity(0.1))
                    .frame(height: 300)
                    .overlay {
                        ProgressView()
                    }
            }
        }
    }
    
    private func SongInfoView(title: String, artist: String, album: String?) -> some View {
        VStack(spacing: 8) {
            Text(title)
                .font(.title3)
                .bold()
                .lineLimit(1)
            
            Text(artist)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            
            if let album = album {
                Text(album)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
    
    private func PlaybackProgressView(playbackTime: TimeInterval, duration: TimeInterval) -> some View {
        VStack(spacing: 8) {
            ProgressView(value: playbackTime, total: duration)
                .tint(.blue)
            
            HStack {
                Text(formatTime(playbackTime))
                Spacer()
                Text(formatTime(duration))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
    
    private func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
