import SwiftUI
import AppKit
import EthersPrismCore

/// Design Option C — Creative Studio: the PRISM sidebar and the section it shows.
/// Create holds every existing field and session, unchanged.
struct RootView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var studio: StudioModel

    var body: some View {
        HStack(spacing: 0) {
            if !studio.focusMode {
                PrismSidebar()
                    .frame(width: 208)
                    .transition(.move(edge: .leading).combined(with: .opacity))
                Rectangle().fill(PrismTheme.border).frame(width: 1)
            }
            page
                // Never let a wide page push the PRISM sidebar off the window.
                .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .id(studio.section == .create ? "create" : (studio.section.studioTab != nil ? "studio" : studio.section.rawValue))
                .transition(.opacity)
        }
        .animation(PrismTheme.spring, value: studio.section)
        .animation(PrismTheme.spring, value: studio.focusMode)
        .background(PrismTheme.background)
        .foregroundStyle(PrismTheme.text)
        .tint(PrismTheme.teal)
        .preferredColorScheme(.dark)
        .alert("Ethers Prism",
               isPresented: Binding(get: { studio.section != .create && model.alertMessage != nil },
                                    set: { if !$0 { model.alertMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(model.alertMessage ?? "") }
        .overlay(alignment: .bottom) { toast }
    }

    @ViewBuilder private var page: some View {
        switch studio.section {
        case .create: ContentView()
        case .importPaste: ImportPastePage()
        case .autoImport: PageFrame(title: "Auto-Import", subtitle: "Images you save from the ChatGPT app come into PRISM by themselves.") {
            AutoImportSettingsTab().scrollContentBackground(.hidden)
        }
        case .library: PageFrame(title: "Library", subtitle: "Every imported, pasted and edited picture.") {
            ImportLibrarySheet(embedded: true)
        }
        case .edit, .color, .realism, .upscale: StudioWorkspace()
        case .presets: PresetsPage()
        case .export: ExportPage()
        }
    }

    @ViewBuilder private var toast: some View {
        if let m = studio.message {
            Text(m).font(.callout).foregroundStyle(PrismTheme.text)
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(PrismTheme.panel, in: Capsule())
                .overlay(Capsule().strokeBorder(PrismTheme.teal.opacity(0.5)))
                .shadow(color: PrismTheme.teal.opacity(0.3), radius: 10)
                .padding(.bottom, 18)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task(id: m) {
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                    if studio.message == m { withAnimation { studio.message = nil } }
                }
        }
    }
}

struct PrismSidebar: View {
    @EnvironmentObject var studio: StudioModel
    @EnvironmentObject var auto: AutoImportController

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                AppLogo(size: 30)
                Text("PRISM").font(.system(size: 22, weight: .semibold, design: .rounded)).foregroundStyle(PrismTheme.text)
            }
            .padding(.horizontal, 10)
            .padding(.top, 6)
            .padding(.bottom, 14)

            ForEach(AppSection.allCases) { s in
                row(s)
            }
            Spacer()
            Text("Version \(AppVersion.number)").font(.caption2).foregroundStyle(PrismTheme.secondaryText.opacity(0.7))
                .padding(.horizontal, 12)
        }
        .padding(10)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(PrismTheme.sidebar)
    }

    private func row(_ s: AppSection) -> some View {
        let active = studio.section == s
        return Button {
            withAnimation(PrismTheme.spring) { studio.section = s }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: s.symbol).frame(width: 18)
                    .foregroundStyle(active ? PrismTheme.teal : PrismTheme.secondaryText)
                Text(s.title).font(.system(size: 13, weight: active ? .semibold : .regular))
                    .foregroundStyle(active ? PrismTheme.text : PrismTheme.text.opacity(0.85))
                Spacer()
                if s == .autoImport && auto.enabled {
                    Circle().fill(PrismTheme.cyan).frame(width: 7, height: 7)
                        .shadow(color: PrismTheme.cyan, radius: 4)
                        .help(auto.status)
                }
                if s == .library {
                    Text("\(auto.items.count)").font(.caption2).foregroundStyle(PrismTheme.secondaryText)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(active ? PrismTheme.selection : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(active ? PrismTheme.teal.opacity(0.45) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A page with a title, on the Creative Studio background.
struct PageFrame<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 24, weight: .semibold)).foregroundStyle(PrismTheme.text)
                Text(subtitle).font(.callout).foregroundStyle(PrismTheme.secondaryText)
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .prismPanel(padding: 6)
        }
        .padding(20)
    }
}

