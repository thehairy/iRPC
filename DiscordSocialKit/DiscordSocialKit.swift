//
//  DiscordSocialKit.swift
//  DiscordSocialKit
//
//  Created by Adrian Castro on 8/5/25.
//

import Combine
import Foundation
internal import MusadoraKit
import SwiftData
import discord_partner_sdk

@MainActor
public final class DiscordManager: ObservableObject {
	private var client: UnsafeMutablePointer<Discord_Client>?
	private var applicationId: UInt64
	private var verifier: Discord_AuthorizationCodeVerifier?
	private var modelContext: ModelContext?

	// Add artwork cache
	private var artworkCache: [String: URL] = [:]

	@Published public private(set) var isReady = false
	@Published public private(set) var isAuthenticated = false
	@Published public private(set) var errorMessage: String? = nil
	@Published public private(set) var isAuthorizing = false
	@Published public var isRunning = false

	public func startPresenceUpdates() {
		print("🎮 Starting Discord Rich Presence")
		isRunning = true
		Task { @MainActor in
			await startUpdates()
		}
	}

	public func stopPresenceUpdates() {
		print("🛑 Stopping Discord Rich Presence")
		isRunning = false
		Task { @MainActor in
			await stopUpdates()
		}
	}

	private var updateTimer: Timer?
	private var lastId: String = ""
	private var lastTitle: String = ""
	private var lastArtist: String = ""
	private var lastArtwork: URL? = nil
	private var lastDuration: TimeInterval = 0
	private var lastCurrentTime: TimeInterval = 0

	private var currentPlaybackInfo:
		(
			id: String, title: String, artist: String, duration: TimeInterval,
			currentTime: TimeInterval,
			artworkURL: URL?
		)? = nil
	private let presenceUpdateInterval: TimeInterval = 0.5

	private let statusCallback: Discord_Client_OnStatusChanged = {
		status, error, errorDetail, userData in
		let manager = Unmanaged<DiscordManager>.fromOpaque(userData!).takeUnretainedValue()
		print("🔄 Status changed: \(status)")

		DispatchQueue.main.async {
			if error != Discord_Client_Error_None {
				print("❌ Connection Error: \(error) - Details: \(errorDetail)")
				manager.handleError("Connection error \(error): \(errorDetail)")
				return
			}

			switch status {
			case Discord_Client_Status_Ready:
				print("✅ Client is ready!")
				manager.isReady = true
			case Discord_Client_Status_Connected:
				print("🔗 Client connected!")
				manager.isAuthenticated = true
				manager.isAuthorizing = false
				manager.errorMessage = nil
			case Discord_Client_Status_Disconnected:
				print("❌ Client disconnected")
				manager.isAuthenticated = false
			default:
				break
			}
		}
	}

	public init(applicationId: UInt64) {
		self.applicationId = applicationId
		setupClient()
	}

	public func setModelContext(_ context: ModelContext) {
		self.modelContext = context
	}

	private func setupClient() {
		print("🚀 Initializing Discord SDK...")

		// Create client and retain pointer
		self.client = UnsafeMutablePointer<Discord_Client>.allocate(capacity: 1)
		guard let client = self.client else { return }

		Discord_Client_Init(client)
		Discord_Client_SetApplicationId(client, applicationId)

		// Set up logging callback with proper string conversion
		let logCallback: Discord_Client_LogCallback = { message, severity, userData in
			let severityStr = { () -> String in
				switch severity {
				case Discord_LoggingSeverity_Info: return "INFO"
				case Discord_LoggingSeverity_Warning: return "WARN"
				case Discord_LoggingSeverity_Error: return "ERROR"
				default: return "DEBUG"
				}
			}()

			if let messagePtr = message.ptr,
				let messageStr = String(
					bytes: UnsafeRawBufferPointer(
						start: messagePtr,
						count: Int(message.size)
					),
					encoding: .utf8
				)
			{
				print("[Discord \(severityStr)] \(messageStr)")
			}
		}
		Discord_Client_AddLogCallback(client, logCallback, nil, nil, Discord_LoggingSeverity_Info)

		let userDataPtr = Unmanaged.passRetained(self).toOpaque()
		Discord_Client_SetStatusChangedCallback(client, statusCallback, nil, userDataPtr)

		// Start callback loop
		DispatchQueue.global(qos: .utility).async { [weak self] in
			while self != nil {
				autoreleasepool {
					Discord_RunCallbacks()
				}
				Thread.sleep(forTimeInterval: 0.01)
			}
		}

		print("✨ Discord SDK initialized successfully")
	}

