import Foundation
import Darwin

@available(macOS 10.12, *)
@available(iOS, unavailable, message: "This framework is only available on macOS")
@available(tvOS, unavailable, message: "This framework is only available on macOS")
@available(watchOS, unavailable, message: "This framework is only available on macOS")
public enum DiscordRPCError: Error {
    case sandboxed
    case noSocketFound
    case posixError(String, Int32)
    case jsonError(Error)
}

@available(macOS 10.12, *)
@available(iOS, unavailable, message: "This framework is only available on macOS")
@available(tvOS, unavailable, message: "This framework is only available on macOS")
@available(watchOS, unavailable, message: "This framework is only available on macOS")
public class DiscordRPC {
    private var socketHandle: FileHandle?
    private let readQueue = DispatchQueue(label: "dev.stabenow.iRPC.DiscordRPCReadQueue")
    private var heartbeatTimer: Timer?
    private let clientID: String
    
    public private(set) var isConnected = false
    public private(set) var isFailedReason: DiscordRPCError?
    
    public init(clientID: String) {
        self.clientID = clientID
    }
    
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
                startReadLoop()
                sendHandshake()
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

    public func disconnect() {
        self.log("Disconnecting from Discord IPC...")
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        socketHandle?.closeFile()
        socketHandle = nil
        isConnected = false
        self.log("Disconnected.")
    }

    @available(macOS 10.12, *)
    @available(iOS, unavailable, message: "This framework is only available on macOS")
    @available(tvOS, unavailable, message: "This framework is only available on macOS")
    @available(watchOS, unavailable, message: "This framework is only available on macOS")
    public struct ActivityAssets {
        public let largeImage: String?
        public let largeText: String?
        public let smallImage: String?
        public let smallText: String?
        
        public init(largeImage: String? = nil, largeText: String? = nil, 
                    smallImage: String? = nil, smallText: String? = nil) {
            self.largeImage = largeImage
            self.largeText = largeText
            self.smallImage = smallImage
            self.smallText = smallText
        }
    }
    
    @available(macOS 10.12, *)
    @available(iOS, unavailable, message: "This framework is only available on macOS")
    @available(tvOS, unavailable, message: "This framework is only available on macOS")
    @available(watchOS, unavailable, message: "This framework is only available on macOS")
    public struct ActivityTimestamps {
        public let start: Int?
        public let end: Int?
        
        public init(start: Int? = nil, end: Int? = nil) {
            self.start = start
            self.end = end
        }
        
        public static func elapsedTime(duration: TimeInterval, position: TimeInterval) -> ActivityTimestamps {
            let now = Date().timeIntervalSince1970
            let start = Int(now - position)
            let end = start + Int(duration)
            return ActivityTimestamps(start: start, end: end)
        }
    }
    
    @available(macOS 10.12, *)
    @available(iOS, unavailable, message: "This framework is only available on macOS")
    @available(tvOS, unavailable, message: "This framework is only available on macOS")
    @available(watchOS, unavailable, message: "This framework is only available on macOS")
    public struct ActivityButton {
        public let label: String
        public let url: String
        
        public init(label: String, url: String) {
            self.label = label
            self.url = url
        }
    }
    
    @available(macOS 10.12, *)
    @available(iOS, unavailable, message: "This framework is only available on macOS")
    @available(tvOS, unavailable, message: "This framework is only available on macOS")
    @available(watchOS, unavailable, message: "This framework is only available on macOS")
    public enum ActivityType: Int {
        case playing = 0
        case streaming = 1
        case listening = 2
        case watching = 3
        case competing = 5
    }

