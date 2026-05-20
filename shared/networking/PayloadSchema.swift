import Foundation

public struct PayloadSchema {
    
    public enum MessageType: String, Codable {
        case authRequest = "AUTH_REQUEST"
        case authResponse = "AUTH_RESPONSE"
        case actionLaunchUrl = "ACTION_LAUNCH_URL"
        case ack = "ACK"
        case ping = "PING"
        case pong = "PONG"
    }
    
    public struct BaseMessage<T: Codable>: Codable {
        public let type: MessageType
        public let messageId: String?
        public let timestamp: String
        public let payload: T?
        
        public init(type: MessageType, messageId: String? = UUID().uuidString, payload: T?) {
            self.type = type
            self.messageId = messageId
            
            let formatter = ISO8601DateFormatter()
            self.timestamp = formatter.string(from: Date())
            self.payload = payload
        }
        
        enum CodingKeys: String, CodingKey {
            case type
            case messageId = "message_id"
            case timestamp
            case payload
        }
    }
    
    // MARK: - Payloads
    
    public struct AuthRequestPayload: Codable {
        public let token: String
    }
    
    public struct AuthResponsePayload: Codable {
        public let status: String
    }
    
    public struct LaunchUrlPayload: Codable {
        public let url: String
    }
    
    public struct AckPayload: Codable {
        public let status: String
        public let details: String?
    }
}