	public func authorize() {
		guard let client = self.client else { return }
		print("Starting auth flow...")
		isAuthorizing = true

		// Create and retain verifier
		let verifier = UnsafeMutablePointer<Discord_AuthorizationCodeVerifier>.allocate(capacity: 1)
		Discord_Client_CreateAuthorizationCodeVerifier(client, verifier)
		self.verifier = verifier.pointee

		var args = Discord_AuthorizationArgs()
		Discord_AuthorizationArgs_Init(&args)
		Discord_AuthorizationArgs_SetClientId(&args, applicationId)

		var scopes = Discord_String()
		Discord_Client_GetDefaultPresenceScopes(&scopes)
		Discord_AuthorizationArgs_SetScopes(&args, scopes)

		var challenge = Discord_AuthorizationCodeChallenge()
		Discord_AuthorizationCodeVerifier_Challenge(verifier, &challenge)
		Discord_AuthorizationArgs_SetCodeChallenge(&args, &challenge)

		let userDataPtr = Unmanaged.passRetained(self).toOpaque()
		Discord_Client_Authorize(client, &args, self.authCallback, nil, userDataPtr)
	}

	public func clearRichPresence() {
		guard let client = client else { return }
		print("🧹 Clearing rich presence...")

		Discord_Client_ClearRichPresence(client)
	}

	struct RichPresenceContext {
		let namePtr: UnsafeMutablePointer<UInt8>
		let detailsPtr: UnsafeMutablePointer<UInt8>
		let statePtr: UnsafeMutablePointer<UInt8>
		let manager: DiscordManager
	}

	private static let richPresenceCallback:
		@convention(c) (UnsafeMutablePointer<Discord_ClientResult>?, UnsafeMutableRawPointer?) ->
			Void = { result, userData in
				print("📣 Rich Presence callback received")
				guard let contextPtr = userData?.assumingMemoryBound(to: RichPresenceContext.self)
				else {
					print("❌ Rich Presence callback: No context")
					return
				}

				let context = contextPtr.pointee
				defer {
					print("🧹 Cleaning up Rich Presence buffers")
					context.namePtr.deallocate()
					context.detailsPtr.deallocate()
					context.statePtr.deallocate()
					contextPtr.deallocate()
				}

				if let result = result {
					if Discord_ClientResult_Successful(result) {
						print("✅ Rich Presence updated successfully!")
					} else {
						var errorStr = Discord_String()
						Discord_ClientResult_Error(result, &errorStr)
						if let ptr = errorStr.ptr {
							let errorMessage =
								String(
									bytes: UnsafeRawBufferPointer(
										start: ptr,
										count: Int(errorStr.size)
									),
									encoding: .utf8
								) ?? "Unknown error"
							print("❌ Rich Presence update failed: \(errorMessage)")
						} else {
							print("❌ Rich Presence update failed: No error message available")
						}
					}
				} else {
					print("❌ Rich Presence update failed: No result")
				}
			}

	private func validateAssetURL(_ url: URL) -> Bool {
		print("Validating asset URL: \(url)")
		let urlString = url.absoluteString
		return urlString.count >= 1 && urlString.count <= 256
	}

