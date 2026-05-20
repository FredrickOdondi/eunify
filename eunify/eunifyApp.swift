import SwiftUI
import Network
import UserNotifications
import AVFoundation

public struct MirroredNotification: Identifiable {
    public let id: String
    public let remoteId: String
    public let appName: String
    public let title: String
    public let body: String
    public let timestamp: Date
}

public struct NowPlayingMetadata {
    public let title: String
    public let artist: String
    public let appName: String
    public let albumArtBase64: String?
    public let isPlaying: Bool
    public let duration: Double
    public let position: Double
    public let timestamp: Date
}

public class AppState: ObservableObject {
    public static let shared = AppState()
    
    @Published public var isServerActive: Bool = false
    @Published public var roomId: String = UUID().uuidString
    @Published public var serverState: String = "Idle"
    @Published public var serverError: String? = nil
    @Published public var lastActionType: String? = nil
    @Published public var lastDroppedURL: String? = nil
    @Published public var connectedClientsCount: Int = 0
    @Published public var connectedClientEmail: String? = nil
    @Published public var mirroredNotifications: [MirroredNotification] = []
    @Published public var isCameraActive: Bool = false
    @Published public var isRecording: Bool = false
    @Published public var preferredAudioSource: String = "Mac" 
    @Published public var availableMicrophones: [String] = ["Mac Built-in"]
    @Published public var cameraFrame: NSImage? = nil
    
    // Security & Proximity State
    @Published public var isBiometricEnabled: Bool = false
    @Published public var isPhoneNearby: Bool = false
    @Published public var isVaultLocked: Bool = true
    @Published public var debugLogs: [String] = []
    
    // Media State
    @Published public var nowPlaying: NowPlayingMetadata? = nil
    
    public init() {
        checkVaultStatus()
    }
    
    func checkVaultStatus() {
        if KeychainHelper.shared.getPassword() != nil {
            self.isVaultLocked = false
        }
    }
    
    public func addLog(_ message: String) {
        print(message)
        DispatchQueue.main.async {
            self.debugLogs.insert("\(Date().formatted(.dateTime.hour().minute().second())): \(message)", at: 0)
            if self.debugLogs.count > 100 { self.debugLogs.removeLast() }
        }
    }
    
    public func refreshMicrophones() {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInMicrophone], 
            mediaType: .audio,
            position: .unspecified
        )
        let mics = session.devices.map { "Mac: \($0.localizedName)" }
        DispatchQueue.main.async {
            self.availableMicrophones = mics.isEmpty ? ["Mac: Internal Microphone"] : mics
            if self.preferredAudioSource == "Mac" || !self.availableMicrophones.contains(self.preferredAudioSource) {
                if let firstMic = self.availableMicrophones.first {
                    self.preferredAudioSource = firstMic
                }
            }
        }
    }
    
    public func dismissNotification(id: String) {
        DispatchQueue.main.async {
            self.mirroredNotifications.removeAll { $0.id == id }
        }
    }
}

public class NetworkServer: NSObject, URLSessionWebSocketDelegate {
    public static let shared = NetworkServer()
    
    private var webSocketTask: URLSessionWebSocketTask?
    private let supabaseUrl = "wss://qyceqgttvvairnaxwicm.supabase.co/realtime/v1/websocket?apikey=eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InF5Y2VxZ3R0dnZhaXJuYXh3aWNtIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzI3NDM4MTQsImV4cCI6MjA4ODMxOTgxNH0.cm8dVGQtAZoLwuhbpsD6uZeFXWPp25LOMCZlyR3aRf0"
    private var messageRef = 1
    private var roomTopic: String {
        return "realtime:eunify_room_\(AppState.shared.roomId)"
    }
    
    private var isConnected = false
    
    override init() {
        super.init()
        connect()
    }
    
    func connect() {
        print("EunifyHost: Attempting to connect to Supabase Realtime...")
        guard let url = URL(string: "\(supabaseUrl)&vsn=1.0.0") else { 
            print("EunifyHost: Invalid Supabase URL")
            return 
        }
        
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: OperationQueue())
        webSocketTask = session.webSocketTask(with: url)
        webSocketTask?.resume()
        
        receiveMessage()
        
