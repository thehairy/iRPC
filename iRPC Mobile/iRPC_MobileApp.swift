//
//  iRPC_MobileApp.swift
//  iRPC Mobile
//
//  Created by Adrian Castro on 8/5/25.
//

import DiscordSocialKit
import SwiftData
import SwiftUI

@main
struct iRPC_MobileApp: App {
	let container: ModelContainer

	init() {
		do {
			let schema = Schema([DiscordToken.self])
			let config = ModelConfiguration(
				schema: schema,
				isStoredInMemoryOnly: false,
				allowsSave: true
			)

			container = try ModelContainer(
				for: schema,
				configurations: config
			)
			print("✅ ModelContainer initialized for CloudKit sync")
		} catch {
			print("❌ Failed to initialize ModelContainer: \(error)")
			fatalError("Failed to initialize ModelContainer: \(error)")
		}
	}

	var body: some Scene {
		WindowGroup {
			ContentView()
		}
		.modelContainer(container)
	}
}
