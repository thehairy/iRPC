import Foundation
import SwiftData

@Model
public final class DiscordToken {
	var accessToken: String
	var refreshToken: String
	var expiresAt: Date
	private var initialExpiresIn: TimeInterval = 0

	init(accessToken: String, refreshToken: String, expiresIn: TimeInterval) {
		self.accessToken = accessToken
		self.refreshToken = refreshToken
		self.expiresAt = Date().addingTimeInterval(expiresIn)
		self.initialExpiresIn = expiresIn
	}

	var needsRefresh: Bool {
		// Get time until expiry
		let timeUntilExpiry = expiresAt.timeIntervalSince(Date())
		// If more than 50% of the total TTL has passed, refresh needed
		return timeUntilExpiry < (initialExpiresIn / 2)
	}
}
