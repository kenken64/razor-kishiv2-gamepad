import Foundation

enum LocalNetwork {
    /// Returns the most likely LAN IPv4 address, preferring Wi-Fi (`en0`).
    static func primaryIPv4Address() -> String? {
        var interfaces: [(name: String, address: String)] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let interface = cursor {
            defer { cursor = interface.pointee.ifa_next }
            guard let sockaddr = interface.pointee.ifa_addr else { continue }
            guard sockaddr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: interface.pointee.ifa_name)
            guard name != "lo0" else { continue }

            var address = sockaddr.pointee
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                &address,
                socklen_t(address.sa_len),
                &host,
                socklen_t(host.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard result == 0 else { continue }
            let ip = String(cString: host)
            guard !ip.hasPrefix("169.254."), ip != "0.0.0.0" else { continue }
            interfaces.append((name, ip))
        }

        if let preferred = interfaces.first(where: { $0.name == "en0" }) {
            return preferred.address
        }
        if let ethernet = interfaces.first(where: { $0.name.hasPrefix("en") }) {
            return ethernet.address
        }
        return interfaces.first?.address
    }
}
