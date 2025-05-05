//
//  AppDelegate.swift
//  iRPC
//
//  Created by Sören Stabenow on 27.04.25.
//

import SwiftUI

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

    // MARK: - Timers

    /// Timer used to retry connecting to Discord if the initial connection fails or is lost.
    private var retryTimer: Timer?
    /// Timer responsible for periodically checking the current music state and updating Discord presence.
    private var musicTimer: Timer?

    // MARK: - NSApplicationDelegate Methods

    /// Called when the application finishes launching. Sets up the status bar item,
    /// configures the popover, registers for notifications, and initiates the first
    /// connection attempt to Discord RPC.
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide the dock icon and main window, making it a menu bar app only.
        NSApp.setActivationPolicy(.prohibited)

        // Configure the status bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(named: "MenuBarIcon") // Ensure "MenuBarIcon" exists in Assets
            button.image?.isTemplate = true // Allows the icon to adapt to light/dark mode
            button.action = #selector(togglePopover(_:))
            button.target = self
        }

        // Configure the popover
        popover.contentSize = NSSize(width: 250, height: 150) // Adjust size as needed
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
        DispatchQueue.main.async {
            self.popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
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
            try DiscordRPC.shared.connect()
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
            guard DiscordRPC.shared.isConnected else {
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
    /// and calls `DiscordRPC.shared.updatePresence` or `clearPresence` if a change is detected
    /// or if playback has stopped. Only sends updates if song details or playback position
    /// (within a tolerance) have changed.
    private func updateCurrentPresenceIfNeeded() {
        guard let currentSong = MusicController.getCurrentSong() else {
            // No song is playing or music app isn't running/accessible.
            if lastPresence != nil {
                // If presence was previously set, clear it now.
                log("Music stopped or unavailable. Clearing presence.")
                DiscordRPC.shared.clearPresence()
                lastPresence = nil
            }
            return // Nothing to update if no song is playing.
        }

        // Song is playing, prepare current presence data.
        let settings = SettingsManager.shared
        let now = Date().timeIntervalSince1970
        let calculatedStartTimestamp = Int(now - currentSong.position)

        let currentPresenceData = PresenceData(
            title: currentSong.title,
            artist: currentSong.artist,
            album: currentSong.album,
            startTimestamp: calculatedStartTimestamp
        )

        // Determine if an update is needed.
        var shouldUpdate = false
        if let last = lastPresence {
            // Check if song details changed.
            if last.title != currentPresenceData.title ||
               last.artist != currentPresenceData.artist ||
               last.album != currentPresenceData.album {
                log("Song changed: \(currentPresenceData.artist) - \(currentPresenceData.title)")
                shouldUpdate = true
            } else {
                // Check if playback position jumped significantly (e.g., user scrubbed).
                let timeDifference = abs(last.startTimestamp - currentPresenceData.startTimestamp)
                if timeDifference > 3 { // Tolerance in seconds
                    log("Playback position changed significantly (diff: \(timeDifference)s). Updating timestamp.")
                    shouldUpdate = true
                }
            }
        } else {
            // No previous presence, so update if a song is now playing.
            log("New song playing: \(currentPresenceData.artist) - \(currentPresenceData.title)")
            shouldUpdate = true
        }

        // Send the update if needed.
        if shouldUpdate {
            log("Updating Discord presence.")
            DiscordRPC.shared.updatePresence(
                with: currentSong,
                showAlbumArt: settings.showAlbumArt,
                showButtons: settings.showButtons
            )
            // Store the newly sent presence data for future comparisons.
            lastPresence = currentPresenceData
        }
    }

    /// Forces an immediate re-evaluation and potential update of the Discord presence.
    /// Called typically when settings affecting presence display (like showAlbumArt) change.
    @objc private func forcePresenceUpdate() {
        log("Force presence update requested.")
        lastPresence = nil // Clear last known state to guarantee an update check.
        
        if DiscordRPC.shared.isConnected {
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
