//
//  MenuContentView.swift
//  iRPC
//
//  Created by Sören Stabenow on 27.04.25.
//

import SwiftUI
import LaunchAtLogin

// Shared notification name used to trigger a presence update, e.g., when settings change.
extension Notification.Name {
    static let refreshDiscordPresence = Notification.Name("refreshDiscordPresenceNotification")
}

/// The SwiftUI view displayed within the menu bar popover.
///
/// Shows connection status, current song information (if available), controls for app settings
/// (Launch at Login, Show Album Art, Show Buttons), and a Quit button.
struct MenuContentView: View {

    // MARK: - State Properties

    /// Tracks the current connection status reported by `DiscordRPC.shared`.
    @State private var isConnected: Bool = false
    /// Stores the reason for connection failure, if any, from `DiscordRPC.shared`.
    @State private var isFailedReason: DiscordRPCError?
    /// Observes and allows modification of shared application settings.
    @StateObject private var settings = SettingsManager.shared // Assuming SettingsManager is an ObservableObject
    /// Holds the currently playing song information, updated periodically.
    @State private var currentSong: MusicInfo?

    // MARK: - Computed Properties for UI

    /// Provides a user-friendly string describing the current RPC connection status.
    private var connectionStatusText: String {
        if isConnected {
            return "Connected"
        } else if case .noSocketFound = isFailedReason {
            return "Connecting / Retrying..." // Changed from "Failed" for better UX during retries
        } else if case .sandboxed = isFailedReason {
            return "Failed – Sandboxed" // Unrecoverable error state
        } else if isFailedReason != nil {
             return "Failed" // Generic failure
        } else {
            return "Disconnected" // Initial state or manual disconnect
        }
    }

    /// Determines the color used for the connection status text.
    private var connectionStatusColor: Color {
        if isConnected {
            return .green // Use system green or a custom green
        } else if case .noSocketFound = isFailedReason {
            return .orange // Indicate a potentially recoverable state (retrying)
        } else {
            return .red // Indicate disconnected or failed state
        }
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 4) {
                Text("iRPC - Imagine an RPC")
                    .font(.headline)
                Text(connectionStatusText)
                    .font(.caption)
                    .foregroundColor(connectionStatusColor)
                    .transition(.opacity)
                    .fontWeight(.bold)
            }
            .padding(.bottom, 4)
            
            Divider()

            if let song = currentSong {
                Text(song.title)
                    .fontWeight(.bold)
                    .padding(.top, 5)
                Text(song.album)
                    .foregroundColor(.secondary)
                Text(song.artist)
                    .foregroundColor(.secondary)
                Text("\(formatTime(song.position)) / \(formatTime(song.duration))")
                    .foregroundColor(.secondary)
                    .opacity(0.8)
                    .padding(.bottom, 5)
            } else {
                Text("No music playing")
                    .foregroundColor(.secondary)
                    .padding(.vertical, 5)
            }

            Divider()
            
            Toggle("Launch at Login", isOn: $settings.launchAtLogin)
                .toggleStyle(CheckboxToggleStyle())
                .padding(.horizontal, 12)
                .onChange(of: settings.launchAtLogin) { _, new in
                    LaunchAtLogin.isEnabled = new
                }
                .padding(.top, 8)
                .padding(.bottom, 1)
            
            Toggle("Show Album Art", isOn: $settings.showAlbumArt)
                .toggleStyle(CheckboxToggleStyle())
                .padding(.horizontal, 12)
                .padding(.bottom, 1)
                .onChange(of: settings.showAlbumArt) { _, _ in
                    NotificationCenter.default.post(name: .refreshDiscordPresence, object: nil)
                }
            
            Toggle("Show Music Buttons", isOn: $settings.showButtons)
                .toggleStyle(CheckboxToggleStyle())
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
                .onChange(of: settings.showButtons) { _, _ in
                    NotificationCenter.default.post(name: .refreshDiscordPresence, object: nil)
                }
            
            Divider()

            MenuButton(title: "Quit", systemImage: "power.circle", shortcut: "⌘Q") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(.vertical, 8)
        .frame(width: 250)
        .onAppear {
            startMonitoringRPC()
            startMonitoringSong()
        }
    }

    // MARK: - Private Helper Methods

    /// Starts a timer to periodically update the `isConnected` and `isFailedReason` state
    /// based on the shared `DiscordRPC` instance.
    private func startMonitoringRPC() {
        // Set initial state immediately
        isConnected = DiscordRPC.shared.isConnected
        isFailedReason = DiscordRPC.shared.isFailedReason

        // Avoid starting timer if sandboxed (unrecoverable error)
        if case .sandboxed = isFailedReason {
            return
        }

        // Schedule repeating timer
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            isConnected = DiscordRPC.shared.isConnected
            isFailedReason = DiscordRPC.shared.isFailedReason
        }
    }

    /// Starts a timer to periodically fetch the currently playing song
    /// using `MusicController` and update the `currentSong` state.
    private func startMonitoringSong() {
        // Set initial state immediately
        currentSong = MusicController.getCurrentSong()

        // Schedule repeating timer
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            currentSong = MusicController.getCurrentSong()
        }
    }

    /// Formats a `TimeInterval` (in seconds) into a MM:SS string.
    private func formatTime(_ interval: TimeInterval) -> String {
        let totalSeconds = Int(max(0, interval)) // Ensure non-negative
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

// MARK: - Helper View: MenuButton

/// A reusable button styled for use in the menu bar popover,
/// including an icon, title, keyboard shortcut hint, and hover effect.
struct MenuButton: View {
    let title: String
    let systemImage: String
    let shortcut: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack {
                Image(systemName: systemImage)
                    .font(.system(size: 16, weight: .regular))
                Text(title)
                    .font(isHovering
                        ? .system(size: 14, weight: .bold)
                        : .system(size: 14, weight: .regular))
                Spacer()
                Text(shortcut)
                    .foregroundColor(.secondary)
                    .font(.system(size: 12))
            }
            .padding(.horizontal, 12)
            .frame(height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
    }
}
