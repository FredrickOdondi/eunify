import Foundation
import Network
import os.log

public protocol WebSocketServerDelegate: AnyObject {
    func server(_ server: WebSocketServer, didStartOn port: UInt16)
    func server(_ server: WebSocketServer, clientConnected connection: NWConnection)
    func server(_ server: WebSocketServer, clientDisconnected connection: NWConnection, error: Error?)
    func server(_ server: WebSocketServer, didReceiveMessage message: Data, from connection: NWConnection)
}

public class WebSocketServer {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.eunify.websocket.server")
    private var connectedClients: Set<NWConnection> = []
    public weak var delegate: WebSocketServerDelegate?
    
    private let logger = OSLog(subsystem: "com.eunify.macOS-Host", category: "WebSocketServer")
    
    public init(port: UInt16 = 8080) throws {
        let parameters = NWParameters.tcp
        let webSocketOptions = NWProtocolWebSocket.Options()
        webSocketOptions.autoReplyPing = true
        parameters.defaultProtocolStack.applicationProtocols.insert(webSocketOptions, at: 0)
        
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw ProtocolError.invalidPort
        }
        
        self.listener = try NWListener(using: parameters, on: nwPort)
    }
    
    public func start() {
        listener.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                if let port = self.listener.port?.rawValue {
                    os_log("WebSocket Server ready on port %d", log: self.logger, type: .info, port)
                    self.delegate?.server(self, didStartOn: port)
                }
            case .failed(let error):
                os_log("WebSocket Server failed: %{public}@", log: self.logger, type: .error, error.localizedDescription)
            case .cancelled:
                os_log("WebSocket Server cancelled", log: self.logger, type: .info)
            default:
                break
            }
        }
        
        listener.newConnectionHandler = { [weak self] connection in
            self?.handleNewConnection(connection)
        }
        
        listener.start(queue: queue)
    }
    
    private func handleNewConnection(_ connection: NWConnection) {
        os_log("New connection received", log: logger, type: .info)
        connection.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                os_log("Connection ready", log: self.logger, type: .info)
                self.connectedClients.insert(connection)
                self.delegate?.server(self, clientConnected: connection)
                self.receiveMessage(from: connection)
            case .failed(let error):
                os_log("Connection failed: %{public}@", log: self.logger, type: .error, error.localizedDescription)
                self.connectedClients.remove(connection)
                self.delegate?.server(self, clientDisconnected: connection, error: error)
            case .cancelled:
                os_log("Connection cancelled", log: self.logger, type: .info)
                self.connectedClients.remove(connection)
                self.delegate?.server(self, clientDisconnected: connection, error: nil)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }
    
    private func receiveMessage(from connection: NWConnection) {
        connection.receiveMessage { [weak self] content, context, isComplete, error in
            guard let self = self else { return }
            
            if let error = error {
                os_log("Receive error: %{public}@", log: self.logger, type: .error, error.localizedDescription)
                return
            }
            
            if let content = content {
                self.delegate?.server(self, didReceiveMessage: content, from: connection)
            }
            
            // Continue receiving
            if connection.state == .ready {
                self.receiveMessage(from: connection)
            }
        }
    }
    
    public func send(message: Data, to connection: NWConnection) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
        let context = NWConnection.ContentContext(identifier: "Message", metadata: [metadata])
        
        connection.send(content: message, contentContext: context, isComplete: true, completion: .contentProcessed({ error in
            if let error = error {
                os_log("Send error: %{public}@", log: self.logger, type: .error, error.localizedDescription)
            }
        }))
    }
    
    public func broadcast(message: Data) {
        for client in connectedClients {
            send(message: message, to: client)
        }
    }
    
    public enum ProtocolError: Error {
        case invalidPort
    }
}
