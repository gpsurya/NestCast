import Foundation
import Network

@MainActor
public class CastDiscovery: NSObject, ObservableObject {
    @Published public var devices: [CastDevice] = []
    @Published public var isScanning: Bool = false
    @Published public var lastScanDate: Date?
    
    private var browser: NetServiceBrowser?
    private var activeServices: [NetService] = []
    private var scanTask: Task<Void, Never>?
    
    public override init() {
        super.init()
    }
    
    public func startDiscovery() {
        guard !isScanning else { return }
        isScanning = true
        activeServices.removeAll()
        scanTask?.cancel()
        
        LogManager.shared.info("Discovery", "Starting mDNS browse for _googlecast._tcp...")
        
        browser = NetServiceBrowser()
        browser?.delegate = self
        browser?.searchForServices(ofType: "_googlecast._tcp.", inDomain: "local.")
        
        // Auto-stop scan after 10 seconds to save battery, but keep discovered list
        scanTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 10 * 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.stopDiscovery()
        }
    }
    
    public func stopDiscovery() {
        scanTask?.cancel()
        scanTask = nil
        browser?.stop()
        browser = nil
        isScanning = false
        lastScanDate = Date()
        LogManager.shared.info("Discovery", "mDNS browse stopped. Total speakers found: \(devices.count)")
    }
    
    public func refresh() {
        stopDiscovery()
        devices.removeAll()
        startDiscovery()
    }
    
    private func updateDevice(from service: NetService) {
        guard let txtData = service.txtRecordData() else { return }
        let dict = NetService.dictionary(fromTXTRecord: txtData)
        
        let friendlyName = dict["fn"].flatMap { String(data: $0, encoding: .utf8) } ?? service.name
        let model = dict["md"].flatMap { String(data: $0, encoding: .utf8) } ?? "Google Nest Mini"
        let deviceId = dict["id"].flatMap { String(data: $0, encoding: .utf8) } ?? service.name
        let hostName = service.hostName ?? "\(service.name).local."
        let port = service.port > 0 ? service.port : 8009
        
        var ipAddress: String?
        if let addresses = service.addresses {
            for data in addresses {
                data.withUnsafeBytes { ptr in
                    guard let sockaddrPtr = ptr.baseAddress?.assumingMemoryBound(to: sockaddr.self) else { return }
                    if sockaddrPtr.pointee.sa_family == UInt8(AF_INET) {
                        var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                        if getnameinfo(sockaddrPtr, socklen_t(data.count), &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST) == 0 {
                            ipAddress = String(cString: hostname)
                        }
                    }
                }
                if ipAddress != nil { break }
            }
        }
        
        let cleanHost = hostName.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        
        let newDevice = CastDevice(
            id: deviceId,
            name: friendlyName,
            model: model,
            host: cleanHost,
            port: port,
            ipAddress: ipAddress,
            status: "Available",
            volume: 0.5,
            isMuted: false,
            isConnected: false
        )
        
        if let index = devices.firstIndex(where: { $0.id == deviceId }) {
            devices[index].name = friendlyName
            devices[index].model = model
            devices[index].host = cleanHost
            if let ip = ipAddress {
                devices[index].ipAddress = ip
            }
        } else {
            devices.append(newDevice)
            LogManager.shared.info("Discovery", "Discovered speaker: '\(friendlyName)' (\(model)) at \(ipAddress ?? cleanHost)")
        }
        
        if let targetIP = ipAddress {
            Task {
                await self.queryEurekaInfo(ip: targetIP, deviceId: deviceId)
            }
        }
    }
    
    private func queryEurekaInfo(ip: String, deviceId: String) async {
        guard let url = URL(string: "https://\(ip):8443/setup/eureka_info") else { return }
        let session = URLSession(configuration: .ephemeral, delegate: InsecureCertDelegate(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        
        do {
            let (data, response) = try await session.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return }
            
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let name = json["name"] as? String {
                if let idx = self.devices.firstIndex(where: { $0.id == deviceId }) {
                    self.devices[idx].name = name
                    self.devices[idx].ipAddress = ip
                    LogManager.shared.info("Discovery", "Resolved Eureka name: '\(name)' for \(ip)")
                }
            }
        } catch {
            // Eureka port is optional
        }
    }
}

extension CastDiscovery: NetServiceBrowserDelegate {
    public nonisolated func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        service.delegate = self
        service.resolve(withTimeout: 5.0)
        Task { @MainActor in
            self.activeServices.append(service)
        }
    }
    
    public nonisolated func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        Task { @MainActor in
            self.activeServices.removeAll(where: { $0.name == service.name })
            // Prune matching either device ID or Bonjour service name
            self.devices.removeAll(where: {
                $0.id == service.name ||
                $0.host.localizedCaseInsensitiveContains(service.name) ||
                $0.name == service.name
            })
        }
    }
}

extension CastDiscovery: NetServiceDelegate {
    public nonisolated func netServiceDidResolveAddress(_ sender: NetService) {
        Task { @MainActor in
            self.updateDevice(from: sender)
        }
    }
}

private class InsecureCertDelegate: NSObject, URLSessionDelegate {
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let serverTrust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
