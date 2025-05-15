# 🎧 iRPC — Imagine an RPC

**iRPC** is a lightweight application that bridges Apple Music with Discord Rich Presence, allowing you to share your current track, album, and artist live on Discord — beautifully and automatically. With support for macOS and iOS, iRPC brings seamless integration to both desktop and mobile platforms.

---

## ✨ Features

- 🎶 Displays your current Apple Music track on Discord in real-time.
- ⚡ Minimal resource usage with macOS-native and iOS-native design.
- 📱 iOS app built with the Discord Social SDK for advanced Rich Presence management.
- 🧠 Automatically reconnects to Discord after interruptions.
- 🪙 Optional toggles for launching at login, showing album art, and enabling music controls.
- 🍏 Designed with Swift and SwiftUI for a smooth and native experience across platforms.

---

## 🖼 Preview

<img src="https://stabenow.dev/iRPC/iRPC_Preview.png" width="400"/>

---

## 🚀 Getting Started

### Requirements
- **macOS**: macOS 12+ with Apple Music and Discord (Canary, PTB, or Stable) installed.
- **iOS**: iOS 15+ with the Discord app installed and logged in.

### Installation

#### macOS
1. Clone the repository:
   ```bash
   git clone https://github.com/itoolio/iRPC.git
   cd iRPC
   ```
2. Open the project in Xcode:
   ```bash
   open iRPC.xcodeproj
   ```
3. Build and run the app on your macOS system.

#### iOS
1. Clone the repository as above.
2. Open the `iRPC Mobile` project in Xcode:
   ```bash
   open iRPC_MobileApp.xcodeproj
   ```
3. Build and run the app on your iOS device.

---

## 🛠 Technical Details

- Built with Swift and SwiftUI for a modern and efficient user interface.
- Uses `NowPlayingKit` and `DiscordSocialKit` to integrate Apple Music and Discord seamlessly.
- Robust state management powered by `ModelContainer` for CloudKit synchronization.
- Debugging tools for tracking connection status and playback details.

---

## 🧑‍💻 Contributing

We welcome contributions! Follow these steps to get started:
1. Fork the repository.
2. Create your feature branch:
   ```bash
   git checkout -b feature/AmazingFeature
   ```
3. Commit your changes:
   ```bash
   git commit -m 'Add some AmazingFeature'
   ```
4. Push to the branch:
   ```bash
   git push origin feature/AmazingFeature
   ```
5. Open a pull request.

---

## 📄 License

This project is licensed under the Apache License 2.0 — see the [LICENSE](LICENSE) file for details.

---

## ❤️ Acknowledgments

- Built with love by [@thehairy](https://github.com/thehairy) and [@castdrian](https://github.com/castdrian).
- Special thanks to the Discord and Apple Music developer communities.
