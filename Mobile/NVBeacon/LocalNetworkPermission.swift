import Darwin

/// Trigger the iOS local-network prompt without discovering peers or sending packets.
/// Apple TN3179: connecting an unsent UDP socket to a local address is sufficient.
enum LocalNetworkPermission {
    static func requestOnEntry() {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else { return }
        defer { freeifaddrs(first) }

        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = current?.pointee {
            current = entry.ifa_next
            guard entry.ifa_flags & UInt32(IFF_UP | IFF_BROADCAST) == UInt32(IFF_UP | IFF_BROADCAST),
                  let address = entry.ifa_addr else { continue }
            if address.pointee.sa_family == AF_INET6 {
                var target = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee }
                let linkLocal = withUnsafeBytes(of: target.sin6_addr) { $0[0] == 0xfe && $0[1] & 0xc0 == 0x80 }
                guard linkLocal else { continue }
                target.sin6_port = UInt16(9).bigEndian
                target.sin6_scope_id = if_nametoindex(entry.ifa_name)
                withUnsafeMutableBytes(of: &target.sin6_addr) { bytes in
                    for i in 8..<16 { bytes[i] = UInt8.random(in: .min ... .max) }
                }
                probe(&target, family: AF_INET6)
            } else if address.pointee.sa_family == AF_INET, let broadcast = entry.ifa_dstaddr {
                var target = broadcast.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                target.sin_port = UInt16(9).bigEndian
                probe(&target, family: AF_INET)
            }
        }
    }

    private static func probe<Address>(_ address: inout Address, family: Int32) {
        let fd = socket(family, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return }
        defer { close(fd) }
        if family == AF_INET {
            var enabled: Int32 = 1
            _ = setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &enabled, socklen_t(MemoryLayout.size(ofValue: enabled)))
        }
        withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                _ = Darwin.connect(fd, $0, socklen_t($0.pointee.sa_len))
            }
        }
    }
}
