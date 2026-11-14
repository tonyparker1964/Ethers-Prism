import SwiftUI
import AppKit
import EthersPrismCore

/// Edit / Realism / Upscale Studio: tool bar, canvas with before/after, inspector, and the library strip.
struct StudioWorkspace: View {
    @EnvironmentObject var studio: StudioModel

    var body: some View {
        VStack(spacing: 0) {
            StudioToolbar()
            HStack(spacing: 12) {
                StudioCanvas()
                    .prismPanel(padding: 0)
                if !studio.focusMode {
                    StudioInspector()
                        .frame(width: 300)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .padding(.horizontal, 12)
            if !studio.focusMode {
                StudioStrip()
                    .frame(height: 92)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                Spacer().frame(height: 12)
            }
        }
        .animation(PrismTheme.spring, value: studio.focusMode)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            loadURLs(providers) { studio.importAndOpen($0) }
            return true
        }
    }
}

/// Collects file URLs from dropped items, then calls back on the main thread.
func loadURLs(_ providers: [NSItemProvider], then: @escaping @MainActor ([URL]) -> Void) {
    final class Box: @unchecked Sendable {
        var urls: [URL] = []
        let lock = NSLock()
        func add(_ u: URL) { lock.lock(); urls.append(u); lock.unlock() }
    }
    let group = DispatchGroup()
    let box = Box()
    for p in providers where p.canLoadObject(ofClass: URL.self) {
        group.enter()
        _ = p.loadObject(ofClass: URL.self) { url, _ in
            if let url { box.add(url) }
            group.leave()
        }
    }
    group.notify(queue: .main) { MainActor.assumeIsolated { then(box.urls) } }
}

// MARK: - Tool bar

struct StudioToolbar: View {
    @EnvironmentObject var studio: StudioModel

