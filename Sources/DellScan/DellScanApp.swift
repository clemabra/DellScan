import AppKit
import SwiftUI

@main
enum Main {
    static func main() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--cli") {
            CLI.run(Array(args[(i + 1)...]))
        } else {
            DellScanApp.main()
        }
    }
}

struct DellScanApp: App {
    @StateObject private var model = ScanModel()

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        WindowGroup("Dell Scan") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 900, minHeight: 560)
        }
        .commands {
            CommandMenu("Scan") {
                Button("Scannen") { model.startScan() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!model.canScan)
                Button("Scanner suchen") { Task { await model.discover() } }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Divider()
                Button("Als PDF sichern…") { model.savePDF() }
                    .keyboardShortcut("s")
                    .disabled(model.pages.isEmpty)
            }
        }
    }
}

/// Test-/Diagnosemodus ohne Oberfläche:
///   DellScan --cli [IP] [ausgabe.pdf] [Platen|ADF|ADFDuplex]
enum CLI {
    static func run(_ args: [String]) {
        let host = args.first
        let output = URL(fileURLWithPath: args.count > 1 ? args[1] : "scan.pdf")
        let source = ScanSource(rawValue: args.count > 2 ? args[2] : "Platen") ?? .platen
        let done = DispatchSemaphore(value: 0)
        Task {
            defer { done.signal() }
            print("Suche Geräte…")
            let endpoints = await WSDiscovery.discover(timeout: 3, unicastHost: host)
            for ep in endpoints { print("  gefunden: \(ep.sourceIP) \(ep.address) [\(ep.types)] \(ep.xaddrs)") }
            var scanner: WSDScanner?
            for ep in endpoints where host == nil || ep.sourceIP == host || ep.xaddrs.contains(where: { $0.host == host }) {
                guard let s = WSDScanner(endpoint: ep) else { continue }
                do { try await s.loadMetadata(); scanner = s; break } catch { print("  \(ep.sourceIP): \(error.localizedDescription)") }
            }
            guard let scanner else { print("Kein WSD-Scanner gefunden."); return }
            print("Scanner: \(scanner.displayName) → \(scanner.scanServiceURL!)")
            do {
                let caps = try await scanner.loadCapabilities()
                print("Formate: \(caps.formats)")
                if let p = caps.platen { print("Glas: \(p.resolutions) dpi, \(p.colorModes), max \(p.maxWidth)x\(p.maxHeight)") }
                if let a = caps.adf { print("Einzug: \(a.resolutions) dpi, \(a.colorModes), duplex=\(caps.adfDuplex)") }
                let settings = ScanSettings(source: source, colorMode: "RGB24", resolution: 300, paper: .a4)
                var pages: [ScannedPage] = []
                let n = try await scanner.scan(settings: settings, capabilities: caps) { data in
                    guard let page = ScannedPage(data: data, dpi: 300) else { throw WSDError.invalidResponse("Bild nicht lesbar") }
                    print("  Seite \(pages.count + 1): \(page.image.width)x\(page.image.height), \(data.count) Bytes")
                    pages.append(page)
                }
                try Exporter.pdf(pages)?.write(to: output)
                print("\(n) Seite(n) → \(output.path)")
            } catch {
                print("Fehler: \(error.localizedDescription)")
            }
        }
        while done.wait(timeout: .now() + 0.05) == .timedOut {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
    }
}
