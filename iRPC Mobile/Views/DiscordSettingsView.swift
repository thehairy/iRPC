//
//  DiscordSettingsView.swift
//  iRPC
//
//  Created by Adrian Castro on 19/5/25.
//

import Foundation
import SwiftUI
import DiscordSocialKit
import Combine

public struct DiscordSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    let discord: DiscordManager
    @Binding var isAuthenticating: Bool
    
    @StateObject private var viewModel: DiscordSettingsViewModel
    
    private var isShowingUserProfile: Bool {
        discord.isAuthenticated && viewModel.isUserDataLoaded
    }
    
    private var isShowingLoadingState: Bool {
        isAuthenticating || (discord.isAuthenticated && !viewModel.isUserDataLoaded)
    }
    
    private var isShowingConnectButton: Bool {
        !isAuthenticating && !discord.isAuthenticated
    }
    
    private var canShowReconnectButton: Bool {
        discord.isAuthenticated && viewModel.isUserDataLoaded
    }
    
    public init(discord: DiscordManager, isAuthenticating: Binding<Bool>) {
        self.discord = discord
        self._isAuthenticating = isAuthenticating
        self._viewModel = StateObject(wrappedValue: DiscordSettingsViewModel(
            discord: discord,
            isAuthenticating: isAuthenticating
        ))
    }
    
    public var body: some View {
        List {
            Section {
                if isShowingUserProfile {
                    UserProfileView(
                        avatarURL: discord.avatarURL,
                        name: discord.globalName ?? discord.username ?? "",
                        username: discord.username ?? "",
                        refreshID: viewModel.refreshID
                    )
                } else if isShowingLoadingState {
                    LoadingAccountView(refreshID: viewModel.refreshID)
                } else {
                    ConnectAccountButton(action: initiateAuthentication)
                }
            } header: {
                Text("Account")
            }

            // Only show reconnect button when fully authenticated with user data
            if canShowReconnectButton {
                Section {
                    ReconnectButton(action: initiateAuthentication)
                } footer: {
                    Text("Use this if you're having connection issues.")
                }
            }
        }
        .navigationTitle("Discord Settings")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            viewModel.checkInitialState()
        }
        .onChange(of: discord.isAuthenticated) { _, newValue in
            if !newValue {
                isAuthenticating = false
            }
            viewModel.handleAuthenticationStateChange(newValue)
        }
        .onDisappear {
            viewModel.cancelObservation()
        }
    }
    
    // Extract authentication flow into a separate function
    private func initiateAuthentication() {
        isAuthenticating = true
        viewModel.startObservingAuthChanges()
        discord.authorize()
    }
}

// Extract UI components as private structs
private struct UserProfileView: View {
    let avatarURL: URL?
    let name: String
    let username: String
    let refreshID: UUID
    
    var body: some View {
        HStack(spacing: 12) {
            if let avatarURL = avatarURL {
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
                Text(name)
                    .font(.headline)

                Text("@\(username)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.vertical, 4)
        .id(refreshID)
    }
}

private struct LoadingAccountView: View {
    let refreshID: UUID
    
    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(.secondary.opacity(0.2))
                .frame(width: 48, height: 48)
                .overlay {
                    ProgressView()
                        .controlSize(.small)
                }
            
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("Loading account...")
                        .font(.headline)
                        .foregroundColor(.secondary)
                    ProgressView()
                        .controlSize(.small)
                }
                
                Text("Please wait...")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
        }
        .padding(.vertical, 4)
        .id("loading-\(refreshID)")
    }
}

private struct ConnectAccountButton: View {
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            Label("Connect Discord Account", systemImage: "person.badge.key.fill")
        }
    }
}

private struct ReconnectButton: View {
    let action: () -> Void
    
    var body: some View {
        Button(role: .destructive, action: action) {
            Label("Reconnect Account", systemImage: "arrow.clockwise")
        }
    }
}
