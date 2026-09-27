import Foundation

enum WSDError: LocalizedError {
    case http(Int)
    case fault(code: String, reason: String)
    case invalidResponse(String)
    case noScanService
    case adfEmpty

    var errorDescription: String? {
        switch self {
        case .http(let status): return "Der Scanner antwortete mit HTTP-Status \(status)."
        case .fault(let code, let reason):
            let text = reason.isEmpty ? code : "\(reason) (\(code))"
            return "Scanner meldet Fehler: \(text)"
        case .invalidResponse(let what): return "Unerwartete Antwort vom Scanner: \(what)"
        case .noScanService: return "Das Gerät bietet keinen WSD-Scan-Dienst an."
        case .adfEmpty: return "Im Vorlageneinzug liegt kein Papier."
        }
    }
}

enum ScanSource: String, CaseIterable, Identifiable, Codable {
    case platen = "Platen", adf = "ADF", adfDuplex = "ADFDuplex"
    var id: String { rawValue }
    var label: String {
        switch self {
        case .platen: return "Vorlagenglas"
        case .adf: return "Einzug (einseitig)"
        case .adfDuplex: return "Einzug (beidseitig)"
        }
    }
}

enum PaperSize: String, CaseIterable, Identifiable, Codable {
    case a4, a5, letter, legal, maximum
    var id: String { rawValue }
    var label: String {
        switch self {
        case .a4: return "A4"
        case .a5: return "A5"
        case .letter: return "US Letter"
        case .legal: return "US Legal"
        case .maximum: return "Maximal"
        }
    }
    /// Größe in 1/1000 Zoll (WSD-Einheit).
    var size: (width: Int, height: Int) {
        switch self {
        case .a4: return (8268, 11693)
        case .a5: return (5827, 8268)
        case .letter: return (8500, 11000)
        case .legal: return (8500, 14000)
        case .maximum: return (100_000, 100_000)
        }
    }
}

struct ScanSettings {
    var source: ScanSource
    var colorMode: String  // RGB24, Grayscale8, BlackAndWhite1
    var resolution: Int
    var paper: PaperSize
}

struct SourceCapabilities {
    var resolutions: [Int]
    var colorModes: [String]
    var maxWidth: Int
    var maxHeight: Int
}

struct ScannerCapabilities {
    var platen: SourceCapabilities?
    var adf: SourceCapabilities?
    var adfDuplex: Bool
    var formats: [String]

    var sources: [ScanSource] {
        var result: [ScanSource] = []
        if platen != nil { result.append(.platen) }
        if adf != nil { result.append(.adf) }
        if adf != nil && adfDuplex { result.append(.adfDuplex) }
        return result
    }

    func caps(for source: ScanSource) -> SourceCapabilities? {
        source == .platen ? platen : adf
    }

    func format(for colorMode: String) -> String {
        let preferred = colorMode == "BlackAndWhite1"
            ? ["png", "tiff-single-uncompressed", "dib", "jfif"]
            : ["jfif", "png", "dib", "tiff-single-uncompressed"]
        return preferred.first(where: formats.contains) ?? formats.first ?? "jfif"
    }
}

/// Client für das WSD-Scan-Protokoll (WS-Scan, "Scan: WSD" am Dell).
final class WSDScanner: @unchecked Sendable {
    static let scanNS = "http://schemas.microsoft.com/windows/2006/08/wdp/scan"

    let endpoint: DiscoveredEndpoint
    let metadataURL: URL
    private(set) var scanServiceURL: URL?
    private(set) var friendlyName: String?
    private(set) var modelName: String?

