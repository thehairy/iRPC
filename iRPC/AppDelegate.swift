//
//  AppDelegate.swift
//  iRPC
//
//  Created by Sören Stabenow on 27.04.25.
//

import SwiftUI
import DiscordRPCKit
import ScrobbleKit

/// Main application delegate responsible for setting up the status bar item,
/// managing the popover window, handling the Discord RPC connection lifecycle,
/// and periodically updating the Rich Presence based on music playback.
class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {

    // MARK: - UI Properties

    private var statusItem: NSStatusItem!
    private var popover = NSPopover()
    private var eventMonitor: Any? // Monitors clicks outside the popover to close it

    // MARK: - State Properties

    /// Stores the details of the last successfully sent presence update to avoid redundant updates.
    private struct PresenceData: Equatable {
        let title: String
        let artist: String
        let album: String
        let startTimestamp: Int
    }
    private var lastPresence: PresenceData?

    private var discordRPC: DiscordRPC!
    
    // MARK: - ScrobbleKit Properties
    
    /// ScrobbleKit manager for LastFM integration
    private var scrobbleManager: SBKManager?
    /// Timestamp when current track started playing (for scrobble duration calculation)
    private var currentTrackStartTime: Date?
    /// Info about the currently playing track for scrobbling purposes
    private var currentScrobbleTrack: MusicInfo?

    // MARK: - Timers

    /// Timer used to retry connecting to Discord if the initial connection fails or is lost.
    private var retryTimer: Timer?
    /// Timer responsible for periodically checking the current music state and updating Discord presence.
    private var musicTimer: Timer?
    
    private let settings = SettingsManager.shared

    // MARK: - NSApplicationDelegate Methods

    /// Called when the application finishes launching. Sets up the status bar item,
    /// configures the popover, registers for notifications, and initiates the first
    /// connection attempt to Discord RPC.
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide the dock icon and main window, making it a menu bar app only.
        NSApp.setActivationPolicy(.prohibited)

        // Initialize DiscordRPC with the client ID
        discordRPC = DiscordRPC(clientID: "1366348807004098612")
        // Register with the manager for UI access
        DiscordRPCManager.shared.setInstance(discordRPC)
        
        // Initialize ScrobbleKit manager
        setupScrobbleKit()