    var body: some View {
        HStack(spacing: 6) {
            Button { studio.paste() } label: { Image(systemName: "doc.on.clipboard") }
                .buttonStyle(PrismToolButtonStyle())
                .keyboardShortcut("v", modifiers: .command)
                .help("Paste an image from ChatGPT (⌘V)")
            Group {
                tool("crop", "Crop", .crop)
                tool("hand.raised", "Pan", .pan)
                Button { studio.rotate(-1) } label: { Image(systemName: "rotate.left") }
                    .help("Rotate left")
                Button { studio.rotate(1) } label: { Image(systemName: "rotate.right") }
                    .help("Rotate right")
                Button { studio.showBefore.toggle() } label: { Image(systemName: "rectangle.split.2x1") }
                    .buttonStyle(PrismToolButtonStyle(active: studio.showBefore))
                    .help("Before / After comparison")
            }
            .buttonStyle(PrismToolButtonStyle())
            .disabled(!studio.hasImage)

            if studio.tool == .crop {
                Button("Apply Crop") { studio.applyCrop() }.buttonStyle(PrismToolButtonStyle(active: true))
                Button("Clear") { studio.clearCrop() }.buttonStyle(PrismToolButtonStyle())
                Button("Cancel") { studio.tool = .none }.buttonStyle(PrismToolButtonStyle())
            }

            Spacer()

            if studio.rendering { ProgressView().controlSize(.small).padding(.trailing, 4) }

            Group {
                Button { studio.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                    .keyboardShortcut("z", modifiers: .command).disabled(!studio.canUndo).help("Undo (⌘Z)")
                Button { studio.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                    .keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!studio.canRedo).help("Redo (⇧⌘Z)")
                historyMenu
                Divider().frame(height: 18)
                Button { zoomBy(1 / 1.25) } label: { Image(systemName: "minus.magnifyingglass") }
                    .keyboardShortcut("-", modifiers: .command).help("Zoom out (⌘−)")
                Button { zoomBy(1.25) } label: { Image(systemName: "plus.magnifyingglass") }
                    .keyboardShortcut("=", modifiers: .command).help("Zoom in (⌘+)")
                Button("Fit") { withAnimation(PrismTheme.spring) { studio.zoom = nil; studio.pan = .zero } }
                    .keyboardShortcut("0", modifiers: .command).help("Fit to window (⌘0)")
                Button("100%") { withAnimation(PrismTheme.spring) { studio.zoom = 1; studio.pan = .zero } }
                    .keyboardShortcut("1", modifiers: .command).help("Actual pixels (⌘1)")
                Button { toggleFullscreen() } label: {
                    Image(systemName: studio.focusMode ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                }
                .keyboardShortcut("f", modifiers: [.command, .control]).help("Fullscreen preview (⌃⌘F)")
            }
            .buttonStyle(PrismToolButtonStyle())
            .disabled(!studio.hasImage)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func tool(_ symbol: String, _ help: String, _ t: StudioTool) -> some View {
        Button { studio.tool = studio.tool == t ? .none : t } label: { Image(systemName: symbol) }
            .buttonStyle(PrismToolButtonStyle(active: studio.tool == t))
            .help(help)
    }

    private var historyMenu: some View {
        Menu {
            if let history = studio.project?.history {
                ForEach(history.reversed()) { v in
                    Button("\(v.label) — \(v.date.formatted(date: .omitted, time: .shortened))") { studio.restore(v) }
                }
            }
        } label: { Image(systemName: "clock.arrow.circlepath") }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Project history")
    }

    private func zoomBy(_ f: CGFloat) {
        withAnimation(PrismTheme.spring) { studio.zoom = min(max((studio.zoom ?? studio.lastFitScale) * f, 0.05), 16) }
    }

    private func toggleFullscreen() {
        studio.focusMode.toggle()
        if let w = NSApp.keyWindow, w.styleMask.contains(.fullScreen) != studio.focusMode { w.toggleFullScreen(nil) }
    }
}

extension StudioModel {
    /// Set by the canvas so Zoom in/out start from the fitted size.
    var lastFitScale: CGFloat {
        get { CGFloat(UserDefaults.standard.double(forKey: "studioFitScale").nonZero ?? 1) }
        set { UserDefaults.standard.set(Double(newValue), forKey: "studioFitScale") }
    }
}

private extension Double { var nonZero: Double? { self == 0 ? nil : self } }

// MARK: - Canvas

struct StudioCanvas: View {
    @EnvironmentObject var studio: StudioModel
    @State private var dragStart: CGSize?
    @State private var cropStart: CGPoint?
    @State private var zoomStart: CGFloat?

    var body: some View {
        GeometryReader { geo in
            let crop = studio.tool == .crop
            let size = crop ? (studio.uncropped?.size ?? studio.imageSize) : studio.imageSize
            let fit = size.width > 0 ? min((geo.size.width - 40) / size.width, (geo.size.height - 40) / size.height) : 1
            let scale = crop ? fit : (studio.zoom ?? fit)
            let frame = CGSize(width: size.width * scale, height: size.height * scale)
            ZStack {
                PrismTheme.background.opacity(0.6)
                if let after = studio.after {
                    ZStack(alignment: .topLeading) {
                        if crop, let full = studio.uncropped {
                            Image(nsImage: full).resizable().interpolation(.high)
                            cropOverlay(frame)
                        } else {
                            Image(nsImage: after).resizable().interpolation(.high)
                            if studio.showBefore, let before = studio.before {
                                Image(nsImage: before).resizable().interpolation(.high)
                                    .mask(alignment: .leading) { Rectangle().frame(width: frame.width * studio.divider) }
                                comparisonDivider(frame)
                            }
                        }
                    }
                    .frame(width: frame.width, height: frame.height)
                    .offset(crop ? .zero : studio.pan)
                    .shadow(color: .black.opacity(0.5), radius: 18)
                } else {
                    emptyState
                }
                if let job = studio.job { jobOverlay(job) }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
            .contentShape(Rectangle())
            .gesture(panGesture, including: studio.tool == .pan && !crop ? .all : .subviews)
            .simultaneousGesture(magnify(fit))
            .onAppear { studio.lastFitScale = fit }
            .onChange(of: fit) { _, f in studio.lastFitScale = f }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.badge.plus").font(.system(size: 44)).foregroundStyle(PrismTheme.teal)
            Text("Open a picture to edit").font(.title3.weight(.semibold)).foregroundStyle(PrismTheme.text)
            Text("Paste with ⌘V, drop an image here, choose one below, or pick from the Library.")
                .font(.callout).foregroundStyle(PrismTheme.secondaryText)
            HStack {
                Button("Paste (⌘V)") { studio.paste() }.buttonStyle(PrismToolButtonStyle())
                Button("Choose Images…") { studio.chooseFiles() }.buttonStyle(PrismToolButtonStyle())
                Button("Library") { studio.section = .library }.buttonStyle(PrismToolButtonStyle())
            }
        }
    }

    private func comparisonDivider(_ frame: CGSize) -> some View {
        let x = frame.width * studio.divider
        return ZStack(alignment: .topLeading) {
            Rectangle().fill(Color.white.opacity(0.9)).frame(width: 2, height: frame.height)
                .shadow(color: PrismTheme.teal.opacity(0.8), radius: 4)
                .offset(x: x - 1)
            Circle().strokeBorder(Color.white, lineWidth: 2)
                .background(Circle().fill(Color.black.opacity(0.35)))
                .overlay(Image(systemName: "arrow.left.and.right").font(.system(size: 10, weight: .bold)).foregroundStyle(.white))
                .frame(width: 30, height: 30)
                .offset(x: x - 15, y: frame.height / 2 - 15)
                .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                    studio.divider = min(max(g.location.x / frame.width, 0), 1)
                })
            label("Before").offset(x: 10, y: frame.height - 32)
            label("After").offset(x: frame.width - 58, y: frame.height - 32)
        }
        .frame(width: frame.width, height: frame.height, alignment: .topLeading)
        // The whole picture is a drag target for the divider too (unless panning).
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 2).onChanged { g in
            studio.divider = min(max(g.location.x / frame.width, 0), 1)
        }, including: studio.tool == .pan ? .none : .all)
    }

    private func label(_ text: String) -> some View {
        Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 6))
    }

