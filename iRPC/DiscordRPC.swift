//
//  DiscordRPC.swift
//  iRPC
//
//  Created by Sören Stabenow on 27.04.25.
//

import Foundation
import Darwin // Required for socket operations and realpath

/// Defines errors that can occur during Discord RPC operations.
public enum DiscordRPCError: Error {
    /// Thrown when the application is sandboxed and cannot access the required IPC sockets.
    case sandboxed
    /// Thrown when no Discord IPC socket could be found in the standard temporary directories.
    case noSocketFound
    /// Thrown when a POSIX C function call fails. Contains the error message and the `errno` code.
    case posixError(String, Int32)
    /// Thrown when encoding or decoding JSON payloads fails. Contains the underlying error.
    case jsonError(Error)
}

/// Manages the connection and communication with the Discord client via its local IPC socket
/// for Rich Presence updates.
public class DiscordRPC {
    /// Shared singleton instance for accessing DiscordRPC functionality.
    public static let shared = DiscordRPC()
    private init() {} // Private initializer to enforce singleton pattern.

    // MARK: - Private Properties

    private var socketHandle: FileHandle?
    private let readQueue = DispatchQueue(label: "dev.stabenow.iRPC.DiscordRPCReadQueue")
    private var heartbeatTimer: Timer?
    private let clientID = "1366348807004098612"

    // MARK: - Public Properties

    /// Indicates whether the RPC connection is currently active. Set to `true` after a successful handshake/READY event.
    public private(set) var isConnected = false
    /// If the connection failed or disconnected unexpectedly, this holds the reason (`DiscordRPCError`).
    public private(set) var isFailedReason: DiscordRPCError?

    // MARK: - Connection Management

    /// Attempts to find and connect to the Discord IPC socket.
    ///
    /// Searches standard temporary directories for `discord-ipc-*`, establishes a connection,
    /// sends the handshake, and starts the read loop and heartbeats.
    /// Sets `isConnected` to true upon receiving the READY event from Discord.
    ///
    /// - Throws: `DiscordRPCError` if connection fails (e.g., sandboxed, socket not found, POSIX error).
    public func connect() throws {
        self.log("Attempting to connect to Discord IPC...")

        if ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil {
            self.log("Connection failed: Application is sandboxed.", level: .error)
            self.isFailedReason = .sandboxed
            throw self.isFailedReason!
        }

        let rawTmp = ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory()
        let realTmp = resolveRealPath(rawTmp)
        self.log("Scanning temporary directory: \(realTmp)")

        let tmpURL = URL(fileURLWithPath: realTmp, isDirectory: true)
        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(
                at: tmpURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        } catch {
            self.log("Failed to list temporary directory contents: \(error)", level: .error)
            self.isFailedReason = .noSocketFound
            throw self.isFailedReason!
        }

        let candidates = entries.filter { $0.lastPathComponent.hasPrefix("discord-ipc-") }
        self.log("Found \(candidates.count) potential socket candidate(s): \(candidates.map { $0.lastPathComponent })")

        for url in candidates {
            let path = resolveRealPath(url.path)
            self.log("Attempting connection to socket: \(path)")
            do {
                let fileDescriptor = try connectUnixSocket(at: path)
                socketHandle = FileHandle(fileDescriptor: fileDescriptor, closeOnDealloc: true)
                self.log("Successfully connected to IPC socket at \(path). Waiting for READY event.")
                // Start background tasks required for maintaining the connection
                startReadLoop()
                sendHandshake() // Initiate the handshake process
                isFailedReason = nil
                return
            } catch DiscordRPCError.posixError(let msg, let code) {
                self.log("POSIX error connecting to \(path): \(msg) (errno: \(code)). Trying next candidate.", level: .warning)
            } catch {
                 self.log("Unexpected error connecting to \(path): \(error). Trying next candidate.", level: .warning)
            }
        }

        self.log("Connection failed: No suitable Discord IPC socket found after scanning all candidates.", level: .error)
        self.isFailedReason = .noSocketFound
        throw self.isFailedReason!
    }

    /// Disconnects from the Discord IPC socket, stops heartbeats, and closes the file handle.
    /// Sets `isConnected` to `false`.
    public func disconnect() {
        self.log("Disconnecting from Discord IPC...")
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        socketHandle?.closeFile()
        socketHandle = nil
        isConnected = false
        self.log("Disconnected.")
    }