	public func updateRichPresence(
		id: String, title: String, artist: String, duration: TimeInterval,
		currentTime: TimeInterval,
		artworkURL: URL? = nil
	) async {
		guard let client = client else {
			print("⚠️ Cannot update Rich Presence: No client")
			return
		}

		guard isAuthenticated else {
			print("⚠️ Cannot update Rich Presence: Not authenticated")
			return
		}

		// Skip empty updates
		if title.isEmpty || artist.isEmpty {
			print("⚠️ Skipping empty rich presence update")
			return
		}

		print("📝 Rich Presence Update Request:")
		print("- Title: \(title)")
		print("- Artist: \(artist)")
		print("- Duration: \(duration)")
		print("- Current Time: \(currentTime)")

		var activity = Discord_Activity()
		Discord_Activity_Init(&activity)

		// Set activity type first
		Discord_Activity_SetType(&activity, Discord_ActivityTypes_Playing)

		// Set up asset
		var assets = Discord_ActivityAssets()
		Discord_ActivityAssets_Init(&assets)

		// Check cache first
		if let cachedArtwork = artworkCache[id] {
			var artworkStr = makeDiscordString(from: cachedArtwork.absoluteString)
			var hoverText = makeDiscordString(from: "\(title) by \(artist)")

			Discord_ActivityAssets_SetLargeImage(&assets, &artworkStr)
			Discord_ActivityAssets_SetLargeText(&assets, &hoverText)
		} else {
			// Fetch and cache if not found
			do {
				let song = try await MCatalog.song(id: MusicItemID(rawValue: id), fetch: [.albums])
				if let artworkURL = song.albums?.first?.artwork?.url(width: 600, height: 600),
					validateAssetURL(artworkURL)
				{
					// Cache the URL
					artworkCache[id] = artworkURL

					var artworkStr = makeDiscordString(from: artworkURL.absoluteString)
					var hoverText = makeDiscordString(from: "\(title) by \(artist)")

					Discord_ActivityAssets_SetLargeImage(&assets, &artworkStr)
					Discord_ActivityAssets_SetLargeText(&assets, &hoverText)
				}
			} catch {
				print("⚠️ Failed to fetch artwork: \(error)")
			}
		}

		// Add assets to activity
		Discord_Activity_SetAssets(&activity, &assets)

		// Create and set name
		let namePtr = makeStringBuffer(from: "Apple Music").ptr
		var nameStr = Discord_String()
		nameStr.ptr = namePtr
		nameStr.size = Int(Int32(4))
		Discord_Activity_SetName(&activity, nameStr)

		// Set details (title)
		let detailsPtr = makeStringBuffer(from: title).ptr
		var detailsStr = Discord_String()
		detailsStr.ptr = detailsPtr
		detailsStr.size = Int(Int32(title.utf8.count))
		Discord_Activity_SetDetails(&activity, &detailsStr)

		// Set state (artist)
		let statePtr = makeStringBuffer(from: "by \(artist)").ptr
		var stateStr = Discord_String()
		stateStr.ptr = statePtr
		stateStr.size = Int(Int32(("by \(artist)").utf8.count))
		Discord_Activity_SetState(&activity, &stateStr)

		// Set timestamps safely
		var timestamps = Discord_ActivityTimestamps()
		Discord_ActivityTimestamps_Init(&timestamps)

		// Convert all times to milliseconds
		let now = Date().timeIntervalSince1970
		let startTime = UInt64((now - currentTime) * 1000)
		let endTime = UInt64((now - currentTime + duration) * 1000)

		print("🕒 Setting timestamps: start=\(startTime)ms, end=\(endTime)ms")

		Discord_ActivityTimestamps_SetStart(&timestamps, startTime)
		Discord_ActivityTimestamps_SetEnd(&timestamps, endTime)
		Discord_Activity_SetTimestamps(&activity, &timestamps)

		// Create context for cleanup
		let context = RichPresenceContext(
			namePtr: namePtr,
			detailsPtr: detailsPtr,
			statePtr: statePtr,
			manager: self
		)
		let contextPtr = UnsafeMutablePointer<RichPresenceContext>.allocate(capacity: 1)
		contextPtr.initialize(to: context)

		print("🎵 Sending activity update to Discord...")
		Discord_Client_UpdateRichPresence(
			client, &activity, Self.richPresenceCallback, nil, contextPtr)
	}

	public func updateCurrentPlayback(
		id: String,
		title: String,
		artist: String,
		duration: TimeInterval,
		currentTime: TimeInterval,
		artworkURL: URL?
	) {
		currentPlaybackInfo = (id, title, artist, duration, currentTime, artworkURL)
	}

	public func clearPlayback() {
		currentPlaybackInfo = nil
		artworkCache.removeAll()  // Clear cache when playback stops
		clearRichPresence()
	}

	private func makeStringBuffer(from string: String) -> (
		ptr: UnsafeMutablePointer<UInt8>, size: Int32
	) {
		let data = Array(string.utf8) + [0]
		let ptr = UnsafeMutablePointer<UInt8>.allocate(capacity: data.count)
		ptr.initialize(from: data, count: data.count)
		return (ptr, Int32(string.utf8.count))
	}

	private func makeDiscordString(from string: String) -> Discord_String {
		var discordStr = Discord_String()
		let buffer = makeStringBuffer(from: string)
		discordStr.ptr = buffer.ptr
		discordStr.size = Int(buffer.size)
		return discordStr
	}

