import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
final class ScanModel: ObservableObject {
    struct Device: Identifiable, Hashable {
        let id: String
        let name: String
        let host: String
    }

    @Published var devices: [Device] = []
    @Published var selectedID: String? {
        didSet { if oldValue != selectedID { Task { await connect() } } }
    }
    @Published var capabilities: ScannerCapabilities?
    @Published var source: ScanSource = .platen { didSet { normalizeSettings(); save() } }
    @Published var colorMode = "RGB24" { didSet { save() } }
    @Published var resolution = 300 { didSet { save() } }
    @Published var paper: PaperSize = .a4 { didSet { save() } }
    @Published var manualHost: String { didSet { defaults.set(manualHost, forKey: "manualHost") } }

    @Published var pages: [ScannedPage] = []
    @Published var previewPage: ScannedPage?
    @Published var isScanning = false
    @Published var isDiscovering = false
    @Published var isConnecting = false
    @Published var status = ""
    @Published var errorMessage: String?

    private var scanners: [String: WSDScanner] = [:]
    private var scanTask: Task<Void, Never>?
    private let defaults = UserDefaults.standard

    init() {
        manualHost = defaults.string(forKey: "manualHost") ?? ""
        source = ScanSource(rawValue: defaults.string(forKey: "source") ?? "") ?? .platen
        colorMode = defaults.string(forKey: "colorMode") ?? "RGB24"
        let savedResolution = defaults.integer(forKey: "resolution")
        resolution = savedResolution > 0 ? savedResolution : 300
        paper = PaperSize(rawValue: defaults.string(forKey: "paper") ?? "") ?? .a4
    }

    private func save() {
        defaults.set(source.rawValue, forKey: "source")
        defaults.set(colorMode, forKey: "colorMode")
        defaults.set(resolution, forKey: "resolution")
        defaults.set(paper.rawValue, forKey: "paper")
    }

    var scanner: WSDScanner? { selectedID.flatMap { scanners[$0] } }
    var canScan: Bool { scanner != nil && capabilities != nil && !isScanning && !isConnecting }
    var availableSources: [ScanSource] { capabilities?.sources ?? ScanSource.allCases }
    var currentCaps: SourceCapabilities? { capabilities?.caps(for: source) }
    var availableColorModes: [String] { currentCaps?.colorModes ?? ["RGB24", "Grayscale8", "BlackAndWhite1"] }
    var availableResolutions: [Int] { currentCaps?.resolutions ?? [150, 200, 300, 600] }

    static func colorLabel(_ mode: String) -> String {
        switch mode {
        case "RGB24": return "Farbe"
        case "Grayscale8": return "Graustufen"
        case "BlackAndWhite1": return "Schwarzweiß"
        default: return mode
        }
    }

    // MARK: Suche & Verbindung

    func discover() async {
        guard !isDiscovering else { return }
        isDiscovering = true
        status = "Suche Scanner im Netzwerk…"
        let host = manualHost.trimmingCharacters(in: .whitespaces)
        let endpoints = await WSDiscovery.discover(timeout: 3, unicastHost: host.isEmpty ? nil : host)
        for endpoint in endpoints where scanners[endpoint.address] == nil {
            guard let scanner = WSDScanner(endpoint: endpoint) else { continue }
            do {
                try await scanner.loadMetadata()
            } catch {
                continue // kein Scanner (z. B. reiner Drucker) oder nicht erreichbar
            }
            scanners[endpoint.address] = scanner
            devices.append(Device(id: endpoint.address, name: scanner.displayName,
                                  host: scanner.scanServiceURL?.host ?? endpoint.sourceIP))
        }
        devices.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        isDiscovering = false
        if selectedID == nil || scanners[selectedID!] == nil {
            selectedID = devices.first { $0.name.localizedCaseInsensitiveContains("dell") }?.id ?? devices.first?.id
        }
        if devices.isEmpty {
            status = "Kein Scanner gefunden – Drucker im selben Netz? Netzwerkzugriff (Firewall/„Lokales Netzwerk“) erlaubt?"
        } else if !isConnecting {
            status = "\(devices.count) Scanner gefunden"
        }
    }

