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
	@StateObject private var discord = DiscordManager(applicationId: 1_370_062_110_272_520_313)
	private let manager = NowPlayingManager.shared
	@State private var lastUpdateTime: TimeInterval = 0
	private let updateInterval: TimeInterval = 1
	private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

	var body: some View {
		VStack(spacing: 20) {
			if !isAuthorized {
				VStack {
					Text("Music Access Required")
						.font(.headline)
					Button("Authorize Access") {
						Task {
							await requestAuthorization()
						}
					}
					.buttonStyle(.borderedProminent)
				}
			} else {
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
									.progressViewStyle(
										CircularProgressViewStyle(tint: .primary)
									)
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

					VStack {
						Text("Discord Status")
							.font(.headline)

						ZStack {
							// Auth Button Layer
							Button(action: {
								discord.authorize()
							}) {
								Label("Link Discord Account", systemImage: "person.badge.key.fill")
									.font(.headline)
									.foregroundColor(.white)
									.padding()
									.background(Color.blue)
									.cornerRadius(10)
							}
							.opacity(
								!discord.isAuthorizing && !discord.isAuthenticated
									&& discord.errorMessage == nil ? 1 : 0)

							// Loading Layer
							ProgressView("Authorizing...")
								.opacity(discord.isAuthorizing ? 1 : 0)

							// Success Layer
							Label("Connected to Discord", systemImage: "checkmark.circle.fill")
								.foregroundColor(.green)
								.opacity(discord.isAuthenticated ? 1 : 0)

							// Error Layer
							if let error = discord.errorMessage {
								Text(error)
									.foregroundColor(.red)
									.multilineTextAlignment(.center)
							}
						}
						.frame(height: 44)  // Add fixed height to prevent layout shifts
						.animation(.easeInOut, value: discord.isAuthorizing)
						.animation(.easeInOut, value: discord.isAuthenticated)
						.animation(.easeInOut, value: discord.errorMessage)
					}
					.padding()
					.background(Color.secondary.opacity(0.1))
					.cornerRadius(15)
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
			let newPlayback = try await manager.getCurrentPlayback()
			nowPlaying = newPlayback

			if discord.isAuthenticated && discord.isReady {
				discord.updateCurrentPlayback(
					title: newPlayback.title,
					artist: newPlayback.artist,
					duration: newPlayback.duration,
					currentTime: newPlayback.playbackTime,
					artworkURL: newPlayback.artworkURL
				)
			}
		} catch {
			nowPlaying = NowPlayingData(title: "No song playing", artist: "")
			discord.clearPlayback()
		}
	}

	private func updatePlaybackTime() async {
		do {
			let current = try await manager.getCurrentPlayback()
			nowPlaying = current

			if discord.isAuthenticated {
				discord.updateCurrentPlayback(
					title: current.title,
					artist: current.artist,
					duration: current.duration,
					currentTime: current.playbackTime,
					artworkURL: current.artworkURL
				)
			}
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
