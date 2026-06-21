import Foundation
import Network

/// WebDAV 服务器 - 通过 WiFi 共享文件
class TRDavServer: ObservableObject {
    static let shared = TRDavServer()
    
    @Published var isRunning = false
    @Published var serverURL: String?
    
    private var listener: NWListener?
    private let port: UInt16 = 8080
    private let recordingsDir: URL
    
    init() {
        recordingsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    
    func start() {
        guard !isRunning else { return }
        
        do {
            let parameters = NWParameters.tcp
            listener = try NWListener(using: parameters, on: NWEndpoint.Port(integerLiteral: port))
            
            listener?.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    DispatchQueue.main.async {
                        self?.isRunning = true
                        self?.serverURL = "http://\(self?.getWiFiAddress() ?? "localhost"):\(self?.port ?? 8080)"
                    }
                case .failed(let error):
                    print("DAV server failed: \(error)")
                    DispatchQueue.main.async { self?.isRunning = false }
                default:
                    break
                }
            }
            
            listener?.newConnectionHandler = { [weak self] connection in
                self?.handleConnection(connection)
            }
            
            listener?.start(queue: .global())
        } catch {
            print("Failed to start DAV server: \(error)")
        }
    }
    
    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
        serverURL = nil
    }
    
    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .global())
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, _ in
            if let data = data, let request = String(data: data, encoding: .utf8) {
                self?.processHTTPRequest(request, on: connection)
            }
            connection.cancel()
        }
    }
    
    private func processHTTPRequest(_ request: String, on connection: NWConnection) {
        let lines = request.components(separatedBy: "\r\n")
        guard let firstLine = lines.first else { return }
        
        let parts = firstLine.components(separatedBy: " ")
        guard parts.count >= 2 else { return }
        
        let method = parts[0]
        let path = parts[1].removingPercentEncoding ?? parts[1]
        
        if method == "GET" || method == "HEAD" {
            if path == "/" || path == "/index.html" {
                sendDirectoryListing(on: connection)
            } else {
                let fileName = String(path.dropFirst())
                sendFile(fileName, on: connection, headOnly: method == "HEAD")
            }
        } else {
            sendResponse(status: 405, body: "Method Not Allowed", on: connection)
        }
    }
    
    private func sendDirectoryListing(on connection: NWConnection) {
        let files = (try? FileManager.default.contentsOfDirectory(at: recordingsDir, includingPropertiesForKeys: nil)) ?? []
        let audioFiles = files.filter { $0.pathExtension == "m4a" || $0.pathExtension == "wav" || $0.pathExtension == "mp3" }
        
        var html = "<html><head><title>CallRecorder Files</title></head><body>"
        html += "<h1>CallRecorder Recordings</h1><ul>"
        for file in audioFiles {
            html += "<li><a href=\"/\(file.lastPathComponent)\">\(file.lastPathComponent)</a></li>"
        }
        html += "</ul></body></html>"
        
        sendResponse(status: 200, body: html, contentType: "text/html", on: connection)
    }
    
    private func sendFile(_ fileName: String, on connection: NWConnection, headOnly: Bool) {
        let fileURL = recordingsDir.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: fileURL) else {
            sendResponse(status: 404, body: "Not Found", on: connection)
            return
        }
        
        if headOnly {
            sendResponse(status: 200, body: "", contentType: "application/octet-stream", on: connection)
        } else {
            sendResponse(status: 200, body: data, contentType: "application/octet-stream", on: connection)
        }
    }
    
    private func sendResponse(status: Int, body: String, contentType: String = "text/plain", on connection: NWConnection) {
        sendResponse(status: status, body: body.data(using: .utf8) ?? Data(), contentType: contentType, on: connection)
    }
    
    private func sendResponse(status: Int, body: Data, contentType: String, on connection: NWConnection) {
        let statusText = status == 200 ? "OK" : status == 404 ? "Not Found" : "Error"
        let header = "HTTP/1.1 \(status) \(statusText)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var response = header.data(using: .utf8) ?? Data()
        response.append(body)
        connection.send(content: response, completion: .idempotent)
    }
    
    private func getWiFiAddress() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return nil }
        var ptr = ifaddr
        while ptr != nil {
            let flags = Int32(ptr!.pointee.ifa_flags)
            let name = String(cString: ptr!.pointee.ifa_name)
            if name == "en0" {
                var addr = ptr!.pointee.ifa_addr.pointee
                if addr.sa_family == UInt8(AF_INET) {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(&addr, socklen_t(addr.sa_len), &hostname, socklen_t(hostname.count), nil, socklen_t(0), NI_NUMERICHOST)
                    address = String(cString: hostname)
                }
            }
            ptr = ptr!.pointee.ifa_next
        }
        freeifaddrs(ifaddr)
        return address
    }
}