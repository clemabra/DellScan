import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: ScanModel

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 230, ideal: 260, max: 340)
        } detail: {
            DetailView()
        }
        .task { await model.discover() }
        .alert("Fehler", isPresented: Binding(get: { model.errorMessage != nil },
                                              set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .sheet(item: $model.previewPage) { page in
            PreviewSheet(page: page)
        }
    }
}

struct SidebarView: View {
    @EnvironmentObject var model: ScanModel

    var body: some View {
        List(selection: $model.selectedID) {
            Section("Scanner") {
                ForEach(model.devices) { device in
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(device.name)
                            Text(device.host).font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "scanner")
                    }
                    .tag(device.id)
                }
                if model.devices.isEmpty {
                    Text(model.isDiscovering ? "Suche läuft…" : "Keine Scanner gefunden")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text("IP-Adresse des Druckers (optional)")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    TextField("z. B. 192.168.1.50", text: $model.manualHost)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { Task { await model.discover() } }
                    Button {
                        Task { await model.discover() }
                    } label: {
                        if model.isDiscovering {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .help("Scanner suchen")
                    .disabled(model.isDiscovering)
                }
            }
            .padding(12)
        }
    }
}

struct DetailView: View {
    @EnvironmentObject var model: ScanModel

    var body: some View {
        VStack(spacing: 0) {
            SettingsBar()
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            Divider()
            if model.pages.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "doc.viewfinder")
                        .font(.system(size: 56, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text("Noch keine Seiten").font(.title3)
                    Text("Dokument einlegen und auf „Scannen“ klicken.\nWeitere Scans werden als zusätzliche Seiten angehängt.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 20)], spacing: 20) {
                        ForEach(Array(model.pages.enumerated()), id: \.element.id) { index, page in
                            PageCell(page: page, number: index + 1)
                        }
                    }
                    .padding(20)
                }
            }
            Divider()
            HStack(spacing: 12) {
                Text(model.status)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
                if !model.pages.isEmpty {
                    Text(model.pages.count == 1 ? "1 Seite" : "\(model.pages.count) Seiten")
                        .foregroundStyle(.secondary)
                    Button("Alle entfernen", role: .destructive) { model.removeAll() }
                    Button("Als Bilder sichern…") { model.saveImages() }
                }
                Button("Als PDF sichern…") { model.savePDF() }
                    .keyboardShortcut("s")
                    .buttonStyle(.borderedProminent)
                    .disabled(model.pages.isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(minWidth: 640, minHeight: 420)
        .navigationTitle(model.scanner?.displayName ?? "Dell Scan")
    }
}

struct SettingsBar: View {
    @EnvironmentObject var model: ScanModel

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) { pickers }
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                    GridRow { sourcePicker; colorPicker }
                    GridRow { resolutionPicker; paperPicker }
                }
            }
            Spacer(minLength: 0)
            scanButton
        }
    }

    @ViewBuilder private var pickers: some View {
        sourcePicker; colorPicker; resolutionPicker; paperPicker
    }

    private var sourcePicker: some View {
        Picker("Quelle", selection: $model.source) {
            ForEach(model.availableSources) { Text($0.label).tag($0) }
        }
        .fixedSize()
    }

    private var colorPicker: some View {
        Picker("Modus", selection: $model.colorMode) {
            ForEach(model.availableColorModes, id: \.self) { Text(ScanModel.colorLabel($0)).tag($0) }
        }
        .fixedSize()
    }

    private var resolutionPicker: some View {
        Picker("Auflösung", selection: $model.resolution) {
            ForEach(model.availableResolutions, id: \.self) { Text("\($0) dpi").tag($0) }
        }
        .fixedSize()
    }

    private var paperPicker: some View {
        Picker("Größe", selection: $model.paper) {
            ForEach(PaperSize.allCases) { Text($0.label).tag($0) }
        }
        .fixedSize()
    }

    @ViewBuilder private var scanButton: some View {
        if model.isScanning {
            HStack {
                ProgressView().controlSize(.small)
                Button("Abbrechen") { model.cancelScan() }
            }
        } else {
            HStack {
                if model.isConnecting { ProgressView().controlSize(.small) }
                Button {
                    model.startScan()
                } label: {
                    Label("Scannen", systemImage: "doc.viewfinder")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!model.canScan)
            }
        }
    }
}

struct PageCell: View {
    @EnvironmentObject var model: ScanModel
    let page: ScannedPage
    let number: Int

    var body: some View {
        VStack(spacing: 8) {
            Image(decorative: page.thumbnail, scale: 1)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(height: 230)
                .background(Color.white)
                .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                .onTapGesture(count: 2) { model.previewPage = page }
            HStack(spacing: 6) {
                Text("Seite \(number)").font(.callout)
                Spacer()
                Button { model.rotate(page, by: -1) } label: { Image(systemName: "rotate.left") }
                    .help("Nach links drehen")
                Button { model.rotate(page, by: 1) } label: { Image(systemName: "rotate.right") }
                    .help("Nach rechts drehen")
                Button { model.delete(page) } label: { Image(systemName: "trash") }
                    .help("Seite entfernen")
            }
            .buttonStyle(.borderless)
        }
        .contextMenu {
            Button("Vorschau") { model.previewPage = page }
            Divider()
            Button("Nach links drehen") { model.rotate(page, by: -1) }
            Button("Nach rechts drehen") { model.rotate(page, by: 1) }
            Button("Um 180° drehen") { model.rotate(page, by: 2) }
            Divider()
            Button("Nach vorne verschieben") { model.move(page, by: -1) }.disabled(number == 1)
            Button("Nach hinten verschieben") { model.move(page, by: 1) }.disabled(number == model.pages.count)
            Divider()
            Button("Entfernen", role: .destructive) { model.delete(page) }
        }
    }
}

struct PreviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    let page: ScannedPage
    @State private var image: CGImage?

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if let image {
                    ScrollView([.horizontal, .vertical]) {
                        Image(decorative: image, scale: 1).resizable().scaledToFit()
                            .frame(maxWidth: 900, maxHeight: 1100)
                    }
                } else {
                    ProgressView()
                }
            }
            .frame(minWidth: 600, idealWidth: 800, minHeight: 700, idealHeight: 1000)
            Divider()
            HStack {
                Text("\(page.image.width) × \(page.image.height) Pixel, \(page.dpi) dpi").foregroundStyle(.secondary)
                Spacer()
                Button("Schließen") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        .task {
            let page = page
            image = await Task.detached { page.rotatedImage }.value
        }
    }
}