        DispatchQueue.main.async {
            AppState.shared.serverState = "Connecting to Cloud..."
        }
    }
    
    // MARK: - URLSessionWebSocketDelegate
    
    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        print("EunifyHost: WebSocket connection opened")
        isConnected = true
        joinChannel()
        startHeartbeat()
    }
    
    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        print("EunifyHost: WebSocket connection closed with code \(closeCode.rawValue)")
        isConnected = false
        handleDisconnection()
    }
    
    private func handleDisconnection() {
        DispatchQueue.main.async {
            AppState.shared.isServerActive = false
            AppState.shared.serverState = "Reconnecting..."
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
            self.connect()
        }
    }
    
    private func joinChannel() {
        print("EunifyHost: Joining channel \(roomTopic)...")
        let payload: [String: Any] = [
            "topic": roomTopic,
            "event": "phx_join",
            "payload": ["config": ["broadcast": ["self": true]]],
            "ref": "\(messageRef)"
        ]
        messageRef += 1
        sendMessage(payload)
    }
    
    private func startHeartbeat() {
        DispatchQueue.global().asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self = self, self.isConnected else { return }
            let payload: [String: Any] = [
                "topic": "phoenix",
                "event": "heartbeat",
                "payload": [:],
                "ref": "\(self.messageRef)"
            ]
            self.messageRef += 1
            self.sendMessage(payload)
            self.startHeartbeat()
        }
    }
    
    private func sendMessage(_ dict: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let string = String(data: data, encoding: .utf8) else { return }
        
        print("EunifyHost: Sending message: \(string)")
        webSocketTask?.send(.string(string)) { error in
            if let error = error {
                print("EunifyHost: Send error: \(error)")
            }
        }
    }
    
    private func receiveMessage() {
        webSocketTask?.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let error):
                print("EunifyHost: Receive error: \(error)")
                self.isConnected = false
                self.handleDisconnection()
            case .success(let message):
                switch message {
                case .string(let text):
                    // Noisy logging removed for production, but re-enabled for debugging notification bridge
                    print("EunifyHost: Received raw message → \(text)")
                    self.handleIncomingString(text)
                default: break
                }
                self.receiveMessage()
            }
        }
    }
    
    private func handleIncomingString(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        
        if let event = json["event"] as? String {
            if event == "phx_reply" {
                let payload = json["payload"] as? [String: Any]
                let status = payload?["status"] as? String
                if status == "ok" {
                    print("EunifyHost: Received OK reply from server")
                    DispatchQueue.main.async {
                        AppState.shared.isServerActive = true
                        AppState.shared.serverState = "Cloud Relay Active"
                    }
                }
            } else if event == "broadcast" {
                if let payloadDict = json["payload"] as? [String: Any] {
                    self.handleBroadcastPayload(payloadDict)
                }
            } else if event.hasPrefix("ACTION_") || event.hasPrefix("CLIENT_") || event.hasPrefix("HOST_") {
                // Handle cases where Supabase/Phoenix delivers the signaling event at the top level
                if let payloadDict = json["payload"] as? [String: Any] {
                    var mutatedPayload = payloadDict
                    if mutatedPayload["event"] == nil {
                        mutatedPayload["event"] = event
                    }
                    self.handleBroadcastPayload(mutatedPayload)
                }
            }
        }
    }
    
    private func flattenPayload(_ dict: [String: Any]) -> [String: Any] {
        if let inner = dict["payload"] as? [String: Any] {
            return flattenPayload(inner)
        }
        return dict
    }
    
    private func handleBroadcastPayload(_ payloadDict: [String: Any]) {
        print("EunifyHost: Processing broadcast payload with event: \(payloadDict["event"] ?? "nil")")
        guard let subEvent = payloadDict["event"] as? String else { 
            print("EunifyHost: Skipping broadcast payload - missing 'event' key")
            return 
        }
        
        if subEvent == "CLIENT_CONNECTED" {
            let finalPayload = self.flattenPayload(payloadDict)
            let clientEmail = finalPayload["email"] as? String
            DispatchQueue.main.async {
                AppState.shared.connectedClientsCount = 1
                if let email = clientEmail {
                    AppState.shared.connectedClientEmail = email
                }
                // Snappy: Request current media state immediately upon client connection
                self.sendMediaRefresh()
            }
        } else if subEvent == "CLIENT_LOGGED_OUT" {
            DispatchQueue.main.async {
                AppState.shared.connectedClientsCount = 0
                AppState.shared.connectedClientEmail = nil
                AppState.shared.isCameraActive = false
                AppState.shared.cameraFrame = nil
                AppState.shared.isRecording = false
                AppState.shared.mirroredNotifications = []
            }
        } else if subEvent == "HOST_LAUNCH_URL" {
            let innerPayload = self.flattenPayload(payloadDict)
            if let urlString = innerPayload["url"] as? String,
               let targetUrl = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)) {
                print("EunifyHost: Intercepted reverse payload URL → \(urlString)")
                DispatchQueue.main.async {
                    AppState.shared.lastActionType = "received"
                    AppState.shared.lastDroppedURL = urlString
                    NSWorkspace.shared.open(targetUrl)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        if AppState.shared.lastDroppedURL == urlString {
                            AppState.shared.lastDroppedURL = nil
                        }
                    }
                }
            }
        } else if subEvent == "CLIENT_UNLOCK_REQUEST" {
            DispatchQueue.main.async {
                UnlockService.shared.startUnlockChallenge()
            }
        } else if subEvent == "CLIENT_UNLOCK_SIGNATURE" {
            let finalPayload = self.flattenPayload(payloadDict)
            DispatchQueue.main.async {
                UnlockService.shared.handleUnlockSignature(payload: finalPayload)
            }
        } else if subEvent == "MEDIA_UPDATE" {
            let finalPayload = self.flattenPayload(payloadDict)
            DispatchQueue.main.async {
                let oldTitle = AppState.shared.nowPlaying?.title
                AppState.shared.nowPlaying = NowPlayingMetadata(
                    title: finalPayload["title"] as? String ?? "Unknown Title",
                    artist: finalPayload["body"] as? String ?? "Unknown Artist",
                    appName: finalPayload["app_name"] as? String ?? "Media Player",
                    albumArtBase64: finalPayload["album_art"] as? String,
                    isPlaying: finalPayload["is_playing"] as? Bool ?? false,
                    duration: finalPayload["duration"] as? Double ?? 0,
                    position: finalPayload["position"] as? Double ?? 0,
                    timestamp: Date()
                )
                if oldTitle != AppState.shared.nowPlaying?.title {
                    AppState.shared.addLog("Media: Song changed → \(AppState.shared.nowPlaying?.title ?? "")")
                }
            }
        } else if subEvent == "ACTION_WEBRTC_ANSWER" {
            if let innerPayload = payloadDict["payload"] as? [String: Any] {
                WebRTCManager.shared.handleAnswer(payload: innerPayload)
            }
        } else if subEvent == "ACTION_WEBRTC_ICE_CANDIDATE" {
            if let innerPayload = payloadDict["payload"] as? [String: Any] {
                WebRTCManager.shared.handleCandidate(payload: innerPayload)
            }
        } else if subEvent == "CLIENT_FILE_TRANSFER_START" {
            if let innerPayload = payloadDict["payload"] as? [String: Any] {
                WebRTCManager.shared.handleIncomingFileStart(payload: innerPayload)
            }
        } else if subEvent == "CLIENT_FILE_CHUNK" {
            if let innerPayload = payloadDict["payload"] as? [String: Any] {
                WebRTCManager.shared.handleIncomingFileChunk(payload: innerPayload)
            }
        } else if subEvent == "CLIENT_CAMERA_FRAME" {
            if let innerPayload = payloadDict["payload"] as? [String: Any] {
                WebRTCManager.shared.handleIncomingCameraFrame(payload: innerPayload)
            }
        } else if subEvent == "ACTION_MIRROR_NOTIFICATION" {
            let innerPayload = self.flattenPayload(payloadDict)
            let title = innerPayload["title"] as? String ?? ""
            let body = innerPayload["body"] as? String ?? ""
            let appName = innerPayload["app_name"] as? String ?? "Eunify"
            
            // Flexible ID extraction (handle String or Number)
            var notifId: String = UUID().uuidString
            if let rawId = innerPayload["notification_id"] {
                notifId = "\(rawId)"
            }
            
            let canReply = innerPayload["can_reply"] as? Bool ?? false
            
            print("EunifyHost: [DEBUG] ACTION_MIRROR_NOTIFICATION Received!")
            print("EunifyHost: [DEBUG] App: \(appName), Title: \(title), ID: \(notifId)")
            
            DispatchQueue.main.async {
                // De-duplicate: Only skip if we have the SAME REMOTE ID AND the SAME BODY
                if AppState.shared.mirroredNotifications.contains(where: { $0.remoteId == notifId && $0.body == body }) {
                    print("EunifyHost: [DEBUG] Skipping exact duplicate (RemoteID: \(notifId))")
                    return
                }
                
                print("EunifyHost: [DEBUG] Processing new or updated notification (RemoteID: \(notifId))")
                
                let newNotif = MirroredNotification(
                    id: UUID().uuidString, // Always unique for SwiftUI
                    remoteId: notifId,     // Preserve Android ID
                    appName: appName,
                    title: title,
                    body: body,
                    timestamp: Date()
                )
                AppState.shared.mirroredNotifications.insert(newNotif, at: 0)
                if AppState.shared.mirroredNotifications.count > 50 {
                    AppState.shared.mirroredNotifications.removeLast()
                }
                
                let content = UNMutableNotificationContent()
                content.title = "📱 " + appName
                content.subtitle = title
                content.body = body
                content.sound = .default
                content.userInfo = ["notification_id": notifId] // Use original remote ID for replies
                
                if canReply {
                    content.categoryIdentifier = "MIRRORED_NOTIFICATION"
                }
                
                let req = UNNotificationRequest(identifier: notifId, content: content, trigger: nil)
                UNUserNotificationCenter.current().add(req) { err in
                    if let err = err {
                        print("EunifyHost: ERROR surfacing desktop alert → \(err.localizedDescription)")
                    }
                }
            }
        } else if subEvent == "CLIENT_UNLOCK_SIGNED" {
            let innerPayload = self.flattenPayload(payloadDict)
            UnlockService.shared.handleUnlockSignature(payload: innerPayload)
        }
    }
    
    public func broadcast(url: String) {
        let messageId = UUID().uuidString
        let timestamp = ISO8601DateFormatter().string(from: Date())
        
        let broadcastPayload: [String: Any] = [
            "type": "broadcast",
            "event": "ACTION_LAUNCH_URL",
            "payload": [
                "url": url,
                "message_id": messageId,
                "timestamp": timestamp
            ]
        ]
        
        let payload: [String: Any] = [
            "topic": roomTopic,
            "event": "broadcast",
            "payload": broadcastPayload,
            "ref": "\(messageRef)"
        ]
        messageRef += 1
        sendMessage(payload)
        
        DispatchQueue.main.async {
            AppState.shared.lastActionType = "broadcast"
            AppState.shared.lastDroppedURL = url
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                if AppState.shared.lastDroppedURL == url {
                    AppState.shared.lastDroppedURL = nil
                }
            }
        }
    }
    
    public func broadcastText(_ text: String) {
        let messageId = UUID().uuidString
        let timestamp = ISO8601DateFormatter().string(from: Date())
        
        let broadcastPayload: [String: Any] = [
            "type": "broadcast",
            "event": "ACTION_COPY_TEXT",
            "payload": [
                "text": text,
                "message_id": messageId,
                "timestamp": timestamp
            ]
        ]
        
        let payload: [String: Any] = [
            "topic": roomTopic,
            "event": "broadcast",
            "payload": broadcastPayload,
            "ref": "\(messageRef)"
        ]
        messageRef += 1
        sendMessage(payload)
        
        DispatchQueue.main.async {
            AppState.shared.lastActionType = "copied"
            AppState.shared.lastDroppedURL = text
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                if AppState.shared.lastDroppedURL == text {
                    AppState.shared.lastDroppedURL = nil
                }
            }
        }
    }
    
    public func sendSignalingEvent(eventType: String, payload: [String: Any]) {
        let broadcastPayload: [String: Any] = [
            "type": "broadcast",
            "event": eventType,
            "payload": payload
        ]
        
        let payload: [String: Any] = [
            "topic": roomTopic,
            "event": "broadcast",
            "payload": broadcastPayload,
            "ref": "\(messageRef)"
        ]
        messageRef += 1
        sendMessage(payload)
    }
    
    public func disconnectAllClients() {
        DispatchQueue.main.async {
            AppState.shared.roomId = UUID().uuidString
            AppState.shared.connectedClientsCount = 0
            AppState.shared.connectedClientEmail = nil
            self.joinChannel()
        }
    }

    public func sendMediaControl(_ action: String) {
        let broadcastPayload: [String: Any] = [
            "type": "broadcast",
            "event": "MEDIA_CONTROL",
            "payload": ["action": action]
        ]
        
        let payload: [String: Any] = [
            "topic": roomTopic,
            "event": "broadcast",
            "payload": broadcastPayload,
            "ref": "\(messageRef)"
        ]
        messageRef += 1
        sendMessage(payload)
    }
    
    public func sendMediaRefresh() {
        let broadcastPayload: [String: Any] = [
            "type": "broadcast",
            "event": "MEDIA_REFRESH",
            "payload": [:]
        ]
        
        let payload: [String: Any] = [
            "topic": roomTopic,
            "event": "broadcast",
            "payload": broadcastPayload,
            "ref": "\(messageRef)"
        ]
        messageRef += 1
        sendMessage(payload)
    }
}

