//
//  SettingsManager.swift
//  iRPC
//
//  Created by Sören Stabenow on 27.04.25.
//

import Foundation
import Combine // Used for @Published properties and managing subscriptions

/// Manages application settings, persisting them to `NSUbiquitousKeyValueStore` (iCloud Key-Value Store)
/// and automatically syncing changes across devices.
/// Conforms to `ObservableObject` to allow SwiftUI views to react to settings changes.
class SettingsManager: ObservableObject {

    /// Shared singleton instance for accessing application settings.
    static let shared = SettingsManager()

    // MARK: - Published Settings Properties

    /// Controls whether the application should launch automatically when the user logs in.
    @Published var launchAtLogin: Bool
    /// Determines if album art should be displayed in the Discord Rich Presence.
    @Published var showAlbumArt: Bool
    /// Determines if action buttons (e.g., "Listen on Music") should be shown in the Discord Rich Presence.
    @Published var showButtons: Bool
    /// Determines if the iOS companion app should be started
    @Published var enableCompanionApp: Bool

    // MARK: - Private Properties

    /// Defines the keys used for storing settings in the key-value store.
    private enum Keys: String {
        case launchAtLogin
        case showAlbumArt
        case showButtons
        case enableCompanionApp
    }

    /// The interface to the iCloud Key-Value Store.
    private let kvStore = NSUbiquitousKeyValueStore.default
    /// Stores Combine subscriptions to manage their lifecycle.
    private var subscriptions = Set<AnyCancellable>()

    // MARK: - Initialization

    /// Private initializer to enforce singleton pattern.
    /// Loads initial values from `NSUbiquitousKeyValueStore`, sets up observation for external changes,
    /// and configures Combine pipelines to save local changes back to the store.
    private init() {
        // Load initial values from iCloud KVS, providing defaults if keys don't exist.
        launchAtLogin = kvStore.bool(forKey: Keys.launchAtLogin.rawValue) // Default false from extension
        showAlbumArt = kvStore.bool(forKey: Keys.showAlbumArt.rawValue, withDefaultValue: true)
        showButtons = kvStore.bool(forKey: Keys.showButtons.rawValue, withDefaultValue: true)
        enableCompanionApp = kvStore.bool(forKey: Keys.enableCompanionApp.rawValue, withDefaultValue: true)

        // Observe notifications for changes made to the KVS from other devices or instances.
        NotificationCenter.default.publisher(for: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: kvStore)
            .sink { [weak self] notification in
                self?.handleICloudChanges(notification)
            }
            .store(in: &subscriptions)

        // Perform an initial synchronization attempt.
        kvStore.synchronize()

        // Set up Combine publishers to automatically save local changes to KVS.
        setupPublishers()

        print("[SettingsManager] Initialized with settings: LaunchAtLogin=\(launchAtLogin), ShowArt=\(showAlbumArt), ShowButtons=\(showButtons), EnableCompanionApp=\(enableCompanionApp)")
    }

    // MARK: - Combine Setup & iCloud Syncing

    /// Sets up Combine pipelines to observe changes in the `@Published` properties (`launchAtLogin`, `showAlbumArt`, `showButtons`).
    /// When a property changes locally, its new value is written to the `NSUbiquitousKeyValueStore` and synchronized.
    private func setupPublishers() {
        // `$property.dropFirst()` prevents saving the initial value loaded during init.
        $launchAtLogin
            .dropFirst()
            .debounce(for: .milliseconds(200), scheduler: RunLoop.main) // Debounce to avoid rapid writes
            .sink { [weak self] newValue in
                print("[SettingsManager] Saving launchAtLogin=\(newValue) to iCloud KVS.")
                self?.kvStore.set(newValue, forKey: Keys.launchAtLogin.rawValue)
                self?.kvStore.synchronize()
            }
            .store(in: &subscriptions)

        $showAlbumArt
            .dropFirst()
            .debounce(for: .milliseconds(200), scheduler: RunLoop.main)
            .sink { [weak self] newValue in
                print("[SettingsManager] Saving showAlbumArt=\(newValue) to iCloud KVS.")
                self?.kvStore.set(newValue, forKey: Keys.showAlbumArt.rawValue)
                self?.kvStore.synchronize()
            }
            .store(in: &subscriptions)

        $showButtons
            .dropFirst()
            .debounce(for: .milliseconds(200), scheduler: RunLoop.main)
            .sink { [weak self] newValue in
                print("[SettingsManager] Saving showButtons=\(newValue) to iCloud KVS.")
                self?.kvStore.set(newValue, forKey: Keys.showButtons.rawValue)
                self?.kvStore.synchronize()
            }
            .store(in: &subscriptions)
        
        $enableCompanionApp
            .dropFirst()
            .debounce(for: .milliseconds(200), scheduler: RunLoop.main)
            .sink { [weak self] newValue in
                print("[SettingsManager] Saving enableCompanionApp=\(newValue) to iCloud KVS.")
                self?.kvStore.set(newValue, forKey: Keys.enableCompanionApp.rawValue)
                self?.kvStore.synchronize()
            }
            .store(in: &subscriptions)
    }

