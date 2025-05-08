//
//  ContentView.swift
//  iRPC Mobile
//
//  Created by Adrian Castro on 8/5/25.
//

// ContentView.swift

import DiscordSocialKit
import NowPlayingKit
import SwiftUI

struct ContentView: View {
	@State private var nowPlaying = NowPlayingData(title: "Loading...", artist: "")
	@State private var isAuthorized = false
	@StateObject private var discord = DiscordManager(applicationId: 1370062110272520313)
	private let manager = NowPlayingManager.shared
	private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

	var body: some View {
		Group {
			if !discord.isReady {
				ProgressView("Connecting to Discord...")
			} else if !discord.isAuthenticated {
				VStack {
					Text("Discord Login Required")
						.font(.headline)
					Button("Login with Discord") {
						discord.authorize()
					}
				}
			} else if isAuthorized {
				VStack(spacing: 20) {
					Text("Now Playing:")
						.font(.headline)
						.foregroundColor(.gray)

					Text(nowPlaying.title)
						.font(.title2)
						.bold()
						.foregroundColor(.primary)

					if !nowPlaying.artist.isEmpty {
						Text(nowPlaying.artist)
							.font(.subheadline)
							.foregroundColor(.secondary)
							.italic()
					}

					if let album = nowPlaying.album {
						Text(album)
							.font(.subheadline)
							.foregroundColor(.secondary)
							.italic()
					}

					if let artworkURL = nowPlaying.artworkURL {
						AsyncImage(url: artworkURL) { phase in
							switch phase {
							case .success(let image):
								image
									.resizable()
									.aspectRatio(contentMode: .fill)
									.frame(width: 250, height: 250)
									.clipShape(RoundedRectangle(cornerRadius: 15))
									.shadow(radius: 10)
							default:
								ProgressView()
									.progressViewStyle(CircularProgressViewStyle(tint: .primary))
									.frame(width: 50, height: 50)
							}
						}
					}

					VStack {
						ProgressView(value: nowPlaying.playbackTime, total: nowPlaying.duration)
							.progressViewStyle(LinearProgressViewStyle(tint: .blue))
							.frame(height: 6)
							.cornerRadius(3)
							.padding(.horizontal)
							.accentColor(.blue)

						HStack {
							Text(formatTime(nowPlaying.playbackTime))
								.font(.footnote)
								.foregroundColor(.secondary)

							Spacer()

							Text(formatTime(nowPlaying.duration))
								.font(.footnote)
								.foregroundColor(.secondary)
						}
						.padding(.horizontal)
					}
				}
			} else {
				VStack {
					Text("Music Access Required")
						.font(.headline)
					Button("Authorize Access") {
						Task {
							await requestAuthorization()
						}
					}
				}
			}
		}
		.padding()
		.task {
			await requestAuthorization()
			if isAuthorized {
				await updateNowPlaying()
			}
		}
		.onReceive(timer) { _ in
			guard isAuthorized else { return }
			Task {
				await updatePlaybackTime()
			}
		}
		.onReceive(manager.queue.objectWillChange) { _ in
			guard isAuthorized else { return }
			Task {
				await updateNowPlaying()
			}
		}
	}

	private func requestAuthorization() async {
		let status = await manager.authorize()
		isAuthorized = status == .authorized
	}

	private func updateNowPlaying() async {
		do {
			nowPlaying = try await manager.getCurrentPlayback()
		} catch {
			nowPlaying = NowPlayingData(title: "No song playing", artist: "")
		}
	}

	private func updatePlaybackTime() async {
		do {
			nowPlaying = try await manager.getCurrentPlayback()
		} catch {
			// Ignore errors during playback time updates
		}
	}

	private func formatTime(_ time: TimeInterval) -> String {
		let minutes = Int(time) / 60
		let seconds = Int(time) % 60
		return String(format: "%02d:%02d", minutes, seconds)
	}
}