class KeychainHelper {
    static let shared = KeychainHelper()
    private let service = "com.eunify.vault"
    private let account = "mac_login_password"
    
    func savePassword(_ password: String) {
        let data = password.data(using: .utf8)!
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data
        ]
        
        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
    }
    
    func getPassword() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var dataTypeRef: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &dataTypeRef)
        
        if status == errSecSuccess, let data = dataTypeRef as? Data {
            return String(data: data, encoding: .utf8)
        }
        return nil
    }
}

class UnlockService {
    static let shared = UnlockService()
    
    private init() {
        // Listen for when the Mac wakes up from sleep to auto-trigger challenge
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { _ in
            self.startUnlockChallenge()
        }
    }
    
    func startUnlockChallenge() {
        guard AppState.shared.isBiometricEnabled && AppState.shared.connectedClientsCount > 0 else {
            AppState.shared.addLog("Unlock ignored. No device linked or Biometric disabled.")
            return 
        }
        
        let challenge = UUID().uuidString
        NetworkServer.shared.sendSignalingEvent(eventType: "CLIENT_UNLOCK_CHALLENGE", payload: ["challenge": challenge])
        AppState.shared.addLog("Sent unlock challenge to phone via Cloud.")
    }
    
    func handleUnlockSignature(payload: [String: Any]) {
        AppState.shared.addLog("Received biometric signature. Unlocking Mac...")
        performNativeUnlock()
    }
    
