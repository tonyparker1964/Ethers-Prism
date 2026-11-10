import SwiftUI
import EthersPrismCore

struct OutputColumn: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            VStack(spacing: 8) {
                if let issue = model.configurationIssue {
                    HStack {
                        Banner(style: .warning, text: issue)
                        SettingsLink { Text("Settings…") }
                    }
                } else if model.usingMock {
                    Banner(style: .info, text: "Using the Mock provider: results are test placeholders, not real generations. Switch providers in Settings.")
                }
                if case .failed(let message) = model.phase {
                    Banner(style: .error, text: message, actionTitle: "Retry") { model.retry() }
                }
                if model.adapter.capabilities.needsImageProvider, let p = model.imageProvider {
                    Text("\(p.name): \(p.previewCostNote)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)

            if let snap = model.current?.currentSnapshot {
                if let review = snap.output.review {
                    Banner(style: review.passed ? .info : .warning,
                           text: review.passed
                               ? "\(review.reviewer): meets the fixed requirements."
                               : "\(review.reviewer) flagged: " + review.issues.joined(separator: " · "))
                        .padding(.horizontal, 10)
                        .padding(.top, 6)
                }
                ResultDisplay(snapshot: snap, editable: model.adapter.capabilities.editable)
                    .id(snap.id)
            } else {
                VStack(spacing: 14) {
                    if AppIcon.image != nil {
                        AppLogo(size: 220).shadow(color: .purple.opacity(0.35), radius: 24)
                    } else {
                        Image(systemName: "dial.medium").font(.system(size: 40)).foregroundStyle(.tertiary)
                    }
                    Text("Don't ask for the thing. Build the instrument, then play it.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            if let snap = model.current?.currentSnapshot {
                Image(systemName: icon(for: snap.origin)).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(snap.origin.label)
                        Text("·")
                        Text(snap.createdAt, style: .time)
                    }
                    .font(.subheadline)
                    Text([snap.output.agent, snap.output.provider].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .lineLimit(1)
                .fixedSize()
                .help("Model: \(snap.output.model)")
            } else {
                Text("No result yet").foregroundStyle(.secondary)
            }
            if case .working(let what) = model.phase {
                ProgressView().controlSize(.small)
                Text(what).font(.caption).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                Button("Cancel") { model.cancelGeneration() }.controlSize(.small)
            }
            Spacer(minLength: 8)
            Menu {
                ForEach(model.current?.dials ?? []) { d in
                    Button(d.locked ? "\(d.name) (locked: unlock to sweep)" : d.name) { model.sweep(dialID: d.id) }
                        .disabled(d.locked)
                }
            } label: {
                Label("Sweep", systemImage: "slider.horizontal.3")
            }
            .fixedSize()
            .help("Five previews of one dial at 0, 25, 50, 75 and 100")
            .disabled(model.current?.dials.isEmpty ?? true)
            Button { model.showCompare = true } label: { Label("Compare", systemImage: "rectangle.split.2x1") }
                .labelStyle(.iconOnly)
                .help("Compare two states side by side")
                .disabled((model.current?.snapshots.count ?? 0) < 2)
            Button { model.toggleChosen() } label: {
                Image(systemName: model.current?.currentSnapshot?.chosen == true ? "star.fill" : "star")
            }
            .accessibilityLabel("Mark as chosen")
            .help("Mark this state as chosen")
            Button { model.copyResult() } label: { Image(systemName: "doc.on.doc") }
                .accessibilityLabel("Copy result")
                .help("Copy result")
            Button { model.export() } label: { Image(systemName: "square.and.arrow.up") }
                .accessibilityLabel("Export")
                .help("Export the result, session file and authorship log")
        }
        .padding(10)
    }
}

func icon(for origin: Origin) -> String {
    switch origin {
    case .preview: return "eye"
    case .render: return "wand.and.stars"
    case .manualEdit: return "pencil"
    case .sweep: return "slider.horizontal.3"
    case .imported: return "tray.and.arrow.down"
    }
}

struct HistoryColumn: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("History").font(.headline).padding(10)
            Divider()
            if let s = model.current {
                let rows = s.treeRows()
                if rows.isEmpty {
                    Text("Each preview, render, sweep pick and manual edit is kept here as a tree. Click any state to return to it, then change something to start a new branch.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(10)
                    Spacer()
                } else {
                    List(rows) { row in
                        Button { model.restore(row.id) } label: {
                            HStack(spacing: 6) {
                                if row.depth > 0 {
                                    Rectangle()
                                        .fill(Color.secondary.opacity(0.35))
                                        .frame(width: 2)
                                        .padding(.leading, CGFloat(row.depth - 1) * 10)
                                }
                                Thumbnail(output: row.snapshot.output, origin: row.snapshot.origin)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(s.summary(for: row.snapshot)).font(.callout).lineLimit(2)
                                    HStack(spacing: 4) {
                                        if row.snapshot.chosen { Image(systemName: "star.fill").foregroundStyle(.yellow) }
                                        Text(row.snapshot.origin.label)
                                        Text(row.snapshot.createdAt, style: .time)
                                    }
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(row.snapshot.origin.label): \(s.summary(for: row.snapshot))")
                        .listRowBackground(row.id == s.currentSnapshotID ? Color.accentColor.opacity(0.18) : Color.clear)
                    }
                }
            }
        }
    }
}

struct Thumbnail: View {
    @EnvironmentObject var model: AppModel
    let output: Output
    let origin: Origin

    var body: some View {
        if output.kind == .image, let url = model.assetURL(output), url.pathExtension != "svg",
           let img = NSImage(contentsOf: url) {
            Image(nsImage: img).resizable().scaledToFill()
                .frame(width: 30, height: 30)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        } else if output.kind == .video {
            Image(systemName: "film")
                .frame(width: 30, height: 30)
                .foregroundStyle(.secondary)
        } else {
            Image(systemName: icon(for: origin))
                .frame(width: 30, height: 30)
                .foregroundStyle(.secondary)
        }
    }
}
