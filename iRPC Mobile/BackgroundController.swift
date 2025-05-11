//
//  BackgroundController.swift
//  iRPC
//
//  Created by Adrian Castro on 9/5/25.
//

import AVFoundation
import UIKit

final class BackgroundController {
	static let shared = BackgroundController()
	private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
	private var engine: AVAudioEngine?
	private var isRunning = false

	private init() {}

	func start() {
		guard !isRunning else { return }

		backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "RPCTask") {
			self.stop()
		}

		startSilentAudioEngine()
		isRunning = true
		print("📱 Background task started")
	}

	func stop() {
		guard isRunning else { return }

		stopSilentAudioEngine()

		if backgroundTaskID != .invalid {
			UIApplication.shared.endBackgroundTask(backgroundTaskID)
			backgroundTaskID = .invalid
		}

		isRunning = false
		print("📱 Background task stopped")
	}

	private func startSilentAudioEngine() {
		guard engine == nil else { return }

		do {
			// Configure audio session first
			let audioSession = AVAudioSession.sharedInstance()
			try audioSession.setCategory(.ambient, mode: .default)
			try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

			let engine = AVAudioEngine()
			let output = engine.outputNode
			let format = output.inputFormat(forBus: 0)

			// Create minimal-volume silent node
			let silentNode = AVAudioSourceNode { _, _, frameCount, audioBufferList -> OSStatus in
				let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
				for buffer in ablPointer {
					let buf: UnsafeMutableBufferPointer<Float> = UnsafeMutableBufferPointer(buffer)
					for idx in 0..<Int(frameCount) {
						buf[idx] = 0.0001  // Minimal non-zero value
					}
				}
				return noErr
			}

			engine.attach(silentNode)
			engine.connect(silentNode, to: output, format: format)

			try engine.start()
			self.engine = engine
			print("🔊 Silent audio engine started")
		} catch {
			print("❌ Failed to start audio engine: \(error)")
		}
	}

	private func stopSilentAudioEngine() {
		engine?.stop()
		engine = nil
		print("🔊 Silent audio engine stopped")
	}
}
