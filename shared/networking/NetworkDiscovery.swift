import Foundation

public struct NetworkDiscovery {
    
    /// Retrieves the local IPv4 address (en0 or en1)
    public static func getLocalIPAddress() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        
        guard getifaddrs(&ifaddr) == 0 else { return nil }
        guard let firstAddr = ifaddr else { return nil }
        
        for ifptr in sequence(firstElement: firstAddr, next: { $0.pointee.ifa_next }) {
            let interface = ifptr.pointee
            let addrFamily = interface.ifa_addr.pointee.sa_family
            
            // Check for IPv4
            if addrFamily == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                // Filter for en0 (Wi-Fi) or en1 (Ethernet)
                if name == "en0" || name == "en1" {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                                &hostname, socklen_t(hostname.count),
                                nil, socklen_t(0), NI_NUMERICHOST)
                    address = String(cString: hostname)
                    break
                }
            }
        }
        
        freeifaddrs(ifaddr)
        return address
    }
    
    /// Generates the properly formatted URI for the QR code
    /// Format: eunify://connect?host=<LAN_IP>&port=<PORT>&auth=<TOKEN>
    public static func generateConnectionURI(port: UInt16, authToken: String) -> URL? {
        guard let ipAddress = getLocalIPAddress() else { return nil }
        
        var components = URLComponents()
        components.scheme = "eunify"
        components.host = "connect"
        
        components.queryItems = [
            URLQueryItem(name: "host", value: ipAddress),
            URLQueryItem(name: "port", value: String(port)),
            URLQueryItem(name: "auth", value: authToken)
        ]
        
        return components.url
    }
}
