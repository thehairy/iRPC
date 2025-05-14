//
//  BackgroundController.swift
//  iRPC
//
//  Created by Adrian Castro on 9/5/25.
//

import AVFoundation
import UIKit
import UserNotifications

final class BackgroundController {
    static let shared = BackgroundController()
    
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private var engine: AVAudioEngine?
    private var isRunning = false
    private var audioSession: AVAudioSession { AVAudioSession.sharedInstance() }
    private var interruptionObserver: NSObjectProtocol?
    
    // Timer for periodic keep-alive tasks
    private var keepAliveTimer: Timer?
    
    // Audio player start time for simulating long-running playback
    private var audioStartTime: TimeInterval = 0
    private var playerNode: AVAudioPlayerNode?
    
    private init() {}

    func start() {
        guard !isRunning else { return }

        // Begin background task
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "RPCBackgroundTask") {
            self.stop()
        }

        startSilentAudioEngine()
        setupInterruptionHandling()
        scheduleKeepAliveTimer()
        requestNotificationPermission()
        
        isRunning = true
        print("📱 Background task started with audio playback")
    }

    func stop() {
        guard isRunning else { return }

        stopSilentAudioEngine()
        removeInterruptionHandling()
        invalidateKeepAliveTimer()

        if backgroundTaskID != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTaskID)
            backgroundTaskID = .invalid
        }

        isRunning = false
        print("📱 Background task stopped")
    }
    
    private func setupInterruptionHandling() {
        // Remove any existing observer
        removeInterruptionHandling()
        
        // Add new observer for audio session interruptions
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleAudioInterruption(notification)
        }
    }
    
    private func removeInterruptionHandling() {
        if let observer = interruptionObserver {
            NotificationCenter.default.removeObserver(observer)
            interruptionObserver = nil
        }
    }
    
    private func handleAudioInterruption(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }
        
        switch type {
        case .began:
            print("🔊 Audio session interrupted")
            // The system interrupted our audio - we'll try to restart when it ends
            
        case .ended:
            // Interruption ended - try to restart our audio
            guard let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt else {
                return
            }
            
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            if options.contains(.shouldResume) {
                print("🔊 Audio interruption ended - restarting audio")
                restartAudioEngine()
            }
            
        @unknown default:
            break
        }
    }
    
    private func restartAudioEngine() {
        // Try to restart our audio engine after an interruption
        stopSilentAudioEngine()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if self.isRunning {
                self.startSilentAudioEngine()
            }
        }
    }
    
    private func scheduleKeepAliveTimer() {
        invalidateKeepAliveTimer()
        
        // Create a timer that fires every 5 minutes to keep the app active
        keepAliveTimer = Timer.scheduledTimer(withTimeInterval: 5 * 60, repeats: true) { [weak self] _ in
            self?.performKeepAliveTasks()
        }
        keepAliveTimer?.tolerance = 30 // Allow 30 seconds tolerance to optimize battery
    }
    
    private func invalidateKeepAliveTimer() {
        keepAliveTimer?.invalidate()
        keepAliveTimer = nil
    }
    
    private func performKeepAliveTasks() {
        // Check if our audio is still running and restart if needed
        if isRunning && (engine?.isRunning == false || playerNode?.isPlaying == false) {
            print("🔄 Keep-alive check - restarting audio engine")
            restartAudioEngine()
        }
        
        // Send a silent local notification to help keep the app alive (if enabled)
        sendSilentKeepAliveNotification()
    }

    private func startSilentAudioEngine() {
        guard engine == nil else { return }

        do {
            // Save the start time to track playback position
            audioStartTime = Date().timeIntervalSince1970
            
            // Configure audio session for background playback
            try audioSession.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

            // Create our audio engine and player node
            let engine = AVAudioEngine()
            let playerNode = AVAudioPlayerNode()
            
            // Set absolute zero volume to guarantee no sound output
            playerNode.volume = 0.0
            
            self.playerNode = playerNode
            
            engine.attach(playerNode)
            
            // Create mixer and connect player to it
            let mixer = engine.mainMixerNode
            // Also ensure mixer volume is zero
            mixer.volume = 0.0
            
            let format = mixer.outputFormat(forBus: 0)
            
            // Connect player to mixer
            engine.connect(playerNode, to: mixer, format: format)
            
            // Generate a silent audio buffer that appears to be long-running
            let silentBuffer = createSilentAudioBuffer(format: format, duration: 60) // 60 seconds buffer
            
            // Schedule buffer to play and loop indefinitely
            playerNode.scheduleBuffer(silentBuffer, at: nil, options: .loops)
            
            try engine.start()
            playerNode.play()
            
            self.engine = engine
            
            print("🔊 Completely silent audio engine started (volume set to 0)")
        } catch {
            print("❌ Failed to start audio engine: \(error)")            
        }
    }
    
    private func createSilentAudioBuffer(format: AVAudioFormat, duration: TimeInterval) -> AVAudioPCMBuffer {
        let sampleRate = format.sampleRate
        let frameCount = AVAudioFrameCount(duration * sampleRate)
        
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            fatalError("Could not create buffer")
        }
        
        buffer.frameLength = frameCount
        
        // Fill buffer with zeros for complete silence
        if let floatChannelData = buffer.floatChannelData {
            for channel in 0..<Int(format.channelCount) {
                let channelData = floatChannelData[channel]
                for frame in 0..<Int(frameCount) {
                    // Use absolute zero for complete silence
                    channelData[frame] = 0.0
                }
            }
        }
        
        return buffer
    }
    
    private func stopSilentAudioEngine() {
        playerNode?.stop()
        playerNode = nil
        engine?.stop()
        engine = nil
        
        try? audioSession.setActive(false)
        print("🔊 Silent audio engine stopped")
    }
        
    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error = error {
                print("❌ Notification authorization failed: \(error)")
            }
        }
    }
    
    private func sendSilentKeepAliveNotification() {
        let content = UNMutableNotificationContent()
        content.title = "iRPC Active"
        content.body = "Keeping Discord rich presence active"
        content.sound = nil
        
        let request = UNNotificationRequest(
            identifier: "iRPC-keepalive-\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil  // Delivering immediately but won't show to user
        )
        
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("❌ Failed to schedule keepalive notification: \(error)")
            }
            
            // Immediately remove the notification since we don't want it to actually show
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [request.identifier])
        }
    }
}