    private func cropOverlay(_ frame: CGSize) -> some View {
        let c = studio.pendingCrop
        let rect = CGRect(x: c.x * frame.width, y: c.y * frame.height, width: c.width * frame.width, height: c.height * frame.height)
        return ZStack(alignment: .topLeading) {
            Path { p in
                p.addRect(CGRect(origin: .zero, size: frame))
                p.addRect(rect)
            }
            .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
            Rectangle().strokeBorder(PrismTheme.teal, lineWidth: 2)
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
                .shadow(color: PrismTheme.teal.opacity(0.6), radius: 6)
        }
        .frame(width: frame.width, height: frame.height, alignment: .topLeading)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 3).onChanged { g in
            let a = cropStart ?? g.startLocation
            cropStart = a
            let x0 = min(a.x, g.location.x), y0 = min(a.y, g.location.y)
            studio.pendingCrop = UnitRect(x: x0 / frame.width, y: y0 / frame.height,
                                          width: abs(g.location.x - a.x) / frame.width,
                                          height: abs(g.location.y - a.y) / frame.height).clamped
        }.onEnded { _ in cropStart = nil })
    }

    private var panGesture: some Gesture {
        DragGesture().onChanged { g in
            let start = dragStart ?? studio.pan
            dragStart = start
            studio.pan = CGSize(width: start.width + g.translation.width, height: start.height + g.translation.height)
        }.onEnded { _ in dragStart = nil }
    }

    private func magnify(_ fit: CGFloat) -> some Gesture {
        MagnifyGesture().onChanged { g in
            let start = zoomStart ?? (studio.zoom ?? fit)
            zoomStart = start
            studio.zoom = min(max(start * g.magnification, 0.05), 16)
        }.onEnded { _ in zoomStart = nil }
    }

    private func jobOverlay(_ job: String) -> some View {
        VStack(spacing: 10) {
            Text(job).font(.callout.weight(.medium)).foregroundStyle(PrismTheme.text)
            ProgressView(value: studio.progress).tint(PrismTheme.teal).frame(width: 260)
            Button("Cancel") { studio.cancelJob() }.buttonStyle(PrismToolButtonStyle())
        }
        .prismPanel(padding: 18, glow: true)
    }
}

// MARK: - Inspector

