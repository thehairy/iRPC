//
//  ContentView.swift
//  iRPC Mobile
//
//  Created by Adrian Castro on 8/5/25.
//

// ContentView.swift

import Combine
import DiscordSocialKit
import NowPlayingKit
import SwiftData
import SwiftUI

struct ContentView: View {
	@State private var nowPlaying = NowPlayingData(title: "Loading...", artist: "")
	@State private var isAuthorized = false
	@State private var isLoading = true
	@State private var isAuthenticating = false  // Add new state
	@StateObject private var discord = DiscordManager(applicationId: 1_370_062_110_272_520_313)
	private let manager = NowPlayingManager.shared
	@State private var lastUpdateTime: TimeInterval = 0
	private let updateInterval: TimeInterval = 1
	@Environment(\.modelContext) private var modelContext

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
							// Loading Layer
							ProgressView("Connecting...")
								.opacity(isLoading || isAuthenticating ? 1 : 0)

							// Auth Button Layer
							Button(action: {
								isAuthenticating = true  // Set authenticating state
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
									&& !isLoading && !isAuthenticating ? 1 : 0)

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
						.contextMenu {
							Button("Refresh Token") {
								Task {
									await discord.refreshTokenIfNeeded()
								}
							}
							Button("Reauthorize") {
								discord.authorize()
							}
						}

						if discord.isAuthenticated {
							Button(action: {
								if discord.isRunning {
									discord.stopPresenceUpdates()
								} else {
									discord.startPresenceUpdates()
								}
							}) {
								Text(discord.isRunning ? "Stop RPC" : "Start RPC")
							}
							.buttonStyle(.borderedProminent)
						}
					}
					.padding()
					.background(Color.secondary.opacity(0.1))
					.cornerRadius(15)
				}
			}
		}
		.padding()
		.task {
			print("🔄 Initializing Discord connection...")
			// Ensure model context is set first
			await MainActor.run {
				print("📱 Setting ModelContext...")
				discord.setModelContext(modelContext)
			}

			// Check for existing token and try to restore session
			let hasExistingToken = await checkExistingToken()
			if hasExistingToken {
				isAuthenticating = true
				await discord.setupWithExistingToken()
			}

			await requestAuthorization()
			if isAuthorized {
				print("🎵 Music access authorized, setting up Discord...")
				await updateNowPlaying()
			}

			isLoading = false
		}
		.onChange(of: discord.isAuthenticated) { authenticated in
			if authenticated {
				isAuthenticating = false
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

	private func setup() {
		discord.setModelContext(modelContext)
	}

	private func checkExistingToken() async -> Bool {
		var descriptor = FetchDescriptor<DiscordToken>(
			sortBy: [SortDescriptor(\DiscordToken.expiresAt, order: .reverse)]
		)
		descriptor.fetchLimit = 1

		do {
			if let token = try modelContext.fetch(descriptor).first {
				print("🔍 Found existing token with ID: \(token.tokenId ?? "unknown")")
				return true
			}
			print("ℹ️ No existing token found")
			return false
		} catch {
			print("❌ Failed to check for existing token: \(error)")
			return false
		}
	}

	private var timer: Publishers.Autoconnect<Timer.TimerPublisher> {
		Timer.publish(every: updateInterval, on: .main, in: .common).autoconnect()
	}
}