    var displayName: String { friendlyName ?? modelName ?? endpoint.sourceIP }

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 600
        config.httpMaximumConnectionsPerHost = 1
        return URLSession(configuration: config)
    }()

    init?(endpoint: DiscoveredEndpoint) {
        // Bevorzugt die Adresse, von der die Antwort kam (IPv4).
        let url = endpoint.xaddrs.first { $0.host == endpoint.sourceIP }
            ?? endpoint.xaddrs.first { ($0.host ?? "").contains(".") && !($0.host ?? "").contains(":") }
            ?? endpoint.xaddrs.first
        guard let url else { return nil }
        self.endpoint = endpoint
        self.metadataURL = url
    }

    // MARK: Metadaten

    func loadMetadata() async throws {
        let (data, _) = try await post(url: metadataURL, to: endpoint.address,
                                       action: "http://schemas.xmlsoap.org/ws/2004/09/transfer/Get",
                                       body: "", timeout: 8)
        guard let root = XNode.parse(data) else { throw WSDError.invalidResponse("Metadaten nicht lesbar") }
        friendlyName = root.first("ThisDevice")?.child("FriendlyName")?.value.nilIfEmpty
        if let model = root.first("ThisModel") {
            let parts = [model.child("Manufacturer")?.value, model.child("ModelName")?.value].compactMap { $0?.nilIfEmpty }
            modelName = parts.isEmpty ? nil : parts.joined(separator: " ")
        }
        for hosted in root.all("Hosted") where (hosted.child("Types")?.value ?? "").contains("ScannerServiceType") {
            if let address = hosted.first("Address")?.value, var url = URL(string: address) {
                // Manche Geräte melden Hostnamen, die der Mac nicht auflösen kann → IP der Antwort verwenden.
                if let host = url.host, host != metadataURL.host, !host.contains("."),
                   var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                    comps.host = metadataURL.host
                    url = comps.url ?? url
                }
                scanServiceURL = url
                return
            }
        }
        throw WSDError.noScanService
    }

    // MARK: Fähigkeiten

    func loadCapabilities() async throws -> ScannerCapabilities {
        let body = """
        <wscn:GetScannerElementsRequest><wscn:RequestedElements>\
        <wscn:Name>wscn:ScannerDescription</wscn:Name>\
        <wscn:Name>wscn:ScannerConfiguration</wscn:Name>\
        <wscn:Name>wscn:DefaultScanTicket</wscn:Name>\
        </wscn:RequestedElements></wscn:GetScannerElementsRequest>
        """
        let (data, _) = try await scanRequest("GetScannerElements", body: body, timeout: 15)
        guard let root = XNode.parse(data), let config = root.first("ScannerConfiguration") else {
            throw WSDError.invalidResponse("Scanner-Konfiguration fehlt")
        }
        let formats = config.first("FormatsSupported")?.all("FormatValue").map(\.value) ?? []
        let platen = config.first("Platen").map(Self.parseSource)
        var adf: SourceCapabilities?
        var duplex = false
        if let adfNode = config.first("ADF") {
            adf = Self.parseSource(adfNode.first("ADFFront") ?? adfNode)
            duplex = ["true", "1"].contains(adfNode.first("ADFSupportsDuplex")?.value.lowercased() ?? "")
        }
        return ScannerCapabilities(platen: platen, adf: adf, adfDuplex: duplex, formats: formats)
    }

    private static func parseSource(_ node: XNode) -> SourceCapabilities {
        let resolutions = node.first { $0.name.hasSuffix("Resolutions") }?
            .first("Widths")?.all("Width").compactMap { Int($0.value) } ?? []
        let colors = node.all("ColorEntry").map(\.value)
        let maxSize = node.first { $0.name.hasSuffix("MaximumSize") }
        return SourceCapabilities(
            resolutions: resolutions.isEmpty ? [150, 200, 300, 600] : Array(Set(resolutions)).sorted(),
            colorModes: colors.isEmpty ? ["RGB24", "Grayscale8", "BlackAndWhite1"] : colors,
            maxWidth: Int(maxSize?.child("Width")?.value ?? "") ?? 8500,
            maxHeight: Int(maxSize?.child("Height")?.value ?? "") ?? 14000)
    }

    // MARK: Scannen

    /// Scannt und liefert jede Seite als Bilddatei (JPEG/PNG/BMP/TIFF) an `onPage`. Gibt die Seitenzahl zurück.
    func scan(settings: ScanSettings, capabilities: ScannerCapabilities,
              onPage: @escaping @MainActor (Data) throws -> Void) async throws -> Int {
        let caps = capabilities.caps(for: settings.source)
        let width = min(settings.paper.size.width, caps?.maxWidth ?? 8500)
        let height = min(settings.paper.size.height, caps?.maxHeight ?? 14000)
        let format = capabilities.format(for: settings.colorMode)
        let imagesToTransfer = settings.source == .platen ? 1 : 0

        let front = """
        <wscn:ScanRegion>\
        <wscn:ScanRegionXOffset>0</wscn:ScanRegionXOffset>\
        <wscn:ScanRegionYOffset>0</wscn:ScanRegionYOffset>\
        <wscn:ScanRegionWidth>\(width)</wscn:ScanRegionWidth>\
        <wscn:ScanRegionHeight>\(height)</wscn:ScanRegionHeight>\
        </wscn:ScanRegion>\
        <wscn:ColorProcessing>\(settings.colorMode)</wscn:ColorProcessing>\
        <wscn:Resolution><wscn:Width>\(settings.resolution)</wscn:Width><wscn:Height>\(settings.resolution)</wscn:Height></wscn:Resolution>
        """
        let sides = settings.source == .adfDuplex
            ? "<wscn:MediaFront>\(front)</wscn:MediaFront><wscn:MediaBack>\(front)</wscn:MediaBack>"
            : "<wscn:MediaFront>\(front)</wscn:MediaFront>"
        let body = """
        <wscn:CreateScanJobRequest><wscn:ScanTicket>\
        <wscn:JobDescription>\
        <wscn:JobName>Dell Scan</wscn:JobName>\
        <wscn:JobOriginatingUserName>\(xmlEscape(NSUserName()))</wscn:JobOriginatingUserName>\
        <wscn:JobInformation>Scan vom Mac</wscn:JobInformation>\
        </wscn:JobDescription>\
        <wscn:DocumentParameters>\
        <wscn:Format>\(format)</wscn:Format>\
        <wscn:ImagesToTransfer>\(imagesToTransfer)</wscn:ImagesToTransfer>\
        <wscn:InputSource>\(settings.source.rawValue)</wscn:InputSource>\
        <wscn:InputSize><wscn:InputMediaSize><wscn:Width>\(width)</wscn:Width><wscn:Height>\(height)</wscn:Height></wscn:InputMediaSize></wscn:InputSize>\
        <wscn:MediaSides>\(sides)</wscn:MediaSides>\
        </wscn:DocumentParameters>\
        </wscn:ScanTicket></wscn:CreateScanJobRequest>
        """

        // Beschäftigte Geräte lehnen Jobs kurzzeitig ab → ein paar Versuche.
        var jobResponse: Data?
        for attempt in 0..<4 {
            do {
                jobResponse = try await scanRequest("CreateScanJob", body: body, timeout: 30).0
                break
            } catch WSDError.fault(let code, _) where code.contains("NotAcceptingJobs") || code.contains("Busy") {
                if attempt == 3 { throw WSDError.fault(code: code, reason: "Scanner ist beschäftigt") }
                try await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        guard let jobData = jobResponse, let root = XNode.parse(jobData),
              let jobId = root.first("JobId")?.value, let jobToken = root.first("JobToken")?.value else {
            throw WSDError.invalidResponse("Scan-Auftrag ohne JobId")
        }

        var count = 0
        do {
            while true {
                try Task.checkCancellation()
                do {
                    let image = try await retrieveImage(jobId: jobId, jobToken: jobToken, format: format)
                    count += 1
                    try await onPage(image)
                    if settings.source == .platen { break }
                } catch WSDError.fault(let code, let reason) {
                    let finished = ["NoImagesAvailable", "JobIdNotFound", "JobCompleted", "InvalidJobToken"]
                        .contains { code.contains($0) }
                    guard finished else { throw WSDError.fault(code: code, reason: reason) }
                    if count == 0 && settings.source != .platen { throw WSDError.adfEmpty }
                    if count == 0 { throw WSDError.fault(code: code, reason: reason) }
                    break
                }
            }
        } catch {
            if count == 0 || error is CancellationError || (error as? URLError)?.code == .cancelled {
                await cancelJob(jobId: jobId)
            }
            throw error
        }
        return count
    }

    private func retrieveImage(jobId: String, jobToken: String, format: String) async throws -> Data {
        let body = """
        <wscn:RetrieveImageRequest>\
        <wscn:JobId>\(xmlEscape(jobId))</wscn:JobId>\
        <wscn:JobToken>\(xmlEscape(jobToken))</wscn:JobToken>\
        <wscn:DocumentDescription><wscn:DocumentName>IMAGE.\(format == "jfif" ? "JPG" : format.uppercased())</wscn:DocumentName></wscn:DocumentDescription>\
        </wscn:RetrieveImageRequest>
        """
        let (data, response) = try await scanRequest("RetrieveImage", body: body, timeout: 300)
        let image = try Self.extractImage(from: data, contentType: response.value(forHTTPHeaderField: "Content-Type") ?? "")
        return format == "dib" ? (ImageDecoding.bmpAddingFileHeader(image) ?? image) : image
    }

    private func cancelJob(jobId: String) async {
        let body = "<wscn:CancelJobRequest><wscn:JobId>\(xmlEscape(jobId))</wscn:JobId></wscn:CancelJobRequest>"
        _ = try? await scanRequest("CancelJob", body: body, timeout: 10)
    }

    // MARK: SOAP-Transport

    private func scanRequest(_ operation: String, body: String, timeout: TimeInterval) async throws -> (Data, HTTPURLResponse) {
        guard let url = scanServiceURL else { throw WSDError.noScanService }
        return try await post(url: url, to: url.absoluteString, action: "\(Self.scanNS)/\(operation)",
                              body: body, timeout: timeout)
    }

    private func post(url: URL, to: String, action: String, body: String,
                      timeout: TimeInterval) async throws -> (Data, HTTPURLResponse) {
        let envelope = """
        <?xml version="1.0" encoding="utf-8"?>
        <soap:Envelope xmlns:soap="http://www.w3.org/2003/05/soap-envelope" \
        xmlns:wsa="http://schemas.xmlsoap.org/ws/2004/08/addressing" \
        xmlns:wscn="\(Self.scanNS)">\
        <soap:Header>\
        <wsa:To>\(xmlEscape(to))</wsa:To>\
        <wsa:Action>\(action)</wsa:Action>\
        <wsa:MessageID>urn:uuid:\(UUID().uuidString.lowercased())</wsa:MessageID>\
        <wsa:ReplyTo><wsa:Address>http://schemas.xmlsoap.org/ws/2004/08/addressing/role/anonymous</wsa:Address></wsa:ReplyTo>\
        </soap:Header>\
        <soap:Body>\(body)</soap:Body>\
        </soap:Envelope>
        """
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/soap+xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(envelope.utf8)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw WSDError.invalidResponse("keine HTTP-Antwort") }
        let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        if !contentType.contains("multipart"), let fault = XNode.parse(data)?.first("Fault") {
            let code = fault.first("Subcode")?.first("Value")?.value ?? fault.first("Value")?.value ?? "Fault"
            let reason = fault.first("Reason")?.first("Text")?.value ?? ""
            throw WSDError.fault(code: code, reason: reason)
        }
        guard (200..<300).contains(http.statusCode) else { throw WSDError.http(http.statusCode) }
        return (data, http)
    }

    // MARK: MTOM/Multipart

    static func extractImage(from data: Data, contentType: String) throws -> Data {
        if let boundary = multipartBoundary(contentType) {
            let parts = multipartParts(data, boundary: boundary)
            if let image = parts.first(where: { !partContentType($0.headers).contains("xml") }) {
                return image.body
            }
            if parts.count >= 2 { return parts[1].body }
        }
        // Fallback: Bild inline als Base64
        if let root = XNode.parse(data), let scanData = root.first("ScanData"),
           let decoded = Data(base64Encoded: scanData.value, options: .ignoreUnknownCharacters), !decoded.isEmpty {
            return decoded
        }
        throw WSDError.invalidResponse("kein Bild in der Antwort")
    }

    private static func multipartBoundary(_ contentType: String) -> String? {
        for param in contentType.split(separator: ";") {
            let trimmed = param.trimmingCharacters(in: .whitespaces)
            guard trimmed.lowercased().hasPrefix("boundary=") else { continue }
            var value = String(trimmed.dropFirst("boundary=".count))
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") { value = String(value.dropFirst().dropLast()) }
            return value
        }
        return nil
    }

    private static func partContentType(_ headers: String) -> String {
        headers.components(separatedBy: "\r\n")
            .first { $0.lowercased().hasPrefix("content-type:") }?
            .lowercased() ?? ""
    }

    static func multipartParts(_ data: Data, boundary: String) -> [(headers: String, body: Data)] {
        let delimiter = Data(("--" + boundary).utf8)
        var ranges: [Range<Data.Index>] = []
        var searchStart = data.startIndex
        while let r = data.range(of: delimiter, in: searchStart..<data.endIndex) {
            ranges.append(r)
            searchStart = r.upperBound
        }
        guard ranges.count >= 2 else { return [] }
        var parts: [(String, Data)] = []
        let headerEnd = Data("\r\n\r\n".utf8)
        let crlf = Data("\r\n".utf8)
        for i in 0..<(ranges.count - 1) {
            let part = data[ranges[i].upperBound..<ranges[i + 1].lowerBound]
            guard let h = part.range(of: headerEnd) else { continue }
            let headers = String(decoding: part[part.startIndex..<h.lowerBound], as: UTF8.self)
            var body = part[h.upperBound..<part.endIndex]
            if body.suffix(2) == crlf { body = body.dropLast(2) }
            parts.append((headers.trimmingCharacters(in: .whitespacesAndNewlines), Data(body)))
        }
        return parts
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
