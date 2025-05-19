//
//  NowPlayingView.swift
//  iRPC
//
//  Created by Adrian Castro on 19/5/25.
//

import SwiftUI
import NowPlayingKit

public struct NowPlayingView: View {
    let nowPlaying: NowPlayingData
    let manager: NowPlayingManager
    let isLastPlayed: Bool
    
    // Updated initializer with default parameter
    public init(nowPlaying: NowPlayingData, manager: NowPlayingManager, isLastPlayed: Bool = false) {
        self.nowPlaying = nowPlaying
        self.manager = manager
        self.isLastPlayed = isLastPlayed
    }

    public var body: some View {
        Section {
            if nowPlaying.title == "Loading..." {
                VStack(spacing: 16) {
                    ProgressView()
                        .controlSize(.large)
                    Text("Loading Music...")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 200)
            } else if nowPlaying.title == "No song playing" {
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
            } else {
                VStack(alignment: .center, spacing: 16) {
                    // Show last played banner if applicable
                    if isLastPlayed {
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
                    
                    if let artworkURL = nowPlaying.artworkURL {
                        AsyncImage(url: artworkURL) { phase in
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

                    VStack(spacing: 8) {
                        Text(nowPlaying.title)
                            .font(.title3)
                            .bold()
                            .lineLimit(1)

                        Text(nowPlaying.artist)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)

                        if let album = nowPlaying.album {
                            Text(album)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }

                    // Only show progress if not showing last played
                    if !isLastPlayed {
                        VStack(spacing: 8) {
                            ProgressView(value: nowPlaying.playbackTime, total: nowPlaying.duration)
                                .tint(.blue)

                            HStack {
                                Text(formatTime(nowPlaying.playbackTime))
                                Spacer()
                                Text(formatTime(nowPlaying.duration))
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
                .listRowInsets(EdgeInsets())
                .padding()
            }
        }
    }
    
    private func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