// MARK: - Import / Paste

struct ImportPastePage: View {
    @EnvironmentObject var studio: StudioModel
    @EnvironmentObject var auto: AutoImportController
    @State private var dropping = false

    var body: some View {
        PageFrame(title: "Import / Paste", subtitle: "Bring in images made with the ChatGPT app.") {
            VStack(spacing: 18) {
                VStack(spacing: 12) {
                    Image(systemName: "square.and.arrow.down.on.square").font(.system(size: 46)).foregroundStyle(PrismTheme.teal)
                    Text("Drop images here").font(.title3.weight(.semibold))
                    Text("In ChatGPT, right-click an image → Copy Image, then press ⌘V here. Or drag the image in, or choose files.")
                        .font(.callout).foregroundStyle(PrismTheme.secondaryText).multilineTextAlignment(.center)
                    HStack(spacing: 10) {
                        Button("Paste (⌘V)") { studio.paste() }
                            .keyboardShortcut("v", modifiers: .command)
                        Button("Choose Images…") { studio.chooseFiles() }
                            .keyboardShortcut("o", modifiers: [.command, .shift])
                        Button("Set Up Auto-Import") { studio.section = .autoImport }
                    }
                    .buttonStyle(PrismToolButtonStyle())
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 16).fill(dropping ? PrismTheme.selection : PrismTheme.background.opacity(0.5)))
                .overlay(RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(dropping ? PrismTheme.teal : PrismTheme.border, style: StrokeStyle(lineWidth: 2, dash: [8, 6])))
                .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
                    loadURLs(providers) { studio.importAndOpen($0) }
                    return true
                }

                if !auto.items.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Recent").font(.caption.weight(.semibold)).foregroundStyle(PrismTheme.secondaryText)
                        StudioStrip().frame(height: 92)
                    }
                }
            }
            .padding(14)
        }
    }
}

// MARK: - Presets

struct PresetsPage: View {
    @EnvironmentObject var studio: StudioModel
    @State private var newName = ""
    private let columns = [GridItem(.adaptive(minimum: 220), spacing: 12)]

    var body: some View {
        PageFrame(title: "Presets", subtitle: "Save and reuse your Adjust, Realism and Enhance settings.") {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        TextField("New preset name", text: $newName).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                        Button("Save Current Look") { studio.saveAsPreset(newName); newName = "" }
                            .buttonStyle(PrismToolButtonStyle(active: true))
                            .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty || !studio.hasImage)
                        Spacer()
                    }
                    if !studio.hasImage {
                        Text("Open a picture in Edit Studio to apply or save presets.").font(.callout).foregroundStyle(PrismTheme.secondaryText)
                    }
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(studio.presets) { p in card(p) }
                    }
                }
                .padding(14)
            }
        }
    }

    private func card(_ p: StudioPreset) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(p.name).font(.headline)
                Spacer()
                if p.builtIn { Text("Built-in").font(.caption2).foregroundStyle(PrismTheme.secondaryText) }
            }
            Text(p.values.keys.sorted().compactMap { StudioControls.byID[$0]?.label }.joined(separator: " · "))
                .font(.caption).foregroundStyle(PrismTheme.secondaryText).lineLimit(3)
            HStack {
                Button("Apply") { studio.apply(p); studio.section = .edit }
                    .buttonStyle(PrismToolButtonStyle(active: true))
                    .disabled(!studio.hasImage)
                if !p.builtIn {
                    Button("Delete", role: .destructive) { studio.delete(p) }.buttonStyle(PrismToolButtonStyle())
                }
            }
        }
        .prismPanel(padding: 12)
    }
}