    private func performNativeUnlock() {
        guard let password = KeychainHelper.shared.getPassword() else {
            AppState.shared.addLog("Unlock failed: No password in Vault.")
            return
        }
        
        AppState.shared.addLog("Biometric Verified. Injecting Vault password...")
        DispatchQueue.global().async {
            self.injectKeystrokes(password)
        }
    }
    
    private func injectKeystrokes(_ text: String) {
        let isTrusted = AXIsProcessTrusted()
        AppState.shared.addLog("Vault: Accessibility Trusted: \(isTrusted)")
        
        AppState.shared.addLog("Vault: Preparing to type \(text.count) characters...")
        let source = CGEventSource(stateID: .hidSystemState)
        
        // Give 1.0s for the user to ensure the correct field is focused
        Thread.sleep(forTimeInterval: 1.0)
        
        for (index, char) in text.enumerated() {
            let vKey: CGKeyCode = (char == " ") ? 0x31 : 0
            
            AppState.shared.addLog("Vault: Pressing key \(index + 1) (vKey: \(vKey))...")
            
            let eventDown = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
            if vKey == 0 {
                eventDown?.keyboardSetUnicodeString(stringLength: 1, unicodeString: [UniChar(char.unicodeScalars.first!.value)])
            }
            eventDown?.post(tap: .cghidEventTap)
            
            let eventUp = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
            if vKey == 0 {
                eventUp?.keyboardSetUnicodeString(stringLength: 1, unicodeString: [UniChar(char.unicodeScalars.first!.value)])
            }
            eventUp?.post(tap: .cghidEventTap)
            
            Thread.sleep(forTimeInterval: 0.05) // Slightly slower for better system reliability
        }
        
        // Final Enter
        AppState.shared.addLog("Vault: Sending Enter key.")
        let enterDown = CGEvent(keyboardEventSource: source, virtualKey: 0x24, keyDown: true)
        enterDown?.post(tap: .cghidEventTap)
        let enterUp = CGEvent(keyboardEventSource: source, virtualKey: 0x24, keyDown: false)
        enterUp?.post(tap: .cghidEventTap)
        
        AppState.shared.addLog("Vault: Injection complete.")
    }
}