        // Configure the status bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(named: "MenuBarIcon") // Ensure "MenuBarIcon" exists in Assets
            button.image?.isTemplate = true // Allows the icon to adapt to light/dark mode
            button.action = #selector(togglePopover(_:))
            button.target = self
        }

        // Configure the popover
        popover.contentSize = NSSize(width: 250, height: 400) // Increased size to better fit content
        popover.behavior = .transient // Closes automatically when clicking outside
        popover.delegate = self
        // Embed the SwiftUI view within an NSHostingController
        popover.contentViewController = NSHostingController(rootView: MenuContentView())
        // Observe notifications to force a presence update (e.g., when settings change)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(forcePresenceUpdate),
            name: .refreshDiscordPresence,
            object: nil
        )

        // Start the connection process
        tryConnectToDiscord()
    }

    // MARK: - ScrobbleKit Setup & Methods
    
    /// Sets up the ScrobbleKit manager with LastFM API credentials
    private func setupScrobbleKit() async throws {
        // TODO: Replace with your actual LastFM API credentials
        let apiKey = "YOUR_LASTFM_API_KEY"
        let apiSecret = "YOUR_LASTFM_API_SECRET"
        
        // Create and configure ScrobbleKit manager
        scrobbleManager = SBKManager(apiKey: apiKey, secret: apiSecret)
        try await scrobbleManager?.startSession(username: settings.lastfmUsername, password: settings.lastfmPassword)
    }
    
    /// Updates LastFM with the currently playing track
    private func updateNowPlayingStatus(_ song: MusicInfo) {
        guard let scrobbleManager = scrobbleManager,
              scrobbleManager.sessionKey != nil,
              settings.lastfmEnabled else {
            return
        }
        
        // Store the track and start time for potential scrobbling later
        currentScrobbleTrack = song
        currentTrackStartTime = Date()
        
        // Send now playing notification to LastFM
        scrobbleManager.updateNowPlaying(artist: song.artist, track: song.title, album: song.album) { result, error in
            if error == nil {
                self.log("Now playing status updated on LastFM")
            } else {
                self.log("Failed to update now playing status: \(String(describing: error))", level: .error)
            }
        }
    }
    
    /// Scrobbles a track if it has been playing for at least 30 seconds
    private func scrobbleTrackIfNeeded(_ previousTrack: MusicInfo?) {
        guard let scrobbleManager = scrobbleManager,
              scrobbleManager.sessionKey != nil,
              settings.lastfmEnabled,
              let trackToScrobble = previousTrack,
              let startTime = currentTrackStartTime else {
            return
        }
        
        let playDuration = Date().timeIntervalSince(startTime)
        
        // Only scrobble if played for at least 30 seconds
        if playDuration >= 30 {
            let timestamp = Int(startTime.timeIntervalSince1970)
            
            trackToScrobble.
            
            scrobbleManager.scrobble(tracks: [{trackToScrobble.album}]) { result in
                switch result {
                case .success(_):
                    self.log("Track scrobbled successfully to LastFM")
                case .failure(let error):
                    self.log("Failed to scrobble track: \(error)", level: .error)
                }
            }
        } else {
            self.log("Track played less than 30 seconds, not scrobbling")
        }
    }

    // MARK: - Popover Management

    /// Toggles the visibility of the popover window when the status bar item is clicked.
    @objc func togglePopover(_ sender: AnyObject?) {
        if popover.isShown {
            closePopover(sender: sender)
        } else {
            showPopover(sender: sender)
        }
    }

    /// Shows the popover relative to the status bar button and sets up a monitor
    /// to detect clicks outside the popover for automatic dismissal.
    private func showPopover(sender: Any?) {
        guard let button = statusItem.button else { return }
        
        NSApp.activate(ignoringOtherApps: true)
        
        // Ensure layout is ready before showing popover
        DispatchQueue.main.async {
            // Force layout if needed
            if let hostingController = self.popover.contentViewController as? NSHostingController<MenuContentView> {
                hostingController.view.needsLayout = true
                hostingController.view.layoutSubtreeIfNeeded()
            }
            
            self.popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            
            // Make sure the popover gets proper focus and layout
            if let popoverWindow = self.popover.contentViewController?.view.window {
                popoverWindow.makeKey()
            }
        }

        // Start monitoring for mouse clicks outside the popover
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            // Check if the click was inside the popover's view before closing
            if let popoverView = self?.popover.contentViewController?.view,
               let eventWindow = event.window,
               popoverView.window == eventWindow {
                // Click was inside the popover window, do nothing
            } else {
                self?.closePopover(sender: nil)
            }
        }
    }

    /// Closes the popover and removes the global event monitor.
    private func closePopover(sender: Any?) {
        popover.performClose(sender)
        // Stop monitoring for clicks outside
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    /// Called by the system when the popover has closed. Cleans up the event monitor.
    func popoverDidClose(_ notification: Notification) {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    // MARK: - Discord Connection Logic

    /// Attempts to connect to the Discord RPC service using the shared `DiscordRPC` instance.
    /// Handles success, socket not found (retries), sandboxing errors, and other unexpected errors.
    private func tryConnectToDiscord() {
        log("Attempting connection to Discord RPC...")
        do {
            try discordRPC.connect()
            log("Discord RPC connection successful (pending READY event).")

            // Successfully initiated connection, cancel any pending retry timer.
            retryTimer?.invalidate()
            retryTimer = nil
            lastPresence = nil // Reset presence on new connection

            // Start monitoring music playback now that connection is established.
            startMusicLoop()

        } catch DiscordRPCError.noSocketFound {
            log("Discord not running or socket not found. Retrying in 15 seconds.", level: .warning)
            // Stop music loop if it was running
            musicTimer?.invalidate()
            musicTimer = nil
            // Schedule a retry attempt
            scheduleConnectionRetry()

        } catch DiscordRPCError.sandboxed {
            log("Application is sandboxed. Cannot connect to Discord RPC.", level: .error)

        } catch {
            log("Unexpected error connecting to Discord RPC: \(error)", level: .error)
            scheduleConnectionRetry()
        }
    }

    /// Schedules a timer to call `tryConnectToDiscord` again after a delay.
    private func scheduleConnectionRetry() {
        retryTimer?.invalidate() // Ensure only one retry timer is active
        retryTimer = Timer.scheduledTimer(withTimeInterval: 15.0, // Retry delay
                                          repeats: false) { [weak self] _ in
            self?.tryConnectToDiscord()
        }
    }

    // MARK: - Music & Presence Update Loop

    /// Starts a timer that periodically checks for music changes and updates Discord presence.
    /// This loop also monitors the Discord connection status and attempts to reconnect if lost.
    private func startMusicLoop() {
        log("Starting music update loop.")
        musicTimer?.invalidate() // Ensure only one music timer is active
        musicTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }

            // Check if Discord connection is still active before proceeding.
            guard self.discordRPC.isConnected else {
                log("Discord connection lost. Stopping music loop and attempting reconnect.", level: .warning)
                self.musicTimer?.invalidate()
                self.musicTimer = nil
                self.tryConnectToDiscord() // Attempt to re-establish connection
                return
            }

            // Update presence based on current music state.
            self.updateCurrentPresenceIfNeeded()
        }
        // Add timer to the main run loop to ensure it fires correctly.
        RunLoop.main.add(musicTimer!, forMode: .common)
    }

    /// Fetches the current song from `MusicController`, compares it with the last sent presence,
    /// and calls `discordRPC.setActivity` or `clearActivity` if a change is detected
    /// or if playback has stopped. Only sends updates if song details or playback position
    /// (within a tolerance) have changed.
    private func updateCurrentPresenceIfNeeded() {
        guard let currentSong = MusicController.getCurrentSong() else {
            // No song is playing or music app isn't running/accessible
            if lastPresence != nil {
                // If presence was previously set, clear it now
                log("Music stopped or unavailable. Clearing activity.")
                discordRPC.clearActivity()
                
                // Scrobble last track if needed
                scrobbleTrackIfNeeded(currentScrobbleTrack)
                currentScrobbleTrack = nil
                currentTrackStartTime = nil
                
                lastPresence = nil
            }
            return // Nothing to update if no song is playing
        }

        // Song is playing, prepare current presence data
        let now = Date().timeIntervalSince1970
        let calculatedStartTimestamp = Int(now - currentSong.position)

        let currentPresenceData = PresenceData(
            title: currentSong.title,
            artist: currentSong.artist,
            album: currentSong.album,
            startTimestamp: calculatedStartTimestamp
        )

        // Determine if an update is needed
        var shouldUpdate = false
        if let last = lastPresence {
            // Check if song details changed
            if last.title != currentPresenceData.title ||
               last.artist != currentPresenceData.artist ||
               last.album != currentPresenceData.album {
                log("Song changed: \(currentPresenceData.artist) - \(currentPresenceData.title)")
                
                // Scrobble previous track if needed before moving to new track
                scrobbleTrackIfNeeded(currentScrobbleTrack)
                
                // Update now playing for the new track
                updateNowPlayingStatus(currentSong)
                
                shouldUpdate = true
            } else {
                // Check if playback position jumped significantly (e.g., user scrubbed)
                let timeDifference = abs(last.startTimestamp - currentPresenceData.startTimestamp)
                if timeDifference > 3 { // Tolerance in seconds
                    log("Playback position changed significantly (diff: \(timeDifference)s). Updating timestamp.")
                    shouldUpdate = true
                }
            }
        } else {
            // No previous presence, so update if a song is now playing
            log("New song playing: \(currentPresenceData.artist) - \(currentPresenceData.title)")
            
            // Update now playing status on LastFM
            updateNowPlayingStatus(currentSong)
            
            shouldUpdate = true
        }

        // Send the Discord update if needed
        if shouldUpdate {
            log("Updating Discord activity.")
            
            // Create timestamps from song position/duration
            let timestamps = DiscordRPC.ActivityTimestamps.elapsedTime(
                duration: currentSong.duration, 
                position: currentSong.position
            )
            
            // Create asset info
            var assets: DiscordRPC.ActivityAssets?
            if settings.showAlbumArt {
                MusicController.fetchCoverURL(for: currentSong) { [weak self] coverURL in
                    guard let self = self, self.discordRPC.isConnected else { return }
                    
                    let largeImage = coverURL?.absoluteString ?? "applemusic"
                    let largeText = currentSong.album.isEmpty ? "Unknown Album" : currentSong.album
                    let assets = DiscordRPC.ActivityAssets(
                        largeImage: largeImage,
                        largeText: largeText,
                        smallImage: "applemusic",
                        smallText: "Apple Music"
                    )
                    
                    self.setActivityWithSong(
                        currentSong, 
                        timestamps: timestamps, 
                        assets: assets, 
                        showButtons: settings.showButtons
                    )
                }
            } else {
                // No album art requested
                assets = DiscordRPC.ActivityAssets(
                    largeImage: "applemusic",
                    largeText: currentSong.album.isEmpty ? "Unknown Album" : currentSong.album,
                    smallImage: nil,
                    smallText: nil
                )
                
                setActivityWithSong(
                    currentSong, 
                    timestamps: timestamps, 
                    assets: assets, 
                    showButtons: settings.showButtons
                )
            }
            
            lastPresence = currentPresenceData
        }
    }
    
    private func setActivityWithSong(
        _ song: MusicInfo, 
        timestamps: DiscordRPC.ActivityTimestamps, 
        assets: DiscordRPC.ActivityAssets?,
        showButtons: Bool
    ) {
        var buttons: [DiscordRPC.ActivityButton]? = nil
        if showButtons {
            buttons = [DiscordRPC.ActivityButton(
                label: "Listen on Apple Music", 
                url: "https://music.apple.com/"
            )]
        }
        
        discordRPC.setActivity(
            type: .listening,
            state: song.artist.isEmpty ? "Unknown Artist" : song.artist,
            details: song.title.isEmpty ? "Unknown Title" : song.title,
            timestamps: timestamps,
            assets: assets,
            buttons: buttons
        )
    }

    /// Forces an immediate re-evaluation and potential update of the Discord presence.
    /// Called typically when settings affecting presence display (like showAlbumArt) change.
    @objc private func forcePresenceUpdate() {
        log("Force presence update requested.")
        lastPresence = nil // Clear last known state to guarantee an update check.
        
        if discordRPC.isConnected {
             if musicTimer?.isValid != true {
                 startMusicLoop() // Restart loop if it wasn't running
             }
             updateCurrentPresenceIfNeeded()
        } else {
             log("Cannot force update: Discord not connected.", level: .warning)
        }
    }

    // MARK: - Logging

    private enum LogLevel: String { case info = "INFO", warning = "WARN", error = "ERROR" }

    private func log(_ message: String, level: LogLevel = .info) {
        print("[AppDelegate][\(level.rawValue)] \(message)")
    }
}
