//
//  DiscordSocialKit.swift
//  DiscordSocialKit
//
//  Created by Adrian Castro on 8/5/25.
//

import Combine
import Foundation
import discord_partner_sdk

public final class DiscordManager: ObservableObject {
	private var client: UnsafeMutablePointer<Discord_Client>?
	private var applicationId: UInt64
	private var verifier: Discord_AuthorizationCodeVerifier?

	@Published public private(set) var isReady = false
	@Published public private(set) var isAuthenticated = false
	@Published public private(set) var errorMessage: String? = nil
	@Published public private(set) var isAuthorizing = false

	private var updateTimer: Timer?
	private var lastTitle: String = ""
	private var lastArtist: String = ""
	private var lastArtwork: URL? = nil
	private var lastDuration: TimeInterval = 0
	private var lastCurrentTime: TimeInterval = 0

	private var currentPlaybackInfo:
		(
			title: String, artist: String, duration: TimeInterval, currentTime: TimeInterval,
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

		// Start presence update timer
		Timer.scheduledTimer(withTimeInterval: presenceUpdateInterval, repeats: true) {
			[weak self] _ in
			guard let self = self,
				let info = self.currentPlaybackInfo,
				self.isAuthenticated,
				self.isReady
			else { return }

			self.updateRichPresence(
				title: info.title,
				artist: info.artist,
				duration: info.duration,
				currentTime: info.currentTime,
				artworkURL: info.artworkURL
			)
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
		guard let client = client, isAuthenticated else { return }

		var activity = Discord_Activity()
		Discord_Activity_Init(&activity)

		let callback:
			@convention(c) (UnsafeMutablePointer<Discord_ClientResult>?, UnsafeMutableRawPointer?)
				-> Void = { result, _ in
					if let result = result, Discord_ClientResult_Successful(result) {
						print("🧹 Rich Presence cleared")
					}
				}

		Discord_Client_UpdateRichPresence(client, &activity, callback, nil, nil)
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

	public func updateRichPresence(
		title: String, artist: String, duration: TimeInterval, currentTime: TimeInterval,
		artworkURL: URL? = nil
	) {
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
//		Discord_Activity_SetType(&activity, Discord_ActivityTypes_Listening)
        Discord_Activity_SetType(&activity, Discord_ActivityTypes_Playing)

		// Create and set name
		let namePtr = makeStringBuffer(from: "Apple Music")
		var nameStr = Discord_String()
		nameStr.ptr = namePtr
		nameStr.size = Int(Int32(4))
		Discord_Activity_SetName(&activity, nameStr)

		// Set details (title)
		let detailsPtr = makeStringBuffer(from: title)
		var detailsStr = Discord_String()
		detailsStr.ptr = detailsPtr
		detailsStr.size = Int(Int32(title.utf8.count))
		Discord_Activity_SetDetails(&activity, &detailsStr)

		// Set state (artist)
		let statePtr = makeStringBuffer(from: "by \(artist)")
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
		title: String,
		artist: String,
		duration: TimeInterval,
		currentTime: TimeInterval,
		artworkURL: URL?
	) {
		currentPlaybackInfo = (title, artist, duration, currentTime, artworkURL)
	}

	public func clearPlayback() {
		currentPlaybackInfo = nil
		clearRichPresence()
	}

	private func makeStringBuffer(from string: String) -> UnsafeMutablePointer<UInt8> {
		let data = Array(string.utf8) + [0]
		let ptr = UnsafeMutablePointer<UInt8>.allocate(capacity: data.count)
		ptr.initialize(from: data, count: data.count)
		return ptr
	}

	private func refreshRichPresence() {
		updateRichPresence(
			title: lastTitle,
			artist: lastArtist,
			duration: lastDuration,
			currentTime: lastCurrentTime,
			artworkURL: lastArtwork
		)
	}

	private func stopUpdates() {
		updateTimer?.invalidate()
		updateTimer = nil
		clearRichPresence()
	}

	private func handleError(_ message: String) {
		DispatchQueue.main.async {
			self.errorMessage = message
			self.isReady = false
			self.isAuthenticated = false
			self.isAuthorizing = false
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

			// Update token and connect
			let updateCallback:
				@convention(c) (
					UnsafeMutablePointer<Discord_ClientResult>?, UnsafeMutableRawPointer?
				) -> Void = { result, userData in
					let manager = Unmanaged<DiscordManager>.fromOpaque(userData!)
						.takeUnretainedValue()
					print("🔑 Token updated, connecting to Discord...")
					Discord_Client_Connect(manager.client)
				}

			Discord_Client_UpdateToken(
				manager.client,
				Discord_AuthorizationTokenType_Bearer,
				token,
				updateCallback,
				nil,
				userData
			)
		}

		Discord_Client_GetToken(
			manager.client, manager.applicationId, code, verifierStr, redirectUri,
			tokenCallback,
			nil,
			userData
		)
	}

	deinit {
		stopUpdates()
		if let client = client {
			Discord_Client_Drop(client)
			client.deallocate()
		}
	}
}