class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let window = NSApplication.shared.windows.first {
            window.isOpaque = false
            window.backgroundColor = .clear
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = true
        }
        
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            print("EunifyHost: Desktop notifications authorization granted → \(granted)")
        }
        
        let replyAction = UNTextInputNotificationAction(identifier: "REPLY_ACTION", title: "Reply", options: [], textInputButtonTitle: "Send", textInputPlaceholder: "Type reply...")
        let category = UNNotificationCategory(identifier: "MIRRORED_NOTIFICATION", actions: [replyAction], intentIdentifiers: [], options: [])
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }
    
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.actionIdentifier == "REPLY_ACTION", let textResponse = response as? UNTextInputNotificationResponse {
            let replyText = textResponse.userText
            let userInfo = response.notification.request.content.userInfo
            if let notificationId = userInfo["notification_id"] as? String {
                print("EunifyHost: Intercepted Quick Reply for \(notificationId) → '\(replyText)'")
                NetworkServer.shared.sendSignalingEvent(eventType: "ACTION_NOTIFICATION_REPLY", payload: [
                    "notification_id": notificationId,
                    "reply_text": replyText
                ])
            }
        }
        completionHandler()
    }
    
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

@main
struct eunifyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .onAppear {
                    _ = NetworkServer.shared
                }
        }
        .windowStyle(.hiddenTitleBar)
    }
}
