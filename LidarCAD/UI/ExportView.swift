import SwiftUI

struct ExportView: View {
    @ObservedObject var scanner: ScanSession
    @StateObject private var model = ExportModel()
    @State private var showShareSheet = false

    var body: some View {
        NavigationStack {
            Form {
                summarySection
                targetSection
                densitySection
                if ScanSession.hasClassification { surfacesSection }
                alignmentSection
                sectionsSection
                formatsSection
                actionSection
            }
            .navigationTitle("Dışa aktar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Yeni tarama") { scanner.newScan() }
                }
            }
            .onAppear { model.refreshPreview(mesh: scanner.capturedMesh, force: true) }
            .onChange(of: model.options) { _, _ in
                model.refreshPreview(mesh: scanner.capturedMesh)
            }
            .sheet(isPresented: $showShareSheet) {
                ShareSheet(urls: model.exportedURLs)
            }
            .alert("Dışa aktarılamadı",
                   isPresented: Binding(get: { model.errorMessage != nil },
                                        set: { if !$0 { model.errorMessage = nil } })) {
                Button("Tamam", role: .cancel) { model.errorMessage = nil }
            } message: {
                Text(model.errorMessage ?? "")
            }
        }
    }

    // MARK: - Özet

    private var summarySection: some View {
        Section("Tarama") {
            row("Üçgen", grouped(scanner.capturedMesh.triangleCount))
            row("Vertex", grouped(scanner.capturedMesh.vertexCount))
            if !scanner.capturedCloud.isEmpty {
                row("Nokta bulutu", grouped(scanner.capturedCloud.count))
            }
            if let bounds = scanner.capturedMesh.bounds() {
                let s = bounds.size
                row("Kapladığı hacim",
                    "\(fixedString(s.x, decimals: 2)) × \(fixedString(s.z, decimals: 2)) × \(fixedString(s.y, decimals: 2)) m")
            }
        }
    }

    // MARK: - Hedef

    private var targetSection: some View {
        Section {
            Picker("Birim", selection: $model.options.unit) {
                ForEach(LengthUnit.allCases) { Text($0.label).tag($0) }
            }
            Picker("Yukarı eksen", selection: $model.options.upAxis) {
                ForEach(UpAxis.allCases) { Text($0.label).tag($0) }
            }
        } header: {
            Text("Hedef")
        } footer: {
            Text("Fusion 360 için mm + Z yukarı. STL birimsiz bir formattır ve daima mm olarak okunur.")
        }
    }

    // MARK: - Yoğunluk

    private var densitySection: some View {
        Section {
            Picker("Sadeleştirme", selection: $model.options.detail) {
                ForEach(DetailLevel.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.menu)

            HStack {
                Text("Çıkacak üçgen")
                Spacer()
                if model.isPreviewing {
                    ProgressView().controlSize(.small)
                } else if let count = model.previewTriangles {
                    Text(grouped(count))
                        .monospacedDigit()
                        .foregroundStyle(count > 50_000 ? .orange : .secondary)
                } else {
                    Text("—").foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Yoğunluk")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.options.detail.hint)
                if let count = model.previewTriangles, count > 50_000 {
                    Text("50.000 üstünde Fusion'ın Convert Mesh komutu çalışmayabilir. Referans olarak kullanacaksanız sorun değil.")
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    // MARK: - Yüzeyler

    private var surfacesSection: some View {
        Section {
            ForEach(SurfaceClass.allCases) { surface in
                Toggle(surface.label, isOn: Binding(
                    get: { model.options.classes.contains(surface.rawValue) },
                    set: { isOn in
                        if isOn { model.options.classes.insert(surface.rawValue) }
                        else { model.options.classes.remove(surface.rawValue) }
                    }
                ))
            }
        } header: {
            Text("Yüzeyler")
        } footer: {
            Text("ARKit her üçgeni sınıflandırır. Sadece kabuğu istiyorsanız mobilyaları (masa, oturma) kapatın.")
        }
    }

    // MARK: - Hizalama

    private var alignmentSection: some View {
        Section {
            Toggle("Duvarları eksenlere oturt", isOn: $model.options.alignToWalls)
                .disabled(model.options.upAxis != .zUp)
            Toggle("Zemini Z=0'a taşı", isOn: $model.options.recenterToFloor)
        } header: {
            Text("Konumlandırma")
        } footer: {
            Text("ARKit'in dünya ekseni taramaya başladığınız yöne göre kurulur. Hizalama, baskın duvar yönünü bulup modeli döndürür — Fusion'da dik skeçler çizebilmek için.")
        }
    }

    // MARK: - Kesitler

    private var sectionsSection: some View {
        Section {
            ForEach(Array(model.options.sectionHeights.indices), id: \.self) { index in
                HStack {
                    Text("Zeminden \(fixedString(safeHeight(index), decimals: 2)) m")
                    Spacer()
                    Stepper("", value: heightBinding(index), in: 0.05...10, step: 0.05)
                        .labelsHidden()
                }
            }
            .onDelete { offsets in
                model.options.sectionHeights.remove(atOffsets: offsets)
            }

            Button {
                let next = (model.options.sectionHeights.max() ?? 0.7) + 0.5
                model.options.sectionHeights.append(min(next, 10))
            } label: {
                Label("Kesit ekle", systemImage: "plus")
            }
            .disabled(model.options.sectionHeights.count >= 8)
        } header: {
            Text("DXF kesitleri")
        } footer: {
            Text("Her yükseklik ayrı bir .dxf dosyası olur. Fusion'da Insert > Insert DXF ile skeç olarak açılır. Kapı/pencere için 1,0–1,2 m tipik bir plan yüksekliğidir.")
        }
    }

    private func safeHeight(_ index: Int) -> Float {
        guard model.options.sectionHeights.indices.contains(index) else { return 0 }
        return model.options.sectionHeights[index]
    }

    private func heightBinding(_ index: Int) -> Binding<Float> {
        Binding(
            get: { safeHeight(index) },
            set: { newValue in
                guard model.options.sectionHeights.indices.contains(index) else { return }
                model.options.sectionHeights[index] = newValue
            }
        )
    }

    // MARK: - Formatlar

    private var formatsSection: some View {
        Section("Dosya formatları") {
            ForEach(ExportFormat.allCases) { format in
                Toggle(isOn: Binding(
                    get: { model.options.formats.contains(format) },
                    set: { isOn in
                        if isOn { model.options.formats.insert(format) }
                        else { model.options.formats.remove(format) }
                    }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(format.label)
                        Text(format.hint)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(format == .plyCloud && scanner.capturedCloud.isEmpty)
            }
        }
    }

    // MARK: - Aksiyon

    private var actionSection: some View {
        Section {
            Button {
                model.export(mesh: scanner.capturedMesh, cloud: scanner.capturedCloud)
            } label: {
                HStack {
                    Spacer()
                    if model.isExporting {
                        ProgressView().controlSize(.small)
                        Text("Yazılıyor…").padding(.leading, 6)
                    } else {
                        Label("Dosyaları oluştur", systemImage: "arrow.down.doc")
                            .font(.headline)
                    }
                    Spacer()
                }
                .padding(.vertical, 4)
            }
            .disabled(model.isExporting
                      || model.options.formats.isEmpty
                      || scanner.capturedMesh.isEmpty)

            if !model.exportedURLs.isEmpty {
                ForEach(model.exportedURLs, id: \.self) { url in
                    HStack {
                        Image(systemName: "doc")
                            .foregroundStyle(.secondary)
                        Text(url.lastPathComponent)
                            .font(.footnote.monospaced())
                        Spacer()
                        Text(fileSize(url))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Button {
                    showShareSheet = true
                } label: {
                    Label("Paylaş / AirDrop", systemImage: "square.and.arrow.up")
                }
            }
        } footer: {
            if !model.exportedURLs.isEmpty {
                Text("Dosyalar uygulamanın Documents klasöründe. AirDrop ile Mac'e atabilir ya da Dosyalar uygulamasından \"Benim iPhone'umda > LidarCAD\" altından alabilirsiniz.")
            }
        }
    }

    private func fileSize(_ url: URL) -> String {
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).foregroundStyle(.secondary).monospacedDigit()
        }
    }
}
