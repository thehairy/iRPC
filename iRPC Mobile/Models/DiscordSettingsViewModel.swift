//
//  DiscordSettingsViewModel.swift
//  iRPC
//
//  Created by Adrian Castro on 19/5/25.
//

import Foundation
import Combine
import DiscordSocialKit
import SwiftUI

// Make the class public and run on the MainActor to match SwiftUI's execution context
@MainActor
public class DiscordSettingsViewModel: ObservableObject {
    // Published properties that the view will observe
    @Published var refreshID = UUID()
    @Published var isUserDataLoaded = false
    
    // Private state
    private var wasAuthenticated = false
    private var refreshSubscription: AnyCancellable?
    private let authCheckInterval: TimeInterval = 2.0
    
    // Add username tracking to detect changes
    private var lastUsername: String? = nil
    
    // References to external objects
    private let discord: DiscordManager
    private var isAuthenticating: Binding<Bool>
    
    public init(discord: DiscordManager, isAuthenticating: Binding<Bool>) {
        self.discord = discord
        self.isAuthenticating = isAuthenticating
        self.wasAuthenticated = discord.isAuthenticated
        self.lastUsername = discord.username
        updateUserDataLoadedState()
    }
    
    // MARK: - Public Methods
    
    func checkInitialState() {
        wasAuthenticated = discord.isAuthenticated
        lastUsername = discord.username
        
        // Update user data loaded state
        updateUserDataLoadedState()
        
        // If already authenticated and user data is available, mark as complete
        if discord.isAuthenticated && discord.username != nil {
            print("📱 ViewModel: Already authenticated with user data available")
            isUserDataLoaded = true
            
            // If we were in authenticating state, complete it
            if isAuthenticating.wrappedValue {
                completeAuthentication()
            }
            return
        }
        
        // If we're authenticating, start observing changes
        if isAuthenticating.wrappedValue {
            startObservingAuthChanges()
        }
        
        // Important: Start observing even if already authenticated but username is nil
        if discord.isAuthenticated && discord.username == nil {
            print("📱 ViewModel: Already authenticated but username not loaded yet, starting observation")
            startObservingAuthChanges()
        }
    }
    
    func handleAuthenticationStateChange(_ newAuthState: Bool) {
        guard newAuthState != wasAuthenticated else { return }
        
        print("📱 ViewModel: Auth state changed from \(wasAuthenticated) to \(newAuthState)")
        wasAuthenticated = newAuthState
        refreshView()
        
        // Always check if user data is loaded when auth state changes
        updateUserDataLoadedState()
        
        // Only complete authentication if we have user data
        if newAuthState && isUserDataLoaded {
            print("📱 ViewModel: Auth completed with user data")
            completeAuthentication()
        } else if newAuthState {
            print("📱 ViewModel: Auth completed but waiting for user data")
            // Keep observing until we get user data
        }
    }
    
    func startObservingAuthChanges() {
        cancelObservation()
        
        print("📱 ViewModel: Started observing auth changes")
        refreshSubscription = Timer.publish(every: authCheckInterval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                Task { @MainActor [self] in
                    guard let self = self else { return }
                    
                    let usernameChanged = self.lastUsername != self.discord.username
                    if usernameChanged {
                        print("📱 ViewModel: Username changed from \(self.lastUsername ?? "nil") to \(self.discord.username ?? "nil")")
                        self.lastUsername = self.discord.username
                    }
                    
                    // Check if user data has been loaded
                    let wasLoaded = self.isUserDataLoaded
                    self.updateUserDataLoadedState()
                    
                    if !wasLoaded && self.isUserDataLoaded {
                        print("📱 ViewModel: User data now loaded")
                        self.completeAuthentication()
                        return
                    }
                    
                    // Continue refreshing if needed
                    if !self.discord.isAuthenticated && self.isAuthenticating.wrappedValue {
                        self.refreshView()
                    } else if self.discord.isAuthenticated && !self.isUserDataLoaded {
                        print("📱 ViewModel: Authenticated but still waiting for user data")
                        self.refreshView()
                    }
                }
            }
    }
    
    func cancelObservation() {
        print("📱 ViewModel: Cancelling observation")
        refreshSubscription?.cancel()
        refreshSubscription = nil
    }
    
    // MARK: - Private Methods
    
    private func updateUserDataLoadedState() {
        // User data is considered loaded if we have a username
        let newState = discord.isAuthenticated && discord.username != nil
        if isUserDataLoaded != newState {
            print("📱 ViewModel: isUserDataLoaded changed from \(isUserDataLoaded) to \(newState)")
            isUserDataLoaded = newState
            
            // If user data is now loaded, update refresh ID to force UI update
            if newState {
                refreshView()
            }
        }
    }
    
    private func completeAuthentication() {
        // Reset authenticating state
        isAuthenticating.wrappedValue = false
        
        // Don't cancel observation until we've confirmed user data is loaded
        if isUserDataLoaded {
            cancelObservation()
        }
        
        // Force view refresh
        refreshView()
    }
    
    private func refreshView() {
        // Force view to refresh by changing the UUID
        refreshID = UUID()
    }
}
