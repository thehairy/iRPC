//
//  ContentView.swift
//  iRPC Mobile
//
//  Created by Adrian Castro on 8/5/25.
//

// ContentView.swift

import Combine
import DiscordSocialKit
import NowPlayingKit
import SwiftData
import SwiftUI
import MusicKit
import MusadoraKit

struct ContentView: View {
    @State private var nowPlaying = NowPlayingData(id: "", title: "Loading...", artist: "")
    @State private var lastPlayed: Song?
    @State private var isShowingLastPlayed = false
    @State private var isAuthorized = false
    @State private var isLoading = true
    @State private var isAuthenticating = false
    @State private var userEnabledRPC = false
    @State private var showRPCToggle = false
    @StateObject private var discord = DiscordManager(applicationId: 1_370_062_110_272_520_313)
    private let manager = NowPlayingManager.shared
    @State private var lastUpdateTime: TimeInterval = 0
    private let updateInterval: TimeInterval = 1
    @Environment(\.modelContext) private var modelContext
    @State private var isMusicCurrentlyPlaying = false
    @State private var toggleRefreshTrigger = UUID()
    @State private var playbackSubscription: AnyCancellable?
    @State private var onAppearExecuted = false
    @State private var connectionCheckTimer: AnyCancellable?
    @State private var forceConnectionRefresh = UUID()

    // Direct state tracking to force UI updates
    @State private var isDiscordAuthenticated = false
    @State private var isDiscordReady = false
    @State private var discordUsername: String? = nil
    @State private var showDebugInfo = false  // Set to true to show debug info in UI

    private var timer: Publishers.Autoconnect<Timer.TimerPublisher> {
        Timer.publish(every: updateInterval, on: .main, in: .common).autoconnect()
    }

    enum ConnectionState: Equatable {
        case connecting
        case authenticating
        case connected(username: String?)
        case failed(error: String?)
        case disconnected

        static func == (lhs: ConnectionState, rhs: ConnectionState) -> Bool {
            switch (lhs, rhs) {
            case (.connecting, .connecting):
                return true
            case (.authenticating, .authenticating):
                return true
            case (.connected(let lhsUsername), .connected(let rhsUsername)):
                return lhsUsername == rhsUsername
            case (.failed(let lhsError), .failed(let rhsError)):
                return lhsError == rhsError
            case (.disconnected, .disconnected):
                return true
            default:
                return false
            }
        }
    }

    private var connectionState: ConnectionState {
        if discord.isAuthorizing || isAuthenticating || isLoading {
            return .connecting
        } else if isDiscordAuthenticated {  // Use our tracked state
            if isDiscordReady {  // Use our tracked state
                return .connected(username: discordUsername)
            } else {
                return .connecting
            }
        } else if let error = discord.errorMessage {
            return .failed(error: error)
        } else {
            return .disconnected
        }
    }

    private var shouldShowRPCToggle: Bool {
        discord.isAuthenticated && discord.isReady && (manager.isPlaying || userEnabledRPC)
    }

