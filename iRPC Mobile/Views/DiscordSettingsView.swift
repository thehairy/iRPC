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
                // Modified display logic to better handle cached user data
                if discord.isAuthenticated && viewModel.isUserDataLoaded {
                    // Show user profile when data is fully loaded
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
                    .id("profile-\(viewModel.refreshID)")
                } else if isAuthenticating || (discord.isAuthenticated && !viewModel.isUserDataLoaded) {
                    // Show loading view when authenticating or waiting for user data
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
                    .id("loading-\(viewModel.refreshID)")
                } else {
                    // Show authenticate button only when not authenticating AND not authenticated
                    Button {
                        // Set authenticating state BEFORE calling authorize
                        isAuthenticating = true
                        
                        // Start observing authentication changes
                        viewModel.startObservingAuthChanges()
                        
                        // Then initiate the authorization process
                        discord.authorize()
                    } label: {
                        Label("Connect Discord Account", systemImage: "person.badge.key.fill")
                    }
                }
            } header: {
                Text("Account")
            }

            // Only show reconnect button when fully authenticated with user data
            if discord.isAuthenticated && viewModel.isUserDataLoaded {
                Section {
                    Button(role: .destructive) {
                        // Set authenticating state BEFORE reconnecting
                        isAuthenticating = true
                        
                        // Start observing authentication changes
                        viewModel.startObservingAuthChanges()
                        
                        // Then reconnect
                        discord.authorize()
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
        .onAppear {
            // Check initial state immediately on appear
            viewModel.checkInitialState()
        }
        .onChange(of: discord.isAuthenticated) { _, newValue in
            if !newValue {
                // If authorization is revoked/lost, make sure we're not in authenticating state
                isAuthenticating = false
            }
            
            // Delegate to ViewModel
            viewModel.handleAuthenticationStateChange(newValue)
        }
        .onDisappear {
            // Use ViewModel to cleanup
            viewModel.cancelObservation()
        }
    }
}