    /// Handles notifications indicating that the `NSUbiquitousKeyValueStore` was changed externally (e.g., by another device).
    /// Updates the corresponding local `@Published` properties to reflect the new values from iCloud.
    /// Ensures updates are performed on the main thread as they affect `@Published` properties bound to the UI.
    /// - Parameter notification: The `NSUbiquitousKeyValueStore.didChangeExternallyNotification` received.
    private func handleICloudChanges(_ notification: Notification) {
        // Extract change reason and changed keys from the notification.
        guard let userInfo = notification.userInfo,
              let reasonForChange = userInfo[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int else {
            print("[SettingsManager][WARN] Received iCloud change notification with missing userInfo or reason.")
            return
        }

        // Check if the change reason indicates a server change or initial sync. Ignore quota violations or account changes for simple updates.
        let validReasons = [
            NSUbiquitousKeyValueStoreServerChange, // Changes pushed from iCloud server
            NSUbiquitousKeyValueStoreInitialSyncChange // First sync after launch
        ]
        guard validReasons.contains(reasonForChange) else {
            print("[SettingsManager] Ignoring iCloud change notification with reason: \(reasonForChange)")
            return
        }

        // Get the list of keys whose values have changed.
        guard let changedKeys = userInfo[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String] else {
            print("[SettingsManager][WARN] Received iCloud change notification with missing changed keys.")
            return
        }
        print("[SettingsManager] Received external iCloud changes for keys: \(changedKeys)")

        // Update local @Published properties on the main thread.
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            for key in changedKeys {
                // Update the corresponding property based on the changed key.
                switch key {
                case Keys.launchAtLogin.rawValue:
                    let newValue = self.kvStore.bool(forKey: key)
                    if self.launchAtLogin != newValue {
                        self.launchAtLogin = newValue
                        print("[SettingsManager] Updated launchAtLogin from iCloud: \(newValue)")
                    }
                case Keys.showAlbumArt.rawValue:
                    let newValue = self.kvStore.bool(forKey: key, withDefaultValue: true)
                    if self.showAlbumArt != newValue {
                        self.showAlbumArt = newValue
                        print("[SettingsManager] Updated showAlbumArt from iCloud: \(newValue)")
                    }
                case Keys.showButtons.rawValue:
                    let newValue = self.kvStore.bool(forKey: key, withDefaultValue: true)
                    if self.showButtons != newValue {
                        self.showButtons = newValue
                        print("[SettingsManager] Updated showButtons from iCloud: \(newValue)")
                    }
                case Keys.enableCompanionApp.rawValue:
                    let newValue = self.kvStore.bool(forKey: key, withDefaultValue: true)
                    if self.enableCompanionApp != newValue {
                        self.enableCompanionApp = newValue
                        print("[SettingsManager] Updated enableCoimpanionApp from iCloud: \(newValue)")
                    }
                default:
                    // Ignore keys not managed by this class.
                    break
                }
            }
        }
    }
}

// MARK: - NSUbiquitousKeyValueStore Extension

extension NSUbiquitousKeyValueStore {
    /// Convenience method to retrieve a boolean value from the key-value store,
    /// providing a specified default value if the key does not exist.
    /// - Parameters:
    ///   - key: The key for the desired boolean value.
    ///   - defaultValue: The value to return if the key is not found. Defaults to `false`.
    /// - Returns: The boolean value associated with the key, or the `defaultValue` if the key is not present.
    func bool(forKey key: String, withDefaultValue defaultValue: Bool = false) -> Bool {
        // Check if the key exists before attempting to retrieve the bool.
        // `object(forKey:)` returns nil if the key doesn't exist.
        if object(forKey: key) != nil {
            return bool(forKey: key)
        } else {
            return defaultValue
        }
    }
}