// MARK: - Export

struct ExportPage: View {
    @EnvironmentObject var studio: StudioModel

    /// Darkens what Smart Reframe leaves out.
    @ViewBuilder private func reframeOverlay(_ size: CGSize) -> some View {
        if let aspect = studio.exportReframe.aspect {
            GeometryReader { geo in
                let c = StudioReframe.crop(size: size, aspect: aspect, focus: studio.focus)
                let rect = CGRect(x: c.x * geo.size.width, y: c.y * geo.size.height,
                                  width: c.width * geo.size.width, height: c.height * geo.size.height)
                ZStack(alignment: .topLeading) {
                    Path { p in p.addRect(CGRect(origin: .zero, size: geo.size)); p.addRect(rect) }
                        .fill(Color.black.opacity(0.6), style: FillStyle(eoFill: true))
                    Rectangle().strokeBorder(PrismTheme.teal, lineWidth: 2)
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                        .shadow(color: PrismTheme.teal.opacity(0.6), radius: 6)
                }
            }
        }
    }

    var body: some View {
        PageFrame(title: "Export", subtitle: "High-quality output in PNG, JPEG, TIFF, HEIC or WebP.") {
            HStack(alignment: .top, spacing: 18) {
                preview
                Form {
                    Picker("Format", selection: $studio.exportFormat) {
                        ForEach(StudioFormat.writable) { Text($0.label).tag($0) }
                    }
                    Picker("Smart Reframe", selection: $studio.exportReframe) {
                        ForEach(StudioReframe.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    if studio.exportReframe != .original {
                        Text("Apple Vision finds the subject on this Mac and keeps it in the \(studio.exportReframe.label) frame.")
                            .font(.caption).foregroundStyle(PrismTheme.secondaryText)
                    }
                    Picker("Size", selection: $studio.exportSize) {
                        ForEach(ExportSizeChoice.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    if studio.exportSize == .custom {
                        TextField("Width (px)", value: $studio.customWidth, format: .number)
                    }
                    if studio.exportFormat.hasQuality {
                        LabeledContent("Quality") {
                            HStack {
                                Slider(value: $studio.quality, in: 0.3...1).tint(PrismTheme.teal)
                                Text("\(Int(studio.quality * 100))%").monospacedDigit().frame(width: 44)
                            }
                        }
                    }
                    Toggle("Preserve transparency", isOn: $studio.keepTransparency)
                        .disabled(!studio.exportFormat.keepsTransparency)
                    if studio.hasImage {
                        let s = studio.exportPixelSize
                        LabeledContent("Output", value: "\(Int(s.width)) × \(Int(s.height)) px")
                    }
                    Text("Sizes above the original use the Enhance settings (detail recovery, noise reduction, edge refinement, texture preservation). Processing runs on this Mac.")
                        .font(.caption).foregroundStyle(PrismTheme.secondaryText)
                    Button("Export…") { studio.export() }
                        .buttonStyle(PrismPrimaryButtonStyle())
                        .keyboardShortcut("e", modifiers: [.command, .option])
                        .disabled(!studio.hasImage || studio.isBusy)
                    if let job = studio.job {
                        HStack {
                            ProgressView(value: studio.progress).tint(PrismTheme.teal)
                            Button("Cancel") { studio.cancelJob() }
                        }
                        Text(job).font(.caption).foregroundStyle(PrismTheme.secondaryText)
                    }
                }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
                .frame(width: 360)
            }
            .padding(14)
        }
    }

    @ViewBuilder private var preview: some View {
        if let img = studio.after {
            Image(nsImage: img).resizable().scaledToFit()
                .overlay { reframeOverlay(img.size) }
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .animation(PrismTheme.spring, value: studio.exportReframe)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "photo").font(.largeTitle).foregroundStyle(PrismTheme.secondaryText)
                Text("Open a picture in Edit Studio first.").foregroundStyle(PrismTheme.secondaryText)
                Button("Go to Library") { studio.section = .library }.buttonStyle(PrismToolButtonStyle())
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