    // MARK: - Presence Updates

    /// Updates the user's Discord Rich Presence status based on the provided music info.
    ///
    /// This method constructs the appropriate payload, including timestamps, assets, and optional buttons,
    /// and sends it to Discord via the `SET_ACTIVITY` command. It handles fetching album art asynchronously if requested.
    /// Does nothing if `isConnected` is false.
    ///
    /// - Parameters:
    ///   - song: A `MusicInfo` struct containing details about the currently playing track.
    ///   - showAlbumArt: If true, attempts to fetch and display album art using `MusicController`. Defaults to true.
    ///   - showButtons: If true, includes default action buttons (e.g., "Listen on Apple Music"). Defaults to true.
    public func updatePresence(with song: MusicInfo, showAlbumArt: Bool = true, showButtons: Bool = true) {
        guard isConnected else {
            self.log("Cannot update presence: Not connected.", level: .warning)
            return
        }

        let now = Date().timeIntervalSince1970
        let startTimestamp = Int(now - song.position)
        let endTimestamp = startTimestamp + Int(song.duration)

        if showAlbumArt {
            MusicController.fetchCoverURL(for: song) { [weak self] coverURL in
                guard self?.isConnected == true else { return } // Check connection again in async callback
                self?.completePresenceUpdate(song: song,
                                             startTimestamp: startTimestamp,
                                             endTimestamp: endTimestamp,
                                             coverURL: coverURL,
                                             showButtons: showButtons)
            }
        } else {
            completePresenceUpdate(song: song,
                                   startTimestamp: startTimestamp,
                                   endTimestamp: endTimestamp,
                                   coverURL: nil,
                                   showButtons: showButtons)
        }
    }

    /// Clears the user's Discord Rich Presence status by sending an empty activity payload.
    /// Does nothing if `isConnected` is false.
    public func clearPresence() {
        guard isConnected else {
            self.log("Cannot clear presence: Not connected.", level: .warning)
            return
        }
        self.log("Clearing Discord presence.")
        sendCmd("SET_ACTIVITY", args: ["pid": getpid(), "activity": NSNull()])
    }

    // MARK: - Private Helper Methods - Socket & Path

    /// Resolves the real path of a given file path, handling symbolic links.
    private func resolveRealPath(_ path: String) -> String {
        var buffer = [Int8](repeating: 0, count: Int(PATH_MAX))
        if realpath(path, &buffer) != nil {
            return String(cString: buffer)
        } else {
            return (path as NSString).standardizingPath // Fallback
        }
    }

