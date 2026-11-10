import Darwin
import Foundation
import TurboFieldfare
import TurboFieldfareServerCore

// Every request line goes to stderr, which is unbuffered, while the ready line
// below goes to stdout, which is fully buffered when it is not a terminal. A
// server started with its output redirected therefore showed an empty log for
// its whole life and printed "ready" only as it exited - exactly inverted from
// what an operator needs. Line buffering puts the line where it is useful.
setvbuf(stdout, nil, _IOLBF, 0)

let arguments: ServerArguments
let runtimeConfiguration: RuntimeConfiguration
do {
    arguments = try ServerArguments.parse(Array(CommandLine.arguments.dropFirst()))
    // Resolved here so an unusable flag combination exits with usage instead of
    // failing after the model has started loading.
    runtimeConfiguration = try arguments.resolvedRuntimeConfiguration()
} catch ServerArgumentError.help {
    print(ServerArguments.usage)
    exit(0)
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n\n\(ServerArguments.usage)\n".utf8))
    exit(2)
}

do {
    let signals = ServerTerminationSignals()
    let modelURL = URL(fileURLWithPath: arguments.model).standardizedFileURL
    let backend = try await ServerModelSession.load(
        modelDirectory: modelURL,
        maxContext: arguments.maxContext,
        visionPackURL: arguments.visionPack.map {
            URL(fileURLWithPath: $0).standardizedFileURL
        },
        visionResidencyPolicy: arguments.visionResidency,
        promptCacheMode: arguments.promptCacheMode,
        runtimeConfiguration: runtimeConfiguration)
    let server = TurboFieldfareHTTPServer(
        modelID: arguments.modelID,
        queueLimit: arguments.queueLimit,
        backend: backend,
        visionCapability: backend.visionCapability)
    _ = try await server.start(host: arguments.host, port: arguments.port)
    let ip = ((arguments.host == "0.0.0.0") ? getIPAddress() : "127.0.0.1") ?? ""
    print("TurboFieldfareServer ready at http://\(ip):\(arguments.port) model=\(arguments.modelID) context=\(arguments.maxContext) prompt_cache=\(arguments.promptCacheMode.rawValue) vision=\(backend.visionCapability) vision_residency=\(arguments.visionResidency.rawValue)")

    _ = await signals.wait()
    try await server.shutdown()
    await signals.cancel()
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}



func getIPAddress() -> String? {
    var address: String?
    var ifaddr: UnsafeMutablePointer<ifaddrs>?

    // インターフェース情報を取得
    guard getifaddrs(&ifaddr) == 0 else { return nil }
    defer { freeifaddrs(ifaddr) }

    var ptr = ifaddr
    while ptr != nil {
        defer { ptr = ptr?.pointee.ifa_next }

        guard let interface = ptr?.pointee else { continue }
        let addrFamily = interface.ifa_addr.pointee.sa_family

        // IPv4 インターフェースを対象とする場合
        if addrFamily == UInt8(AF_INET) {
            let name = String(cString: interface.ifa_name)

            // 特定のインターフェース (例: iPhoneのWi-Fiは通常 "en0") を指定する場合
            // if name == "en0" {

            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(interface.ifa_addr,
                        socklen_t(interface.ifa_addr.pointee.sa_len),
                        &hostname,
                        socklen_t(hostname.count),
                        nil,
                        socklen_t(0),
                        NI_NUMERICHOST)

            address = String(cString: &hostname)
            // if name == "en0" { break } // 必要に応じてループを抜ける
        }
    }

    return address
}
