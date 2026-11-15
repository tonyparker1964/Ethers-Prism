import SwiftUI
import AVKit
import EthersPrismCore

/// Script Lab: scripts on the left, the editor and console in the middle, the result on the right.
struct ScriptLabPage: View {
    @EnvironmentObject var lab: ScriptLabModel
    @EnvironmentObject var auto: AutoImportController

    var body: some View {
        HStack(spacing: 12) {
            ScriptList()
                .frame(width: 190)
                .prismPanel(padding: 8)
            VStack(spacing: 10) {
                ScriptToolbar()
                CodeEditor(text: $lab.code, errorLine: lab.errorLine, jumpTo: lab.jumpTo)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(PrismTheme.border))
                ScriptConsole()
                    .frame(height: 130)
            }
            .frame(minWidth: 360)
            ScriptResult()
                .frame(minWidth: 280, idealWidth: 400, maxWidth: 440)
                .prismPanel(padding: 10)
        }
        .padding(12)
        .sheet(isPresented: $lab.showReference) { ScriptReference().environmentObject(lab) }
    }
}

struct ScriptList: View {
    @EnvironmentObject var lab: ScriptLabModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Script Lab").font(.headline)
                Spacer()
                Button { lab.newScript() } label: { Image(systemName: "plus") }
                    .buttonStyle(PrismToolButtonStyle()).help("New script")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    Text("TEMPLATES").font(.caption2.weight(.bold)).foregroundStyle(PrismTheme.secondaryText).padding(.top, 4)
                    ForEach(ScriptLab.templates, id: \.name) { t in
                        row(t.name, symbol: "doc.text", active: lab.fileURL == nil && lab.name == t.name) { lab.open(template: t) }
                    }
                    Text("MY SCRIPTS").font(.caption2.weight(.bold)).foregroundStyle(PrismTheme.secondaryText).padding(.top, 10)
                    if lab.scripts.isEmpty {
                        Text("Save a script (⌘S) and it appears here.").font(.caption).foregroundStyle(PrismTheme.secondaryText)
                    }
                    ForEach(lab.scripts, id: \.self) { url in
                        row(url.deletingPathExtension().lastPathComponent, symbol: "chevron.left.forwardslash.chevron.right",
                            active: lab.fileURL == url) { lab.open(url) }
                            .contextMenu {
                                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                                Button("Move to Trash", role: .destructive) { lab.delete(url) }
                            }
                    }
                }
            }
            Divider()
            Button { lab.showReference = true } label: { Label("Brush & Colour Reference", systemImage: "book") }
                .buttonStyle(PrismToolButtonStyle())
        }
    }

    private func row(_ title: String, symbol: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol).frame(width: 14).foregroundStyle(active ? PrismTheme.teal : PrismTheme.secondaryText)
                Text(title).font(.system(size: 12)).lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 6).padding(.vertical, 5)
            .background(active ? PrismTheme.selection : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct ScriptToolbar: View {
    @EnvironmentObject var lab: ScriptLabModel
    @EnvironmentObject var auto: AutoImportController

    var body: some View {
        HStack(spacing: 6) {
            TextField("Script name", text: $lab.name)
                .textFieldStyle(.roundedBorder).frame(width: 180)
            if lab.dirty { Circle().fill(PrismTheme.teal).frame(width: 6, height: 6).help("Not saved") }
            Button { lab.save() } label: { Image(systemName: "square.and.arrow.down") }
                .keyboardShortcut("s", modifiers: .command).help("Save (⌘S)")
            Menu {
                Button("None") { lab.choosePicture(nil) }
                Divider()
                ForEach(auto.items.prefix(40)) { it in
                    Button(it.fileName) { lab.choosePicture(it) }
                }
            } label: {
                Label(lab.picture?.fileName ?? "Picture: none", systemImage: "photo")
                    .lineLimit(1)
            }
            .menuStyle(.borderlessButton).fixedSize()
            .help("The picture your script paints from (IMAGE)")
            snippetsMenu
            Spacer()
            Button { lab.copyForClaude() } label: { Image(systemName: "sparkles") }
                .help("Copy for Claude: the script plus the brush library reference")
            Button { lab.pasteFromClaude() } label: { Image(systemName: "doc.on.clipboard") }
                .help("Paste a script from Claude")
            Button { lab.openInBlender() } label: { Image(systemName: "cube") }
                .help("Open in Blender to keep drawing by hand")
            if lab.isRunning {
                ProgressView().controlSize(.small)
                Button("Stop") { lab.stop() }.keyboardShortcut(".", modifiers: .command)
            } else {
                Button { lab.run(video: false) } label: { Label("Run", systemImage: "play.fill") }
                    .keyboardShortcut(.return, modifiers: .command).help("Run: the finished frame (⌘↩)")
                Button { lab.run(video: true) } label: { Label("Video", systemImage: "film") }
                    .keyboardShortcut(.return, modifiers: [.command, .shift]).help("Render the animation (⇧⌘↩)")
            }
        }
        .buttonStyle(PrismToolButtonStyle())
    }

    private var snippetsMenu: some View {
        Menu {
            Section("Brushes") {
                ForEach(["ink", "pen", "marker", "pencil", "charcoal", "chalk", "bristle", "oil", "dry", "wash",
                         "watercolor", "airbrush", "dots", "squares"], id: \.self) { k in
                    Button(k.capitalized) {
                        lab.insert("\(k) = brush(\"\(k.capitalized)\", kind=\"\(k)\", color=\"#1b2a4a\", size=\(["wash", "watercolor", "airbrush"].contains(k) ? 40 : 12))")
                    }
                }
            }
            Section("Shapes") {
                Button("Line") { lab.insert("line(b, (200, 200), (800, 600))") }
                Button("Circle") { lab.insert("circle(b, (960, 540), 200)") }
                Button("Filled circle") { lab.insert("circle(b, (960, 540), 200, fill=True)") }
                Button("Rectangle") { lab.insert("rect(b, 300, 200, 600, 400)") }
                Button("Smooth stroke through points") { lab.insert("stroke(b, [(200, 800), (600, 300), (1100, 700), (1600, 250)], smooth=True)") }
            }
            Section("Colour") {
                Button("Mix two colours") { lab.insert("c = mix(\"#e8b53a\", \"#1b2a4a\", 0.5)") }
                Button("Gradient") { lab.insert("c = gradient([\"#1b2a4a\", \"#3fa37a\", \"#e8b53a\"], 0.4)") }
                Button("Colours from the picture") { lab.insert("colours = picture_palette(6)") }
            }
            Section("Picture") {
                Button("Paint the picture") { lab.insert("paint([brush(\"Wash\", kind=\"watercolor\", size=70), brush(\"Bristle\", kind=\"bristle\", size=24), brush(\"Detail\", kind=\"dry\", size=9)])") }
                Button("Ink lines") { lab.insert("ink(brush(\"Ink\", kind=\"ink\", color=\"#141414\", size=3))") }
            }
            Section("Motion & effects") {
                Button("Draw on") { lab.insert("draw_on()") }
                Button("Line boil") { lab.insert("boil(0.8)") }
                Button("Glow") { lab.insert("glow(color=\"#ffcc66\", radius=50)") }
                Button("Shadow") { lab.insert("shadow()") }
                Button("New layer") { lab.insert("layer(\"Details\")") }
            }
        } label: { Label("Insert", systemImage: "text.badge.plus") }
        .menuStyle(.borderlessButton).fixedSize()
    }
}

struct ScriptConsole: View {
    @EnvironmentObject var lab: ScriptLabModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if lab.console.isEmpty {
                        Text("Run a script with ⌘↩. Messages and errors appear here.")
                            .foregroundStyle(PrismTheme.secondaryText)
                    }
                    ForEach(lab.console) { l in
                        Text(l.text)
                            .foregroundStyle(l.isError ? Color(hex: 0xFF7A8A) : PrismTheme.text)
                            .textSelection(.enabled)
                            .id(l.id)
                    }
                }
                .font(.system(size: 11, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
            .onChange(of: lab.console.count) { _, _ in
                if let last = lab.console.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
        .background(Color(hex: 0x0B1219), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(PrismTheme.border))
    }
}

struct ScriptResult: View {
    @EnvironmentObject var lab: ScriptLabModel
    @State private var player: AVPlayer?

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                Color.black.opacity(0.35)
                if let movie = lab.movie {
                    VideoPlayer(player: player)
                        .onAppear { setPlayer(movie) }
                        .onChange(of: movie) { _, m in setPlayer(m) }
                } else if let still = lab.still, let img = NSImage(contentsOf: still) {
                    Image(nsImage: img).resizable().scaledToFit()
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "paintbrush.pointed").font(.system(size: 34)).foregroundStyle(PrismTheme.teal)
                        Text("Your drawing appears here").foregroundStyle(PrismTheme.secondaryText)
                    }
                }
                if let r = lab.running {
                    VStack(spacing: 8) {
                        ProgressView()
                        Text(r).font(.caption)
                    }
                    .prismPanel(padding: 14, glow: true)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            HStack {
                Button("Add to Library") { lab.addResultToLibrary() }.disabled(lab.still == nil)
                Button("Show in Finder") { lab.showResult() }.disabled(lab.still == nil && lab.movie == nil)
            }
            .buttonStyle(PrismToolButtonStyle())
            if let p = lab.picture, let thumb = lab.autoImport.thumbnail(for: p) {
                HStack {
                    Image(nsImage: thumb).resizable().scaledToFill().frame(width: 54, height: 40).clipShape(RoundedRectangle(cornerRadius: 5))
                    VStack(alignment: .leading) {
                        Text("IMAGE").font(.caption2.weight(.bold)).foregroundStyle(PrismTheme.teal)
                        Text(p.fileName).font(.caption).lineLimit(1)
                    }
                    Spacer()
                }
            }
        }
    }

    private func setPlayer(_ url: URL) {
        let p = AVPlayer(url: url)
        player = p
        p.play()
    }
}

struct ScriptReference: View {
    @EnvironmentObject var lab: ScriptLabModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Brush & Colour Reference").font(.title3.bold())
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            ScrollView {
                Text(ScriptLab.apiReference)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("Brushes are Grease Pencil materials with a brush texture (bristle, wash, chalk …) and a pressure profile. Strokes are written as data, so everything stays editable in Blender.")
                .font(.caption).foregroundStyle(PrismTheme.secondaryText)
        }
        .padding(18)
        .frame(width: 760, height: 520)
    }
}
