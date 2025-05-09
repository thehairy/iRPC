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
			let modelConfiguration = ModelConfiguration(schema: schema)
			container = try ModelContainer(for: schema, configurations: [modelConfiguration])
		} catch {
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
