import Darwin
import Foundation

/// Ein per WS-Discovery gefundenes Gerät.
struct DiscoveredEndpoint: Hashable {
    var address: String   // z. B. urn:uuid:…
    var types: String
    var xaddrs: [URL]
    var sourceIP: String
}

/// WS-Discovery (UDP 3702): Multicast-Probe auf allen IPv4-Schnittstellen, optional zusätzlich Unicast an eine IP.
enum WSDiscovery {
    static let port: UInt16 = 3702
    static let multicastGroup = "239.255.255.250"

    static func discover(timeout: TimeInterval = 3, unicastHost: String? = nil) async -> [DiscoveredEndpoint] {
        // Harte Zeitgrenze: Firewalls (z. B. Little Snitch) oder die macOS-Abfrage „Lokales Netzwerk“
        // können sendto() blockieren, bis der Nutzer zustimmt.
        await withCheckedContinuation { continuation in
            let once = ResumeOnce(continuation)
            DispatchQueue.global(qos: .userInitiated).async {
                once.resume(runProbe(timeout: timeout, unicastHost: unicastHost))
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout + 2) {
                once.resume([])
            }
        }
    }

    private final class ResumeOnce: @unchecked Sendable {
        private var continuation: CheckedContinuation<[DiscoveredEndpoint], Never>?
        private let lock = NSLock()
        init(_ c: CheckedContinuation<[DiscoveredEndpoint], Never>) { continuation = c }
        func resume(_ value: [DiscoveredEndpoint]) {
            lock.lock()
            let c = continuation
            continuation = nil
            lock.unlock()
            c?.resume(returning: value)
        }
    }

    private static func probeMessage(types: String?) -> Data {
        let typesXML = types.map { "<wsd:Types>\($0)</wsd:Types>" } ?? ""
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <soap:Envelope xmlns:soap="http://www.w3.org/2003/05/soap-envelope" \
        xmlns:wsa="http://schemas.xmlsoap.org/ws/2004/08/addressing" \
        xmlns:wsd="http://schemas.xmlsoap.org/ws/2005/04/discovery" \
        xmlns:wscn="http://schemas.microsoft.com/windows/2006/08/wdp/scan" \
        xmlns:devprof="http://schemas.xmlsoap.org/ws/2006/02/devprof">\
        <soap:Header>\
        <wsa:To>urn:schemas-xmlsoap-org:ws:2005:04:discovery</wsa:To>\
        <wsa:Action>http://schemas.xmlsoap.org/ws/2005/04/discovery/Probe</wsa:Action>\
        <wsa:MessageID>urn:uuid:\(UUID().uuidString.lowercased())</wsa:MessageID>\
        </soap:Header>\
        <soap:Body><wsd:Probe>\(typesXML)</wsd:Probe></soap:Body>\
        </soap:Envelope>
        """
        return Data(xml.utf8)
    }

    private static func runProbe(timeout: TimeInterval, unicastHost: String?) -> [DiscoveredEndpoint] {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return [] }
        defer { close(fd) }

        var local = sockaddr_in()
        local.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        local.sin_family = sa_family_t(AF_INET)
        local.sin_addr.s_addr = INADDR_ANY
        local.sin_port = 0
        _ = withUnsafePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        var ttl: UInt8 = 4
        setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout<UInt8>.size))
        var tv = timeval(tv_sec: 0, tv_usec: 250_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        // Ungefilterte Probe + typisierte Probes, da nicht jedes Gerät auf alle antwortet.
        let messages = [nil, "wscn:ScanDeviceType", "devprof:Device"].map(probeMessage(types:))

        func send(_ data: Data, to ip: in_addr) {
            var dst = sockaddr_in()
            dst.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            dst.sin_family = sa_family_t(AF_INET)
            dst.sin_port = port.bigEndian
            dst.sin_addr = ip
            data.withUnsafeBytes { buf in
                _ = withUnsafePointer(to: &dst) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(fd, buf.baseAddress, buf.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
        }

        var group = in_addr()
        inet_pton(AF_INET, multicastGroup, &group)
        let unicastIP = unicastHost.flatMap(resolveIPv4)
        for _ in 0..<2 { // UDP kann verloren gehen
            if let ip = unicastIP { messages.forEach { send($0, to: ip) } }
            for var ifAddr in ipv4Interfaces() {
                setsockopt(fd, IPPROTO_IP, IP_MULTICAST_IF, &ifAddr, socklen_t(MemoryLayout<in_addr>.size))
                messages.forEach { send($0, to: group) }
            }
        }

        var results: [String: DiscoveredEndpoint] = [:]
        var buffer = [UInt8](repeating: 0, count: 65536)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            var from = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = buffer.withUnsafeMutableBytes { buf in
                withUnsafeMutablePointer(to: &from) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        recvfrom(fd, buf.baseAddress, buf.count, 0, $0, &len)
                    }
                }
            }
            guard n > 0 else { continue }
            let ip = String(cString: inet_ntoa(from.sin_addr))
            guard let root = XNode.parse(Data(buffer[0..<n])) else { continue }
            for match in root.all("ProbeMatch") {
                guard let address = match.first("Address")?.value, !address.isEmpty else { continue }
                let types = match.first("Types")?.value ?? ""
                let xaddrs = (match.first("XAddrs")?.value ?? "")
                    .split(whereSeparator: \.isWhitespace)
                    .compactMap { URL(string: String($0)) }
                if var existing = results[address] {
                    existing.xaddrs = Array(Set(existing.xaddrs + xaddrs))
                    if existing.types.isEmpty { existing.types = types }
                    results[address] = existing
                } else {
                    results[address] = DiscoveredEndpoint(address: address, types: types, xaddrs: xaddrs, sourceIP: ip)
                }
            }
        }
        return Array(results.values)
    }

    private static func ipv4Interfaces() -> [in_addr] {
        var result: [in_addr] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return result }
        defer { freeifaddrs(list) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            guard let addr = ptr.pointee.ifa_addr, addr.pointee.sa_family == sa_family_t(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_MULTICAST != 0, flags & IFF_LOOPBACK == 0 else { continue }
            let sin = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            result.append(sin.sin_addr)
        }
        return result
    }

    private static func resolveIPv4(_ host: String) -> in_addr? {
        var addr = in_addr()
        if inet_pton(AF_INET, host, &addr) == 1 { return addr }
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_DGRAM
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &res) == 0, let info = res else { return nil }
        defer { freeaddrinfo(res) }
        return info.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
    }
}
