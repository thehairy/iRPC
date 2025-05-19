//
//  UIComponents.swift
//  iRPC
//
//  Created by Adrian Castro on 19/5/25.
//

import SwiftUI
import NowPlayingKit

// Make all components public so they can be used from ContentView.swift
public struct AuthorizationView: View {
    let requestAuthorization: () async -> Void

    public init(requestAuthorization: @escaping () async -> Void) {
        self.requestAuthorization = requestAuthorization
    }

    public var body: some View {
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

// Discord connection status indicator
public struct ConnectionStatusView: View {
    let isAuthenticated: Bool
    let isReady: Bool
    let username: String?
    
    public init(isAuthenticated: Bool, isReady: Bool, username: String?) {
        self.isAuthenticated = isAuthenticated
        self.isReady = isReady
        self.username = username
    }
    
    public var body: some View {
        HStack(spacing: 4) {
            if !isAuthenticated {
                Text("Not Connected")
                    .foregroundStyle(.secondary)
            } else if !isReady {
                Text("Connecting")
                    .foregroundStyle(.secondary)
                ProgressView()
                    .scaleEffect(0.7)
            } else {
                Text("Connected")
                    .foregroundStyle(.green)
                if let username = username {
                    Text("as \(username)")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

// Footer view for Discord connection status
public struct ConnectionFooterView: View {
    let isAuthenticated: Bool
    let isReady: Bool
    let isPlaying: Bool
    let showRPCToggle: Bool
    let userEnabledRPC: Bool

    public init(isAuthenticated: Bool, isReady: Bool, isPlaying: Bool, showRPCToggle: Bool, userEnabledRPC: Bool) {
        self.isAuthenticated = isAuthenticated
        self.isReady = isReady
        self.isPlaying = isPlaying
        self.showRPCToggle = showRPCToggle
        self.userEnabledRPC = userEnabledRPC
    }

    public var body: some View {
        if !isAuthenticated {
            Text("Sign in with Discord to share your music status.")
        } else if !isReady {
            Text("Establishing connection to Discord...")
        } else {
            if showRPCToggle {
                if userEnabledRPC {
                    if isPlaying {
                        Text("Sharing your music status on Discord.")
                    } else {
                        Text("Waiting for music to play...")
                    }
                } else {
                    Text("Enable Rich Presence to share your music status.")
                }
            } else {
                Text("Start playing music to enable Rich Presence.")
            }
        }
    }
}