    /// Creates and connects a Unix domain socket at the specified path.
    /// - Throws: `DiscordRPCError.posixError` on failure.
    private func connectUnixSocket(at path: String) throws -> Int32 {
        var addr = sockaddr_un()
        addr.sun_len    = UInt8(MemoryLayout<sockaddr_un>.size)
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = path.withCString { strncpy(&addr.sun_path.0, $0, MemoryLayout.size(ofValue: addr.sun_path) - 1) }

        let fd = Darwin.socket(AF_UNIX, Int32(SOCK_STREAM), 0)
        guard fd >= 0 else { throw DiscordRPCError.posixError("socket() failed", errno) }

        var connectAddr = addr
        let sockLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &connectAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, sockLen) }
        }

        if result != 0 {
            let errorNumber = errno
            Darwin.close(fd)
            throw DiscordRPCError.posixError("connect() failed", errorNumber)
        }
        return fd
    }

    // MARK: - Private Helper Methods - Communication Loop & Protocol

    /// Starts the asynchronous loop on `readQueue` to continuously read and handle messages from the socket.
    /// Handles message framing (Opcode + Length prefix) and dispatches payloads to `handleMessage`.
    /// Triggers disconnection if the loop terminates due to errors or socket closure.
    private func startReadLoop() {
        guard let handle = socketHandle else {
            self.log("Cannot start read loop: Socket handle is nil.", level: .error)
            return
        }

        readQueue.async { [weak self] in
            guard let self = self else { return }
            self.log("Read loop started.")

            while self.socketHandle != nil {
                do {
                    // Read header
                    guard let headerData = try handle.read(upToCount: 8), headerData.count == 8 else {
                        self.log("Read loop: Failed to read full header or EOF reached.", level: .warning)
                        break
                    }
                    let op = headerData.withUnsafeBytes { $0.load(as: Int32.self) }.littleEndian
                    let length = Int(headerData.withUnsafeBytes { $0.load(fromByteOffset: 4, as: Int32.self) }.littleEndian)

                    // Read payload
                    var payloadData = Data()
                    if length > 0 {
                        guard let readData = try handle.read(upToCount: length), readData.count == length else {
                            self.log("Read loop: Failed to read full payload (expected \(length) bytes) or EOF reached.", level: .warning)
                            break
                        }
                        payloadData = readData
                    }

                    // Process message
                    self.handleMessage(op: op, data: payloadData)

                } catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(EBADF) {
                    self.log("Read loop: Socket closed (EBADF).", level: .info)
                     break
                } catch {
                    self.log("Read loop error: \(error)", level: .error)
                    DispatchQueue.main.async {
                         self.isFailedReason = self.isFailedReason ?? .posixError("Read loop failed", errno)
                    }
                    break
                }
            } // End while loop

            self.log("Read loop finished.")
            DispatchQueue.main.async {
                if self.socketHandle != nil {
                     self.isFailedReason = self.isFailedReason ?? .posixError("Connection lost", 0)
                     self.disconnect()
                }
            }
        }
    }

    /// Sends the initial handshake message (Opcode 0) to Discord.
    private func sendHandshake() {
        let handshakePayload: [String: Any] = ["v": 1, "client_id": clientID]
        self.log("Sending handshake: \(handshakePayload)")
        sendFrame(op: 0, data: handshakePayload) { error in
            if let error = error {
                self.log("Failed to send handshake: \(error)", level: .error)
                DispatchQueue.main.async {
                    self.isFailedReason = .posixError("Handshake send failed", errno)
                    self.disconnect()
                }
            } else {
                self.log("Handshake message sent.")
            }
        }
    }

    /// Starts a timer on the main run loop to send heartbeat messages (Opcode 3) periodically.
    private func startHeartbeat() {
        DispatchQueue.main.async { [weak self] in
             guard let self = self else { return }
            self.heartbeatTimer?.invalidate() // Stop existing timer if any
            self.heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: true) { _ in
                self.log("Sending heartbeat (Op 3)...")
                self.sendFrame(op: 3, data: [:]) { error in
                    if let error = error {
                        self.log("Failed to send heartbeat: \(error)", level: .error)
                        DispatchQueue.main.async {
                            self.isFailedReason = .posixError("Heartbeat failed", errno)
                            self.disconnect()
                        }
                    }
                }
            }
            RunLoop.main.add(self.heartbeatTimer!, forMode: .common)
            self.log("Heartbeat timer started.")
        }
    }

    /// Processes incoming messages from the read loop based on their Opcode.
    /// Handles key events like READY (sets `isConnected=true`, starts heartbeats), Heartbeat ACKs, and Close requests.
    private func handleMessage(op: Int32, data: Data) {
        var jsonPayload: Any? = nil
        if !data.isEmpty {
            do {
                jsonPayload = try JSONSerialization.jsonObject(with: data, options: [])
            } catch {
                self.log("Failed to decode JSON payload for Op \(op): \(error)", level: .warning)
                return // Ignore messages with invalid JSON
            }
        }

        switch op {
        case 1: // Frame (Dispatch)
            guard let message = jsonPayload as? [String: Any],
                  let command = message["cmd"] as? String, command == "DISPATCH",
                  let eventType = message["evt"] as? String else {
                self.log("Received malformed Frame (Op 1) message.", level: .warning)
                return
            }

            self.log("Received Dispatch Event: \(eventType)")
            if eventType == "READY" {
                // Connection is fully established.
                isConnected = true
                isFailedReason = nil // Clear failure state
                self.log("Discord RPC connection READY.")
                // Start heartbeats *after* READY is confirmed.
                startHeartbeat()
            }

        case 3: // Heartbeat ACK (Pong)
            self.log("Received Heartbeat ACK (Op 3 - Pong). Connection alive.")

        case 5: // Close
            self.log("Received Close (Op 5) from Discord: \(jsonPayload ?? "No details").", level: .warning)
             DispatchQueue.main.async {
                 self.isFailedReason = .posixError("Discord closed connection", 0)
                 self.disconnect()
             }

        default:
            self.log("Received unhandled message Opcode: \(op)", level: .warning)
        }
    }

    /// Constructs the activity payload dictionary for presence updates.
    private func completePresenceUpdate(song: MusicInfo, startTimestamp: Int, endTimestamp: Int, coverURL: URL?, showButtons: Bool) {
        let largeImageKey = coverURL?.absoluteString ?? "applemusic" // Replace with your default asset key
        let largeImageText = song.album.isEmpty ? "Unknown Album" : song.album
        let smallImageKey = "applemusic"
        let smallImageText = "Apple Music"

        var activityPayload: [String: Any] = [
            "type": 2, // Listening - https://discord-api-types.dev/api/discord-api-types-v10/enum/ActivityType#Listening
            "state": song.artist.isEmpty ? "Unknown Artist" : song.artist,
            "details": song.title.isEmpty ? "Unknown Title" : song.title,
            "timestamps": ["start": startTimestamp, "end": endTimestamp],
            "assets": [
                "large_image": largeImageKey, "large_text": largeImageText,
                "small_image": smallImageKey, "small_text": smallImageText
            ]
        ]

        if showButtons {
            activityPayload["buttons"] = [
                ["label": "Listen on Apple Music", "url": "https://music.apple.com/"] // TODO: Grab song URL and display in button
            ]
        }

        self.log("Sending presence update: \(song.title) by \(song.artist)")
        sendCmd("SET_ACTIVITY", args: ["pid": getpid(), "activity": activityPayload])
    }

    /// Sends a command frame (Opcode 1) with the specified command name and arguments.
    private func sendCmd(_ cmd: String, args: [String: Any]) {
        let payload: [String: Any] = [
            "cmd": cmd,
            "args": args,
            "nonce": UUID().uuidString
        ]
        self.log("Sending command: \(cmd)")
        sendFrame(op: 1, data: payload) { error in
             if let error = error {
                 self.log("Failed to send command '\(cmd)': \(error)", level: .error)
             }
        }
    }

    /// Encodes the given payload dictionary into a JSON string, prefixes it with the
    /// Opcode and length (Little Endian), and writes the resulting packet to the socket handle.
    /// Handles potential JSON encoding errors and socket write errors (like EPIPE).
    private func sendFrame(op: Int32, data: [String: Any], completion: ((Error?) -> Void)? = nil) {
        guard let handle = socketHandle else {
            self.log("Cannot send frame (Op \(op)): Socket handle is nil.", level: .error)
            completion?(DiscordRPCError.noSocketFound)
            return
        }

        do {
            let jsonData = try JSONSerialization.data(withJSONObject: data, options: [])
            let jsonLength = Int32(jsonData.count)

            var header = Data(capacity: 8)
            var opLE = op.littleEndian
            var lenLE = jsonLength.littleEndian
            header.append(Data(bytes: &opLE, count: 4))
            header.append(Data(bytes: &lenLE, count: 4))
            let packet = header + jsonData

            try handle.write(contentsOf: packet)
            completion?(nil) // Success
        } catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(EPIPE) {
            self.log("Failed to send frame (Op \(op)): Broken pipe (EPIPE). Disconnecting.", level: .error)
             DispatchQueue.main.async {
                 self.isFailedReason = .posixError("Broken pipe", Int32(EPIPE))
                 self.disconnect()
             }
             completion?(error)
        } catch {
            self.log("Failed to send frame (Op \(op)): \(error)", level: .error)
             if let ioError = error as? POSIXError {
                 DispatchQueue.main.async {
                     self.isFailedReason = .posixError("Send frame failed", ioError.code.rawValue)
                 }
             }
             completion?(error)
        }
    }


    // MARK: - self.logging

    private enum logLevel: String { case info = "INFO", warning = "WARN", error = "ERROR" }

    /// Simple internal self.logger.
    private func log(_ message: String, level: logLevel = .info) {
        print("[DiscordRPC][\(level.rawValue)] \(message)")
    }
}
