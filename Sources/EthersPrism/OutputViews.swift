import SwiftUI
import WebKit
import EthersPrismCore

struct OutputColumn: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if let snap = model.current?.currentSnapshot {
                    Label(snap.quality == .render ? "Full render" : "Preview",
                          systemImage: snap.quality == .render ? "wand.and.stars" : "eye")
                        .font(.subheadline)
                    Text(snap.createdAt, style: .time)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Text("No output yet").foregroundStyle(.secondary)
                }
                if model.isGenerating { ProgressView().controlSize(.small) }
                Spacer()
                Menu {
                    ForEach(model.current?.axes ?? []) { a in
                        Button(a.name) { model.sweep(axisID: a.id) }
                    }
                } label: {
                    Label("Sweep", systemImage: "slider.horizontal.3")
                }
                .fixedSize()
                .help("See one dial from 0 to 100 side by side")
                .disabled(model.current?.axes.isEmpty ?? true)
                Button { model.showCompare = true } label: {
                    Label("Compare", systemImage: "rectangle.split.2x1")
                }
                .disabled((model.current?.snapshots.count ?? 0) < 2)
                Button { model.toggleChosen() } label: {
                    Image(systemName: model.current?.currentSnapshot?.chosen == true ? "star.fill" : "star")
                }
                .help("Mark this state as chosen")
                Button { model.copyResult() } label: { Image(systemName: "doc.on.doc") }
                    .help("Copy result")
                Button { model.export() } label: { Image(systemName: "square.and.arrow.up") }
                    .help("Export result with its authorship log")
            }
            .padding(10)
            Divider()
            if let snap = model.current?.currentSnapshot {
                OutputView(kind: model.adapter.outputKind, text: snap.output)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "dial.medium").font(.system(size: 40)).foregroundStyle(.tertiary)
                    Text("Don't ask for the thing. Build the instrument, then play it.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

struct OutputView: View {
    let kind: OutputKind
    let text: String

    var body: some View {
        switch kind {
        case .text:
            ScrollView {
                Text(Self.markdown(text))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
            }
        case .code:
            ScrollView([.vertical, .horizontal]) {
                Text(text)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .svg:
            SVGView(svg: text)
        case .storyboard:
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(Storyboard.parse(text)) { scene in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(scene.title).font(.headline)
                            Text(Self.markdown(scene.body)).textSelection(.enabled)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
                .padding(16)
            }
        }
    }

    static func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
    }
}

/// Renders SVG with WebKit. Only reloads when the SVG actually changes.
struct SVGView: NSViewRepresentable {
    let svg: String

    final class Coordinator {
        var lastSVG: String?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView()
        view.setValue(false, forKey: "drawsBackground")
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        guard context.coordinator.lastSVG != svg else { return }
        context.coordinator.lastSVG = svg
        let html = """
        <html><head><style>
        html,body{margin:0;height:100%;background:transparent;}
        body{display:flex;align-items:center;justify-content:center;}
        svg{max-width:96%;max-height:96%;width:auto;height:auto;}
        </style></head><body>\(svg)</body></html>
        """
        view.loadHTMLString(html, baseURL: nil)
    }
}
