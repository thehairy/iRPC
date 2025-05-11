import Foundation
import SwiftData

@Model
public final class DiscordToken {
	// Remove unique constraint but keep as identifier
	public var tokenId: String = UUID().uuidString
	public var accessToken: String?
	public var refreshToken: String?
	public var expiresAt: Date?
	public var initialExpiresIn: TimeInterval = 0

	public init(accessToken: String, refreshToken: String, expiresIn: TimeInterval) {
		self.accessToken = accessToken
		self.refreshToken = refreshToken
		self.expiresAt = Date().addingTimeInterval(expiresIn)
		self.initialExpiresIn = expiresIn
	}

	public var isValid: Bool {
        guard accessToken != nil else { return false }
		guard let expiresAt = expiresAt else { return false }
		let timeUntilExpiry = expiresAt.timeIntervalSinceNow
		let isValid = timeUntilExpiry > 0

		print("🔒 Token validity check:")
		print("- Expires in: \(Int(timeUntilExpiry))s")
		print("- Valid: \(isValid)")

		return isValid
	}

	public var needsRefresh: Bool {
		guard let accessToken = accessToken, !accessToken.isEmpty,
			let refreshToken = refreshToken, !refreshToken.isEmpty,
			let expiresAt = expiresAt
		else { return true }
		let timeUntilExpiry = expiresAt.timeIntervalSinceNow
		let needsRefresh = timeUntilExpiry < (initialExpiresIn / 2)

		print("🔄 Token refresh check:")
		print("- Time until expiry: \(Int(timeUntilExpiry))s")
		print("- Initial TTL: \(Int(initialExpiresIn))s")
		print("- Needs refresh: \(needsRefresh)")

		return needsRefresh
	}

	public var description: String {
		return
			"DiscordToken(expires: \(String(describing: expiresAt)), needsRefresh: \(needsRefresh))"
	}
}
