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

		// Set up status callback
		let statusCallback: Discord_Client_OnStatusChanged = {
			status, error, errorDetail, userData in
			let manager = Unmanaged<DiscordManager>.fromOpaque(userData!).takeUnretainedValue()
			print("🔄 Status changed: \(status)")

			DispatchQueue.main.async {
				if status == Discord_Client_Status_Ready {
					print("✅ Client is ready!")
					manager.isReady = true
				} else if status == Discord_Client_Status_Connected {
					print("🔗 Client connected!")
					manager.isAuthenticated = true
					manager.isAuthorizing = false
				}
			}
		}

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
		guard let result = result else {
			let manager = Unmanaged<DiscordManager>.fromOpaque(userData!).takeUnretainedValue()
			manager.handleError("Authentication failed: No result received")
			return
		}

		if !Discord_ClientResult_Successful(result) {
			var errorStr = Discord_String()
			Discord_ClientResult_Error(result, &errorStr)
			let manager = Unmanaged<DiscordManager>.fromOpaque(userData!).takeUnretainedValue()

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

		let manager = Unmanaged<DiscordManager>.fromOpaque(userData!).takeUnretainedValue()
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
		if let client = client {
			Discord_Client_Drop(client)
			client.deallocate()
		}
	}
}