    var body: some View {
        NavigationStack {
            List {
                if !isAuthorized {
                    Section {
                        AuthorizationView(requestAuthorization: requestAuthorization)
                    }
                } else {
                    NowPlayingView(
                        nowPlaying: nowPlaying,
                        manager: manager,
                        isLastPlayed: isShowingLastPlayed
                    )
                }

                Section {
                    VStack(spacing: 8) {
                        HStack {
                            Image("Discord")
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 24, height: 24)

                            ConnectionStatusView(
                                isAuthenticated: isDiscordAuthenticated,
                                isReady: isDiscordReady,
                                username: discordUsername
                            )

                            Spacer()
                        }

                        // Debug info to show what's happening
                        if showDebugInfo {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Auth: \(discord.isAuthenticated ? "✅" : "❌")")
                                    Text("Ready: \(discord.isReady ? "✅" : "❌")")
                                    Text("User: \(discord.username ?? "none")")
                                }
                                .font(.caption)
                                .padding(6)
                                .background(Color.gray.opacity(0.2))
                                .cornerRadius(6)
                                Spacer()
                            }
                        }
                    }

                    if shouldShowRPCToggle {
                        Toggle("Enable Rich Presence", isOn: $userEnabledRPC)
                            .onChange(of: userEnabledRPC) { _, isEnabled in
                                withAnimation(.easeInOut(duration: 0.3)) {
                                    handleUserToggleRPC(enabled: isEnabled)
                                }
                            }
                            .id("toggle-\(toggleRefreshTrigger)")
                    }
                } header: {
                    Text("Discord Status")
                } footer: {
                    // Use ConnectionFooterView instead
                    ConnectionFooterView(
                        isAuthenticated: isDiscordAuthenticated,
                        isReady: isDiscordReady,
                        isPlaying: manager.isPlaying,
                        showRPCToggle: shouldShowRPCToggle,
                        userEnabledRPC: userEnabledRPC
                    )
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("iRPC")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        DiscordSettingsView(
                            discord: discord,
                            isAuthenticating: $isAuthenticating
                        )
                    } label: {
                        Label("Discord Settings", systemImage: "gear")
                    }
                }
            }
        }
        .onChange(of: manager.isPlaying) { _, newValue in
            print("🎵 Music playing state changed: \(newValue)")
            DispatchQueue.main.async {
                withAnimation(.easeInOut(duration: 0.3)) {
                    showRPCToggle = shouldShowRPCToggle
                }

                if newValue {
                    print("▶️ Music started playing - updating UI and Discord")
                    if userEnabledRPC && discord.isAuthenticated && discord.isReady {
                        Task { await updateDiscordWithCurrentSong() }
                    }
                } else {
                    print("⏸️ Music stopped playing")
                    if userEnabledRPC && discord.isAuthenticated {
                        print("🛑 Clearing Discord presence")
                        discord.clearPlayback()
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: SystemMusicPlayer.playbackStateDidChangeNotification)) { _ in
            print("🎵📣 System Music Player state changed!")
            handleMusicPlaybackStateChange()
        }
        .task(priority: .high) {
            isLoading = true
            await MainActor.run {
                discord.setModelContext(modelContext)
            }

            let hasExistingToken = await checkExistingToken()
            if hasExistingToken {
                isAuthenticating = true
                await discord.setupWithExistingToken()
            }
            isLoading = false
        }
        .task {
            await requestAuthorization()
            if isAuthorized {
                print("🎵 Music access authorized")
                await updateNowPlaying()
            }
            isLoading = false
        }
        .onReceive(timer) { _ in
            guard isAuthorized else { return }
            Task {
                await updatePlaybackTime()
            }
        }
        .onAppear {
            if !onAppearExecuted {
                onAppearExecuted = true
                DispatchQueue.main.async {
                    let isPlaying = manager.isPlaying
                    print("📱 Initial music state: \(isPlaying)")

                    withAnimation(.easeInOut(duration: 0.3)) {
                        showRPCToggle = discord.isAuthenticated &&
                                        discord.isReady &&
                                        (isPlaying || userEnabledRPC)
                    }

                    setupMusicStatusObservers()
                    setupConnectionMonitoring()
                }
            }
            handleMusicPlaybackStateChange()
        }
        .onReceive(Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()) { _ in
            updateTrackedDiscordState()
        }
    }

    private func setupMusicStatusObservers() {
        // Cancel any existing subscription
        playbackSubscription?.cancel()

        playbackSubscription = manager.playbackStatePublisher
            .receive(on: RunLoop.main)
            .sink { isPlaying in
                print("🎹 Playback state publisher update: \(isPlaying)")
                self.isMusicCurrentlyPlaying = isPlaying
                self.handleMusicPlaybackStateChange()
            }

        print("🎧 Music status observers setup complete")
    }

    private func setupConnectionMonitoring() {
        // Cancel any existing timer
        connectionCheckTimer?.cancel()
        
        connectionCheckTimer = Timer.publish(every: 0.5, on: .main, in: .common)
            .autoconnect()
            .sink { _ in
                // Always force refresh the connection state to ensure UI stays in sync
                self.updateTrackedDiscordState()
                
                let shouldShow = self.shouldShowRPCToggle
                if self.showRPCToggle != shouldShow {
                    DispatchQueue.main.async {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            self.showRPCToggle = shouldShow
                        }
                    }
                }
            }
            
        print("🔌 Discord connection monitoring started")
    }

    private func updateTrackedDiscordState() {
        // Directly update our state variables from Discord
        let authenticated = discord.isAuthenticated
        let ready = discord.isReady
        let username = discord.username
        
        // Only update UI if values have changed
        if isDiscordAuthenticated != authenticated || 
           isDiscordReady != ready ||
           discordUsername != username {
            
            print("🔄 Discord state changed: Auth=\(authenticated) Ready=\(ready) User=\(username ?? "none")")
            
            // Update our tracked state
            isDiscordAuthenticated = authenticated
            isDiscordReady = ready
            discordUsername = username
            
            // Force UI refresh
            forceConnectionRefresh = UUID()
        }
    }

    private func handleMusicPlaybackStateChange() {
        let isCurrentlyPlaying = manager.isPlaying

        print("🎮 Handling music state change: \(isCurrentlyPlaying ? "playing" : "paused")")

        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.3)) {
                let shouldShow = self.discord.isAuthenticated &&
                                self.discord.isReady &&
                                (isCurrentlyPlaying || self.userEnabledRPC)

                self.showRPCToggle = shouldShow
                self.toggleRefreshTrigger = UUID()
            }

            if isCurrentlyPlaying {
                if self.userEnabledRPC && self.discord.isAuthenticated && self.discord.isReady {
                    Task { await self.updateDiscordWithCurrentSong() }
                }
            } else {
                if self.userEnabledRPC && self.discord.isAuthenticated {
                    self.discord.clearPlayback()
                }
            }

            Task { await self.updateNowPlaying() }
        }
    }

    private func updateToggleVisibility() {
        let shouldShow = shouldShowRPCToggle
        if showRPCToggle != shouldShow {
            DispatchQueue.main.async {
                withAnimation(.easeInOut(duration: 0.3)) {
                    self.showRPCToggle = shouldShow
                }
            }
        }
    }

    private func forceShowToggle() {
        guard discord.isAuthenticated && discord.isReady else {
            print("⚠️ Cannot show toggle - Discord not ready/authenticated")
            return
        }

        DispatchQueue.main.async {
            withAnimation(.easeInOut) {
                self.showRPCToggle = true
                print("🎯 Forcing toggle visibility to true")
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                withAnimation(.easeInOut) {
                    self.showRPCToggle = true
                }
            }
        }
    }

    private func checkMusicPlaybackState() {
        let isPlaying = manager.isPlaying

        print("🔎 Checking music state: \(isPlaying ? "playing" : "not playing")")

        let shouldShow = discord.isAuthenticated && discord.isReady && (isPlaying || userEnabledRPC)

        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.3)) {
                self.showRPCToggle = shouldShow

                if isPlaying && shouldShow && self.userEnabledRPC {
                    Task { await self.updateDiscordWithCurrentSong() }
                }
            }
        }
    }

    private func updateNowPlaying() async {
        // Check if music is playing first
        if !manager.isPlaying {
            // Not playing, so attempt to show the last played song
            do {
                let recentSongs = try await MHistory.recentlyPlayedSongs(limit: 1)
                if let lastSong = recentSongs.first {
                    await MainActor.run {
                        print("🎵 No active playback, showing last played: \(lastSong.title)")
                        lastPlayed = lastSong
                        isShowingLastPlayed = true
                        
                        // Update nowPlaying with last played info
                        nowPlaying = NowPlayingData(
                            id: lastSong.id.rawValue,
                            title: lastSong.title,
                            artist: lastSong.artistName,
                            album: lastSong.albumTitle,
                            artworkURL: lastSong.artwork?.url(width: 300, height: 300),
                            playbackTime: 0,
                            duration: lastSong.duration ?? 0
                        )
                        
                        if userEnabledRPC && discord.isAuthenticated {
                            discord.clearPlayback()
                        }
                    }
                } else {
                    await showNoSongPlaying()
                }
            } catch {
                print("⚠️ Failed to get recently played: \(error.localizedDescription)")
                await showNoSongPlaying()
            }
            return
        }
        
        // Music is actively playing, get current playback
        do {
            let newPlayback = try await manager.getCurrentPlayback()
            await MainActor.run {
                isShowingLastPlayed = false
                nowPlaying = newPlayback
                print("🎵 Now Playing updated: \(newPlayback.title)")

                if userEnabledRPC && discord.isAuthenticated && discord.isReady && manager.isPlaying {
                    updateDiscordDirectly(with: newPlayback)
                }

                updateToggleVisibility()
            }
        } catch {
            print("⚠️ Error getting now playing: \(error.localizedDescription)")
            await showNoSongPlaying()
        }
    }
    
    private func showNoSongPlaying() async {
        await MainActor.run {
            isShowingLastPlayed = false
            nowPlaying = NowPlayingData(id: "", title: "No song playing", artist: "")
            
            if userEnabledRPC && discord.isAuthenticated {
                discord.clearPlayback()
            }
        }
    }

    private func updateDiscordDirectly(with playback: NowPlayingData) {
        discord.updateCurrentPlayback(
            id: playback.id,
            title: playback.title,
            artist: playback.artist,
            duration: playback.duration,
            currentTime: playback.playbackTime,
            artworkURL: playback.artworkURL
        )
    }

    private func updatePlaybackTime() async {
        do {
            let current = try await manager.getCurrentPlayback()
            await MainActor.run {
                nowPlaying = current

                if userEnabledRPC && discord.isAuthenticated && discord.isReady && manager.isPlaying {
                    updateDiscordDirectly(with: current)
                }
            }
        } catch {
        }
    }

    private func updateDiscordWithCurrentSong() async {
        do {
            guard manager.isPlaying else {
                print("⚠️ Not updating Discord - music not playing")
                return
            }

            let current = try await manager.getCurrentPlayback()
            await MainActor.run {
                print("🎮 Updating Discord with: \(current.title)")
                updateDiscordDirectly(with: current)
            }
        } catch {
            print("⚠️ Failed to update Discord: \(error.localizedDescription)")
        }
    }

    private func handleUserToggleRPC(enabled: Bool) {
        print("🎮 User toggled Discord RPC: \(enabled ? "ON" : "OFF")")

        if enabled {
            discord.startPresenceUpdates()
            if manager.isPlaying {
                Task { await updateDiscordWithCurrentSong() }
            }
            BackgroundController.shared.start()
        } else {
            discord.stopPresenceUpdates()
            BackgroundController.shared.stop()
        }
    }

    private func requestAuthorization() async {
        let status = await manager.authorize()
        isAuthorized = status == .authorized
    }

    private func checkExistingToken() async -> Bool {
        var descriptor = FetchDescriptor<DiscordToken>(
            sortBy: [SortDescriptor(\DiscordToken.expiresAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1

        do {
            if let token = try modelContext.fetch(descriptor).first {
                print("🔍 Found existing token with ID: \(token.tokenId)")
                return true
            }
            print("ℹ️ No existing token found")
            return false
        } catch {
            print("❌ Failed to check for existing token: \(error)")
            return false
        }
    }
}

extension View {
    fileprivate func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

// MARK: - Subviews
private struct AuthorizationView: View {
    let requestAuthorization: () async -> Void

    var body: some View {
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

private struct NowPlayingView: View {
    let nowPlaying: NowPlayingData
    let manager: NowPlayingManager
    let isLastPlayed: Bool
    
    // Updated initializer with default parameter
    init(nowPlaying: NowPlayingData, manager: NowPlayingManager, isLastPlayed: Bool = false) {
        self.nowPlaying = nowPlaying
        self.manager = manager
        self.isLastPlayed = isLastPlayed
    }

    var body: some View {
        Section {
            if nowPlaying.title == "Loading..." {
                VStack(spacing: 16) {
                    ProgressView()
                        .controlSize(.large)
                    Text("Loading Music...")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 200)
            } else if nowPlaying.title == "No song playing" {
                VStack(spacing: 16) {
                    Image(systemName: "music.note.list")
                        .font(.system(size: 50))
                        .foregroundStyle(.secondary)
                    
                    Text("No Music Playing")
                        .font(.title3)
                        .bold()
                    
                    Text("Play a song to see it here")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 200)
            } else {
                VStack(alignment: .center, spacing: 16) {
                    // Show last played banner if applicable
                    if isLastPlayed {
                        HStack {
                            Image(systemName: "clock.arrow.circlepath")
                            Text("Last Played")
                                .font(.caption)
                                .bold()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.secondary.opacity(0.2))
                        .cornerRadius(20)
                    }
                    
                    // ...existing artwork display code...
                    if let artworkURL = nowPlaying.artworkURL {
                        AsyncImage(url: artworkURL) { phase in
                            switch phase {
                            case .success(let image):
                                image
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(height: 300)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                            default:
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(.secondary.opacity(0.1))
                                    .frame(height: 300)
                                    .overlay {
                                        ProgressView()
                                    }
                            }
                        }
                    }

                    VStack(spacing: 8) {
                        Text(nowPlaying.title)
                            .font(.title3)
                            .bold()
                            .lineLimit(1)

                        Text(nowPlaying.artist)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)

                        if let album = nowPlaying.album {
                            Text(album)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }

                    // Only show progress if not showing last played
                    if !isLastPlayed {
                        VStack(spacing: 8) {
                            ProgressView(value: nowPlaying.playbackTime, total: nowPlaying.duration)
                                .tint(.blue)

                            HStack {
                                Text(formatTime(nowPlaying.playbackTime))
                                Spacer()
                                Text(formatTime(nowPlaying.duration))
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
                .listRowInsets(EdgeInsets())
                .padding()
            }
        }
    }
}

// Update DiscordSettingsView to use the ViewModel
private struct DiscordSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    let discord: DiscordManager
    @Binding var isAuthenticating: Bool
    
    // Replace state variables with a StateObject ViewModel
    @StateObject private var viewModel: DiscordSettingsViewModel
    
    init(discord: DiscordManager, isAuthenticating: Binding<Bool>) {
        self.discord = discord
        self._isAuthenticating = isAuthenticating
        // Initialize the ViewModel
        self._viewModel = StateObject(wrappedValue: DiscordSettingsViewModel(
            discord: discord,
            isAuthenticating: isAuthenticating
        ))
    }

    var body: some View {
        List {
            Section {
                if discord.isAuthenticated {
                    if viewModel.isUserDataLoaded {
                        // Show user profile when data is loaded
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
                    } else {
                        // Show loading view while waiting for user data
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
                    }
                } else {
                    Button {
                        isAuthenticating = true
                        discord.authorize()
                        // Use ViewModel to start observing auth changes
                        viewModel.startObservingAuthChanges()
                    } label: {
                        Label("Connect Discord Account", systemImage: "person.badge.key.fill")
                    }
                }
            } header: {
                Text("Account")
            }

            if discord.isAuthenticated {
                Section {
                    Button(role: .destructive) {
                        discord.authorize()
                        // Use ViewModel to start observing auth changes
                        viewModel.startObservingAuthChanges()
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
            // Let ViewModel check initial state
            viewModel.checkInitialState()
        }
        .onChange(of: discord.isAuthenticated) { _, newValue in
            // Delegate to ViewModel
            viewModel.handleAuthenticationStateChange(newValue)
        }
        .onDisappear {
            // Use ViewModel to cleanup
            viewModel.cancelObservation()
        }
    }
}

private struct ConnectionStatusView: View {
    let isAuthenticated: Bool
    let isReady: Bool
    let username: String?
    
    var body: some View {
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

private struct ConnectionFooterView: View {
    let isAuthenticated: Bool
    let isReady: Bool
    let isPlaying: Bool
    let showRPCToggle: Bool
    let userEnabledRPC: Bool

    var body: some View {
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