    private func connect() async {
        capabilities = nil
        guard let scanner else { return }
        isConnecting = true
        status = "Verbinde mit \(scanner.displayName)…"
        do {
            capabilities = try await scanner.loadCapabilities()
            normalizeSettings()
            status = "Bereit – \(scanner.displayName)"
        } catch {
            status = "Verbindung fehlgeschlagen"
            errorMessage = error.localizedDescription
        }
        isConnecting = false
    }

    private func normalizeSettings() {
        guard capabilities != nil else { return }
        if !availableSources.contains(source), let first = availableSources.first { source = first }
        if !availableColorModes.contains(colorMode), let first = availableColorModes.first { colorMode = first }
        if !availableResolutions.contains(resolution) {
            resolution = availableResolutions.min { abs($0 - 300) < abs($1 - 300) } ?? 300
        }
    }

    // MARK: Scannen

    func startScan() {
        guard let scanner, let capabilities, !isScanning else { return }
        let settings = ScanSettings(source: source, colorMode: colorMode, resolution: resolution, paper: paper)
        isScanning = true
        status = settings.source == .platen ? "Scanne…" : "Scanne aus dem Einzug…"
        scanTask = Task {
            do {
                let count = try await scanner.scan(settings: settings, capabilities: capabilities) { [weak self] data in
                    guard let self else { return }
                    guard let page = ScannedPage(data: data, dpi: settings.resolution) else {
                        throw WSDError.invalidResponse("Bildformat nicht lesbar")
                    }
                    self.pages.append(page)
                    self.status = "Seite \(self.pages.count) empfangen…"
                }
                status = count == 1 ? "1 Seite gescannt" : "\(count) Seiten gescannt"
            } catch is CancellationError {
                status = "Scan abgebrochen"
            } catch let error as URLError where error.code == .cancelled {
                status = "Scan abgebrochen"
            } catch {
                status = "Scan fehlgeschlagen"
                errorMessage = error.localizedDescription
            }
            isScanning = false
            scanTask = nil
        }
    }

    func cancelScan() { scanTask?.cancel() }

    // MARK: Seiten

    func rotate(_ page: ScannedPage, by turns: Int) {
        guard let i = pages.firstIndex(where: { $0.id == page.id }) else { return }
        pages[i].rotate(by: turns)
    }

    func delete(_ page: ScannedPage) { pages.removeAll { $0.id == page.id } }

    func move(_ page: ScannedPage, by offset: Int) {
        guard let i = pages.firstIndex(where: { $0.id == page.id }) else { return }
        let j = i + offset
        guard pages.indices.contains(j) else { return }
        pages.swapAt(i, j)
    }

    func removeAll() { pages.removeAll() }

    private var defaultName: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return "Scan \(f.string(from: Date()))"
    }

    func savePDF() {
        guard !pages.isEmpty else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = defaultName + ".pdf"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let data = Exporter.pdf(pages) else { errorMessage = "PDF konnte nicht erzeugt werden."; return }
        do {
            try data.write(to: url)
            status = "Gespeichert: \(url.lastPathComponent)"
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func saveImages() {
        guard !pages.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Hier sichern"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        let base = defaultName
        var written: [URL] = []
        for (i, page) in pages.enumerated() {
            guard let file = Exporter.imageFile(page) else { continue }
            let url = folder.appendingPathComponent(pages.count == 1 ? "\(base).\(file.ext)" : "\(base) - Seite \(i + 1).\(file.ext)")
            do { try file.data.write(to: url); written.append(url) } catch { errorMessage = error.localizedDescription; return }
        }
        status = "\(written.count) Bild(er) gespeichert"
        NSWorkspace.shared.activateFileViewerSelecting(written)
    }
}