	private func updateStoredToken(
		accessToken: String, refreshToken: String, expiresIn: TimeInterval
	) async {
		await MainActor.run {
			guard let context = modelContext else {
				print("❌ No ModelContext available")
				return
			}

			do {
				print("💾 Saving new token...")

				// Clear existing tokens
				let descriptor = FetchDescriptor<DiscordToken>()
				let existingTokens = try context.fetch(descriptor)
				for token in existingTokens {
					print("🗑️ Removing old token: \(token.tokenId)")
					context.delete(token)
				}

				// Create new token
				let token = DiscordToken(
					accessToken: accessToken,
					refreshToken: refreshToken,
					expiresIn: expiresIn
				)

				// Save new token
				context.insert(token)
				try context.save()

				print("✅ Token saved successfully")
				print("- ID: \(token.tokenId)")
				print("- Expires: \(String(describing: token.expiresAt))")
			} catch {
				print("❌ Failed to save token: \(error)")
				print("Error details: \(error.localizedDescription)")
			}
		}
	}

	private func loadExistingToken() -> DiscordToken? {
		guard let context = modelContext else {
			print("❌ Cannot load token: No ModelContext available")
			return nil
		}

		var descriptor = FetchDescriptor<DiscordToken>()
		descriptor.sortBy = [SortDescriptor(\DiscordToken.expiresAt, order: .reverse)]
		descriptor.fetchLimit = 1

		do {
			let tokens = try context.fetch(descriptor)
			print("🔍 Found \(tokens.count) tokens in store")
			return tokens.first
		} catch {
			print("❌ Failed to fetch tokens: \(error)")
			return nil
		}
	}

	private func refreshRichPresence() {
		Task {
			await updateRichPresence(
				id: lastId,
				title: lastTitle,
				artist: lastArtist,
				duration: lastDuration,
				currentTime: lastCurrentTime,
				artworkURL: lastArtwork
			)
		}
	}

	private func stopUpdates() async {
		print("⏹️ Stopping presence updates")
		// Stop timer first
		updateTimer?.invalidate()
		updateTimer = nil

		// Clear state
		currentPlaybackInfo = nil
		lastTitle = ""
		lastArtist = ""
		lastArtwork = nil
		lastDuration = 0
		lastCurrentTime = 0

		// Clear presence last
		clearRichPresence()
	}

	private func startUpdates() async {
		await stopUpdates()  // Clear any existing timer first

		print("▶️ Starting presence updates")
		updateTimer = Timer.scheduledTimer(withTimeInterval: presenceUpdateInterval, repeats: true)
		{ [weak self] _ in
			guard let self = self else { return }
			Task { @MainActor in
				guard let info = self.currentPlaybackInfo,
					self.isAuthenticated,
					self.isReady,
					self.isRunning
				else { return }

				await self.updateRichPresence(
					id: info.id,
					title: info.title,
					artist: info.artist,
					duration: info.duration,
					currentTime: info.currentTime,
					artworkURL: info.artworkURL
				)
			}
		}
	}

	private func handleError(_ message: String) {
		DispatchQueue.main.async {
			self.errorMessage = message
			self.isReady = false
			self.isAuthenticated = false
			self.isAuthorizing = false
		}
	}

	public func refreshTokenIfNeeded() async {
		guard let token = loadExistingToken(),
			let refreshToken = token.refreshToken,  // Now correctly handling optional
			token.needsRefresh
		else {
			print("⚠️ No valid refresh token available")
			return
		}
		let refreshStr = makeDiscordString(from: refreshToken)

		print("🔄 Refreshing token using refresh token")
		Discord_Client_RefreshToken(
			client,
			applicationId,
			refreshStr,
			tokenCallback,
			nil,
			Unmanaged.passRetained(self).toOpaque()
		)
	}

	public func setupWithExistingToken() async {
		await MainActor.run {
			guard let token = loadExistingToken(),
				let accessToken = token.accessToken  // Now correctly handling optional
			else {
				print("⚠️ No existing token found or token invalid")
				return
			}

			if token.needsRefresh {
				print("🔄 Token needs refresh, initiating refresh flow")
				Task { await refreshTokenIfNeeded() }
			} else {
				print("✅ Using existing valid token")
				let accessStr = makeDiscordString(from: accessToken)
				Discord_Client_UpdateToken(
					client,
					Discord_AuthorizationTokenType_Bearer,
					accessStr,
					{ result, userData in
						let manager = Unmanaged<DiscordManager>.fromOpaque(userData!)
							.takeUnretainedValue()
						print("🔑 Loaded token from storage, connecting to Discord...")
						Discord_Client_Connect(manager.client)
					},
					nil,
					Unmanaged.passRetained(self).toOpaque()
				)
			}
		}
	}