    public func setActivity(type: ActivityType = .playing,
                           state: String? = nil,
                           details: String? = nil,
                           timestamps: ActivityTimestamps? = nil,
                           assets: ActivityAssets? = nil,
                           buttons: [ActivityButton]? = nil) {
        guard isConnected else {
            self.log("Cannot set activity: Not connected.", level: .warning)
            return
        }
        
        var activityPayload: [String: Any] = ["type": type.rawValue]
        
        if let state = state {
            activityPayload["state"] = state
        }
        
        if let details = details {
            activityPayload["details"] = details
        }
        
        if let timestamps = timestamps {
            var timestampsDict: [String: Int] = [:]
            if let start = timestamps.start {
                timestampsDict["start"] = start
            }
            if let end = timestamps.end {
                timestampsDict["end"] = end
            }
            if !timestampsDict.isEmpty {
                activityPayload["timestamps"] = timestampsDict
            }
        }
        
        if let assets = assets {
            var assetsDict: [String: String] = [:]
            if let largeImage = assets.largeImage {
                assetsDict["large_image"] = largeImage
            }
            if let largeText = assets.largeText {
                assetsDict["large_text"] = largeText
            }
            if let smallImage = assets.smallImage {
                assetsDict["small_image"] = smallImage
            }
            if let smallText = assets.smallText {
                assetsDict["small_text"] = smallText
            }
            if !assetsDict.isEmpty {
                activityPayload["assets"] = assetsDict
            }
        }
        
        if let buttons = buttons, !buttons.isEmpty {
            activityPayload["buttons"] = buttons.map { ["label": $0.label, "url": $0.url] }
        }
        
        self.log("Setting activity with payload: \(activityPayload)")
        sendCmd("SET_ACTIVITY", args: ["pid": getpid(), "activity": activityPayload])
    }
    
    public func clearActivity() {
        guard isConnected else {
            self.log("Cannot clear activity: Not connected.", level: .warning)
            return
        }
        self.log("Clearing Discord activity.")
        sendCmd("SET_ACTIVITY", args: ["pid": getpid(), "activity": NSNull()])
    }

    private func resolveRealPath(_ path: String) -> String {
        var buffer = [Int8](repeating: 0, count: Int(PATH_MAX))
        if realpath(path, &buffer) != nil {
            return String(cString: buffer)
        } else {
            return (path as NSString).standardizingPath
        }
    }

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
                    guard let headerData = try handle.read(upToCount: 8), headerData.count == 8 else {
                        self.log("Read loop: Failed to read full header or EOF reached.", level: .warning)
                        break
                    }
                    let op = headerData.withUnsafeBytes { $0.load(as: Int32.self) }.littleEndian
                    let length = Int(headerData.withUnsafeBytes { $0.load(fromByteOffset: 4, as: Int32.self) }.littleEndian)

                    var payloadData = Data()
                    if length > 0 {
                        guard let readData = try handle.read(upToCount: length), readData.count == length else {
                            self.log("Read loop: Failed to read full payload (expected \(length) bytes) or EOF reached.", level: .warning)
                            break
                        }
                        payloadData = readData
                    }

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
            }

            self.log("Read loop finished.")
            DispatchQueue.main.async {
                if self.socketHandle != nil {
                     self.isFailedReason = self.isFailedReason ?? .posixError("Connection lost", 0)
                     self.disconnect()
                }
            }
        }
    }

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

    private func startHeartbeat() {
        DispatchQueue.main.async { [weak self] in
             guard let self = self else { return }
            self.heartbeatTimer?.invalidate()
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

    private func handleMessage(op: Int32, data: Data) {
        var jsonPayload: Any? = nil
        if !data.isEmpty {
            do {
                jsonPayload = try JSONSerialization.jsonObject(with: data, options: [])
            } catch {
                self.log("Failed to decode JSON payload for Op \(op): \(error)", level: .warning)
                return
            }
        }

        switch op {
        case 1:
            guard let message = jsonPayload as? [String: Any],
                  let command = message["cmd"] as? String, command == "DISPATCH",
                  let eventType = message["evt"] as? String else {
                self.log("Received malformed Frame (Op 1) message.", level: .warning)
                return
            }

            self.log("Received Dispatch Event: \(eventType)")
            if eventType == "READY" {
                isConnected = true
                isFailedReason = nil
                self.log("Discord RPC connection READY.")
                startHeartbeat()
            }

        case 3:
            self.log("Received Heartbeat ACK (Op 3 - Pong). Connection alive.")

        case 5:
            self.log("Received Close (Op 5) from Discord: \(jsonPayload ?? "No details").", level: .warning)
             DispatchQueue.main.async {
                 self.isFailedReason = .posixError("Discord closed connection", 0)
                 self.disconnect()
             }

        default:
            self.log("Received unhandled message Opcode: \(op)", level: .warning)
        }
    }

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
            completion?(nil)
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

    private enum logLevel: String { case info = "INFO", warning = "WARN", error = "ERROR" }

    private func log(_ message: String, level: logLevel = .info) {
        print("[DiscordRPC][\(level.rawValue)] \(message)")
    }
}