struct StudioInspector: View {
    @EnvironmentObject var studio: StudioModel
    @Namespace private var tabs

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 4) {
                ForEach(StudioTab.allCases) { t in
                    Button {
                        withAnimation(PrismTheme.spring) { studio.tab = t }
                    } label: {
                        Text(t.title).font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(studio.tab == t ? Color(hex: 0x04161A) : PrismTheme.secondaryText)
                            .frame(maxWidth: .infinity).padding(.vertical, 6)
                            .background {
                                if studio.tab == t {
                                    RoundedRectangle(cornerRadius: 7).fill(PrismTheme.accentGradient)
                                        .matchedGeometryEffect(id: "tab", in: tabs)
                                }
                            }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(3)
            .background(PrismTheme.background, in: RoundedRectangle(cornerRadius: 9))

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    switch studio.tab {
                    case .adjust: sliders(.adjust)
                    case .realism: sliders(.realism)
                    case .enhance: enhancePanel
                    }
                }
                .id(studio.tab)
                .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
            .scrollIndicators(.never)

            HStack {
                Button("Reset \(studio.tab.title)") { studio.reset(studio.tab) }
                Spacer()
                Button("Reset All") { studio.resetAll() }
            }
            .buttonStyle(PrismToolButtonStyle())
            .disabled(!studio.hasImage)
        }
        .prismPanel(padding: 12)
        .disabled(!studio.hasImage)
        .opacity(studio.hasImage ? 1 : 0.6)
    }

    private func sliders(_ tab: StudioTab) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            PrismHeading(title: tab == .adjust ? "Image Adjustments" : "Realism Studio")
            ForEach(StudioControls.controls(for: tab)) { c in
                PrismSlider(control: c, value: studio.binding(c.id)) { studio.commit(c.label) }
            }
        }
    }

    private var enhancePanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            PrismHeading(title: "Enhancement Engine")
            HStack(spacing: 6) {
                engineButton("Local (Mac)", "cpu", selected: !studio.aiEngine) { studio.aiEngine = false }
                engineButton("AI (Optional)", "sparkles", selected: studio.aiEngine) {
                    studio.message = "AI processing isn't set up. Everything runs on this Mac."
                }
                .opacity(0.5)
                .help("Not configured: PRISM enhances locally on your Mac's GPU.")
            }
            Text("Local Mac processing: Core Image on the GPU. Nothing is uploaded.")
                .font(.caption).foregroundStyle(PrismTheme.secondaryText)

            ForEach(StudioControls.enhance) { c in
                PrismSlider(control: c, value: studio.binding(c.id)) { studio.commit(c.label) }
            }
            Text("These settings apply whenever the picture is made larger: Upscale, Enhance to 4K, and exports at 2×, 4× or 3840×2160.")
                .font(.caption).foregroundStyle(PrismTheme.secondaryText)

            HStack(spacing: 8) {
                Button("Upscale 2×") { studio.enhance(.scale(2), tag: "2x") }
                Button("Upscale 4×") { studio.enhance(.scale(4), tag: "4x") }
            }
            .buttonStyle(PrismToolButtonStyle())
            .disabled(studio.isBusy)

            Button {
                studio.enhance(.longEdge4K, tag: "4K")
            } label: {
                Label("Enhance to 4K", systemImage: "4k.tv")
            }
            .buttonStyle(PrismPrimaryButtonStyle())
            .disabled(studio.isBusy || !studio.hasImage)
            if studio.hasImage {
                let s = StudioRenderer.pixelSize(source: studio.sourceSize, edit: studio.edit, size: .longEdge4K)
                Text("Output \(Int(s.width))×\(Int(s.height)), saved to the Library as a new version.")
                    .font(.caption).foregroundStyle(PrismTheme.secondaryText)
            }
        }
    }

    private func engineButton(_ title: String, _ symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol).font(.system(size: 11, weight: .medium))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(PrismToolButtonStyle(active: selected))
    }
}

// MARK: - Bottom strip

struct StudioStrip: View {
    @EnvironmentObject var studio: StudioModel
    @EnvironmentObject var auto: AutoImportController

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 10) {
                    ForEach(auto.items) { item in
                        StripThumb(item: item, selected: studio.item?.id == item.id)
                            .id(item.id)
                            .onTapGesture { withAnimation(PrismTheme.spring) { studio.open(item) } }
                    }
                    Button { studio.chooseFiles() } label: {
                        Image(systemName: "plus").font(.title3).frame(width: 64, height: 64)
                    }
                    .buttonStyle(PrismToolButtonStyle())
                    .help("Add images")
                }
                .padding(.horizontal, 6)
            }
            .scrollIndicators(.never)
            .onChange(of: studio.item?.id) { _, id in
                if let id { withAnimation(PrismTheme.spring) { proxy.scrollTo(id, anchor: .center) } }
            }
        }
        .prismPanel(padding: 8)
    }
}

struct StripThumb: View {
    @EnvironmentObject var auto: AutoImportController
    let item: ImportedImage
    let selected: Bool

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let img = auto.thumbnail(for: item) {
                Image(nsImage: img).resizable().scaledToFill()
            } else {
                PrismTheme.panel
            }
            if StudioModel.isEdited(item) {
                Text("Edited").font(.system(size: 9, weight: .bold)).foregroundStyle(Color(hex: 0x04161A))
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(PrismTheme.teal, in: RoundedRectangle(cornerRadius: 3))
                    .padding(4)
            }
        }
        .frame(width: 96, height: 68)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(selected ? PrismTheme.teal : PrismTheme.border, lineWidth: selected ? 2.5 : 1))
        .shadow(color: selected ? PrismTheme.teal.opacity(0.55) : .clear, radius: 8)
        .help("\(item.fileName)\(StudioModel.isEdited(item) ? " (edited version)" : " (original)")")
    }
}