	private let tokenCallback: Discord_Client_TokenExchangeCallback = {
		result, token, refreshToken, tokenType, expiresIn, scope, userData in
		let manager = Unmanaged<DiscordManager>.fromOpaque(userData!).takeUnretainedValue()

		if let tokenPtr = token.ptr,
			let refreshPtr = refreshToken.ptr,
			let tokenStr = String(
				bytes: UnsafeRawBufferPointer(start: tokenPtr, count: Int(token.size)),
				encoding: .utf8),
			let refreshStr = String(
				bytes: UnsafeRawBufferPointer(start: refreshPtr, count: Int(refreshToken.size)),
				encoding: .utf8)
		{

			print("🎟️ Received new token from Discord")
			Task { @MainActor in
				await manager.updateStoredToken(
					accessToken: tokenStr,
					refreshToken: refreshStr,
					expiresIn: TimeInterval(expiresIn)
				)

				let accessStr = manager.makeDiscordString(from: tokenStr)
				Discord_Client_UpdateToken(
					manager.client,
					Discord_AuthorizationTokenType_Bearer,
					accessStr,
					{ result, userData in
						let manager = Unmanaged<DiscordManager>.fromOpaque(userData!)
							.takeUnretainedValue()
						print("🔑 Token updated, connecting to Discord...")
						Discord_Client_Connect(manager.client)
					},
					nil,
					userData
				)
			}
		} else {
			print("❌ Failed to parse token data from Discord")
		}
	}

	private let authCallback: Discord_Client_AuthorizationCallback = {
		result, code, redirectUri, userData in
		let manager = Unmanaged<DiscordManager>.fromOpaque(userData!).takeUnretainedValue()

		guard let result = result else {
			manager.handleError("Authentication failed: No result received")
			return
		}

		if !Discord_ClientResult_Successful(result) {
			var errorStr = Discord_String()
			Discord_ClientResult_Error(result, &errorStr)
			if let errorPtr = errorStr.ptr,
				let messageStr = String(
					bytes: UnsafeRawBufferPointer(
						start: errorPtr,
						count: Int(errorStr.size)
					),
					encoding: .utf8
				)
			{
				manager.handleError("Authentication Error: \(messageStr)")
			} else {
				manager.handleError("Authentication failed with unknown error")
			}
			return
		}

		guard var verifier = manager.verifier else {
			manager.handleError("❌ Authentication Error: No verifier available")
			return
		}

		var verifierStr = Discord_String()
		Discord_AuthorizationCodeVerifier_Verifier(&verifier, &verifierStr)

		// Token exchange callback
		let tokenCallback: Discord_Client_TokenExchangeCallback = {
			result, token, refreshToken, tokenType, expiresIn, scope, userData in
			let manager = Unmanaged<DiscordManager>.fromOpaque(userData!).takeUnretainedValue()

			if let tokenPtr = token.ptr,
				let refreshPtr = refreshToken.ptr,
				let tokenStr = String(
					bytes: UnsafeRawBufferPointer(start: tokenPtr, count: Int(token.size)),
					encoding: .utf8),
				let refreshStr = String(
					bytes: UnsafeRawBufferPointer(start: refreshPtr, count: Int(refreshToken.size)),
					encoding: .utf8)
			{
				print("🎟️ Received token from auth flow")

				// Save token first
				Task { @MainActor in
					await manager.updateStoredToken(
						accessToken: tokenStr,
						refreshToken: refreshStr,
						expiresIn: TimeInterval(expiresIn)
					)

					// Then update client token
					print("🔑 Updating client with new token...")
					let accessStr = manager.makeDiscordString(from: tokenStr)
					Discord_Client_UpdateToken(
						manager.client,
						Discord_AuthorizationTokenType_Bearer,
						token,
						{ result, userData in
							print("🔌 Connecting with new token...")
							let manager = Unmanaged<DiscordManager>.fromOpaque(userData!)
								.takeUnretainedValue()
							Discord_Client_Connect(manager.client)
						},
						nil,
						userData
					)
				}
			}
		}

		Discord_Client_GetToken(
			manager.client,
			manager.applicationId,
			code,
			verifierStr,
			redirectUri,
			tokenCallback,
			nil,
			userData
		)
	}

	deinit {
		// Stop timer synchronously
		updateTimer?.invalidate()
		updateTimer = nil

		// Clear state
		currentPlaybackInfo = nil
		lastTitle = ""
		lastArtist = ""
		lastArtwork = nil
		lastDuration = 0
		lastCurrentTime = 0

		// Clear client
		if let client = client {
			// Basic presence clear without callback
			var activity = Discord_Activity()
			Discord_Activity_Init(&activity)
			Discord_Client_UpdateRichPresence(client, &activity, nil, nil, nil)

			Discord_Client_Drop(client)
			client.deallocate()
		}
	}
}
