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
	@State private var nowPlaying = NowPlayingData(id: "", title: "Loading...", artist: "")
	@State private var isAuthorized = false
	@State private var isLoading = true
	@State private var isAuthenticating = false
	@State private var userEnabledRPC = false
	@StateObject private var discord = DiscordManager(applicationId: 1_370_062_110_272_520_313)
	private let manager = NowPlayingManager.shared
	@State private var lastUpdateTime: TimeInterval = 0
	private let updateInterval: TimeInterval = 1
	@Environment(\.modelContext) private var modelContext

	var body: some View {
		NavigationStack {
			Group {
				if !isAuthorized {
					AuthorizationView(requestAuthorization: requestAuthorization)
				} else {
					NowPlayingView(
						nowPlaying: nowPlaying,
						discord: discord,
						userEnabledRPC: $userEnabledRPC
					)
				}
			}
			.navigationTitle("iRPC")
			.toolbar {
				if isAuthorized {
					ToolbarItem(placement: .topBarTrailing) {
						NavigationLink {
							DiscordSettingsView(
								discord: discord,
								isAuthenticating: $isAuthenticating
							)
						} label: {
							Label("Discord Settings", systemImage: "gear")
						}
					}
				}
			}
		}
		.task {
			print("🔄 Initializing Discord connection...")
			await MainActor.run {
				print("📱 Setting ModelContext...")
				discord.setModelContext(modelContext)
			}

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
		.onChange(of: discord.isAuthenticated) { oldValue, newValue in
			if newValue {
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
		.onReceive(manager.$isPlaying) { isPlaying in
			guard userEnabledRPC, discord.isAuthenticated else { return }

			if isPlaying && !discord.isRunning {
				print("▶️ Music started playing, starting RPC")
				discord.startPresenceUpdates()
			} else if !isPlaying && discord.isRunning {
				print("⏸️ Music paused, stopping RPC")
				discord.stopPresenceUpdates()
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
					id: newPlayback.id,
					title: newPlayback.title,
					artist: newPlayback.artist,
					duration: newPlayback.duration,
					currentTime: newPlayback.playbackTime,
					artworkURL: newPlayback.artworkURL
				)
			}
		} catch {
			nowPlaying = NowPlayingData(id: "", title: "No song playing", artist: "")
			discord.clearPlayback()
		}
	}

	private func updatePlaybackTime() async {
		do {
			let current = try await manager.getCurrentPlayback()
			nowPlaying = current

			if discord.isAuthenticated {
				discord.updateCurrentPlayback(
					id: current.id,
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
				print("🔍 Found existing token with ID: \(token.tokenId)")
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

extension View {
	fileprivate func formatTime(_ time: TimeInterval) -> String {
		let minutes = Int(time) / 60
		let seconds = Int(time) % 60
		return String(format: "%02d:%02d", minutes, seconds)
	}
}

// MARK: - Subviews
private struct AuthorizationView: View {
	let requestAuthorization: () async -> Void

	var body: some View {
		VStack(spacing: 16) {
			Image(systemName: "music.note")
				.font(.system(size: 60))
				.foregroundStyle(.secondary)

			Text("Music Access Required")
				.font(.title2)
				.bold()

			Text(
				"iRPC needs access to Apple Music to show your currently playing track in Discord."
			)
			.multilineTextAlignment(.center)
			.foregroundStyle(.secondary)

			Button(action: {
				Task { await requestAuthorization() }
			}) {
				Text("Authorize Access")
					.frame(maxWidth: .infinity)
			}
			.buttonStyle(.bordered)
			.tint(.blue)
			.controlSize(.large)
			.padding(.top)
		}
		.padding()
	}
}

private struct NowPlayingView: View {
	let nowPlaying: NowPlayingData
	let discord: DiscordManager
	@Binding var userEnabledRPC: Bool

	var body: some View {
		List {
			// Now Playing Section
			Section {
				if nowPlaying.title == "Loading..." {
					VStack(spacing: 16) {
						ProgressView()
							.controlSize(.large)
						Text("Loading Music...")
							.foregroundStyle(.secondary)
					}
					.frame(maxWidth: .infinity, minHeight: 200)
				} else {
					VStack(alignment: .center, spacing: 16) {
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

						// Playback Progress
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
					.listRowInsets(EdgeInsets())
					.padding()
				}
			}

			// Discord Status Section - Now always visible
			Section {
				VStack(spacing: 12) {
					HStack {
						Image("Discord")
							.resizable()
							.aspectRatio(contentMode: .fit)
							.frame(width: 24, height: 24)

						if discord.isAuthorizing {
							HStack(spacing: 4) {
								Text("Connecting")
									.foregroundStyle(.secondary)
								ProgressView()
									.scaleEffect(0.7)
							}
						} else if discord.isAuthenticated && discord.isReady {
							HStack(spacing: 4) {
								Text("Connected")
									.foregroundStyle(.green)

								if let username = discord.username {
									Text("as \(username)")
										.foregroundStyle(.secondary)
								}
							}

							Spacer()

							Toggle(isOn: $userEnabledRPC) {
								Text("Rich Presence")
									.fixedSize()
							}
							.onChange(of: userEnabledRPC) { _, isEnabled in
								if isEnabled {
									discord.startPresenceUpdates()
									BackgroundController.shared.start()
								} else {
									discord.stopPresenceUpdates()
									BackgroundController.shared.stop()
								}
							}
						} else {
							Text("Not Connected")
								.foregroundStyle(.secondary)
						}
					}
				}
			} header: {
				Text("Discord Status")
			} footer: {
				if discord.isAuthenticated {
					Text(
						userEnabledRPC
							? "Discord Rich Presence is active."
							: "Enable Rich Presence to show your currently playing track in Discord."
					)
				} else {
					Text("Connect your Discord account in Settings to share your music status.")
				}
			}
		}
		.listStyle(.insetGrouped)
	}
}

private struct DiscordSettingsView: View {
	@Environment(\.dismiss) private var dismiss
	let discord: DiscordManager
	@Binding var isAuthenticating: Bool

	var body: some View {
		List {
			Section {
				if discord.isAuthenticated {
					HStack(spacing: 12) {
						if let avatarURL = discord.avatarURL {
							AsyncImage(url: avatarURL) { phase in
								switch phase {
								case .success(let image):
									image
										.resizable()
										.aspectRatio(contentMode: .fill)
										.frame(width: 48, height: 48)
										.clipShape(Circle())
								default:
									Circle()
										.fill(.secondary.opacity(0.2))
										.frame(width: 48, height: 48)
								}
							}
						}

						VStack(alignment: .leading, spacing: 4) {
							Text(discord.globalName ?? discord.username ?? "")
								.font(.headline)

							Text("@\(discord.username ?? "")")
								.font(.subheadline)
								.foregroundStyle(.secondary)
						}

						Spacer()
					}
					.padding(.vertical, 4)
				} else {
					Button {
						isAuthenticating = true
						discord.authorize()
					} label: {
						Label("Connect Discord Account", systemImage: "person.badge.key.fill")
					}
				}
			} header: {
				Text("Account")
			}

			if discord.isAuthenticated {
				Section {
					Button(role: .destructive) {
						discord.authorize()  // Re-authorize
					} label: {
						Label("Reconnect Account", systemImage: "arrow.clockwise")
					}
				} footer: {
					Text("Use this if you're having connection issues.")
				}
			}
		}
		.navigationTitle("Discord Settings")
		.navigationBarTitleDisplayMode(.inline)
	}
}
