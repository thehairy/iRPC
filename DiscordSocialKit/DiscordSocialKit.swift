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

	// Store callback references to prevent deallocation
	private let statusCallback: Discord_Client_OnStatusChanged = {
		status, error, errorDetail, userData in
		if status == Discord_Client_Status_Ready {
			let manager = Unmanaged<DiscordManager>.fromOpaque(userData!).takeUnretainedValue()
			DispatchQueue.main.async {
				manager.isReady = true
			}
		}
	}

	private let authCallback: Discord_Client_AuthorizationCallback = {
		result, code, redirectUri, userData in
		guard let result = result, Discord_ClientResult_Successful(result) else {
			print("❌ Authentication Error")
			return
		}

		let manager = Unmanaged<DiscordManager>.fromOpaque(userData!).takeUnretainedValue()
		guard var verifier = manager.verifier else { return }

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
					Discord_RunCallbacks()

					DispatchQueue.main.async {
						manager.isAuthenticated = true
					}
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

	@Published public private(set) var isReady = false
	@Published public private(set) var isAuthenticated = false

	public init(applicationId: UInt64) {
		self.applicationId = applicationId
		setupClient()
	}

	private func setupClient() {
		var client = Discord_Client()
		Discord_Client_Init(&client)
		self.client = withUnsafeMutablePointer(to: &client) { $0 }

		guard let client = self.client else { return }

		Discord_Client_SetApplicationId(client, applicationId)

		// Add logging callback
		let logCallback: Discord_Client_LogCallback = { message, severity, userData in
			let severityStr =
				severity == Discord_LoggingSeverity_Info
				? "INFO"
				: severity == Discord_LoggingSeverity_Warning
					? "WARN" : severity == Discord_LoggingSeverity_Error ? "ERROR" : "DEBUG"
			print("[Discord \(severityStr)] \(message)")
		}
		Discord_Client_AddLogCallback(client, logCallback, nil, nil, Discord_LoggingSeverity_Info)

		// Add status callback
		let userDataPtr = Unmanaged.passRetained(self).toOpaque()
		Discord_Client_SetStatusChangedCallback(client, statusCallback, nil, userDataPtr)

		// Start OAuth2 flow
		var verifier = Discord_AuthorizationCodeVerifier()
		Discord_Client_CreateAuthorizationCodeVerifier(client, &verifier)
		self.verifier = verifier

		var args = Discord_AuthorizationArgs()
		Discord_AuthorizationArgs_Init(&args)

		Discord_AuthorizationArgs_SetClientId(&args, applicationId)

		var scopes = Discord_String()
		Discord_Client_GetDefaultPresenceScopes(&scopes)
		Discord_AuthorizationArgs_SetScopes(&args, scopes)

		var challenge = Discord_AuthorizationCodeChallenge()
		Discord_AuthorizationCodeVerifier_Challenge(&verifier, &challenge)
		Discord_AuthorizationArgs_SetCodeChallenge(&args, &challenge)

		// Authorization callback
		Discord_Client_Authorize(client, &args, authCallback, nil, userDataPtr)

		// Start callback loop
		DispatchQueue.global(qos: .utility).async { [weak self] in
			while self != nil {
				Discord_RunCallbacks()
				Thread.sleep(forTimeInterval: 0.01)
			}
		}
	}

	public func authorize() {
		guard let client = client else { return }

		var args = Discord_AuthorizationArgs()
		Discord_AuthorizationArgs_Init(&args)

		var verifier = Discord_AuthorizationCodeVerifier()
		Discord_Client_CreateAuthorizationCodeVerifier(client, &verifier)
		self.verifier = verifier

		Discord_AuthorizationArgs_SetClientId(&args, applicationId)

		var scopes = Discord_String()
		Discord_Client_GetDefaultPresenceScopes(&scopes)
		Discord_AuthorizationArgs_SetScopes(&args, scopes)

		var challenge = Discord_AuthorizationCodeChallenge()
		Discord_AuthorizationCodeVerifier_Challenge(&verifier, &challenge)
		Discord_AuthorizationArgs_SetCodeChallenge(&args, &challenge)

		let userDataPtr = Unmanaged.passRetained(self).toOpaque()
		Discord_Client_Authorize(client, &args, authCallback, nil, userDataPtr)
	}

	deinit {
		if let client = client {
			Discord_Client_Drop(client)
		}
	}
}
