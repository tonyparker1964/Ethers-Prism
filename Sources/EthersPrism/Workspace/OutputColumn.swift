import SwiftUI
import EthersPrismCore

struct OutputColumn: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                if let issue = model.configurationIssue {
                    HStack {
                        Banner(style: .warning, text: issue)
                        SettingsLink { Text("Settings…") }
                    }
                } else if model.usingMock {
                    Banner(style: .info, text: "Using the Mock provider: results are test placeholders, not real generations. Switch providers in Settings.")
                }
                if model.adapter.id == "beats", let note = model.producerNote {
                    Banner(style: .info, text: note)
                }
                if case .failed(let message) = model.phase {
                    Banner(style: .error, text: message, actionTitle: "Retry") { model.retry() }
                }
                if let snap = model.current?.currentSnapshot, let review = snap.output.review {
                    Banner(style: review.passed ? .info : .warning,
                           text: review.passed
                               ? "\(review.reviewer): meets the fixed requirements."
                               : "\(review.reviewer) flagged: " + review.issues.joined(separator: " · "))
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)

            if let snap = model.current?.currentSnapshot {
                ResultDisplay(snapshot: snap, editable: model.adapter.capabilities.editable)
                    .id(snap.id)
                    .background(.background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator))
                    .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
                    .padding(16)
                ResultCaption(snapshot: snap)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            } else {
                ContentUnavailableView {
                    Label {
                        Text("Nothing played yet")
                    } icon: {
                        if AppIcon.image != nil {
                            AppLogo(size: 120).shadow(color: .purple.opacity(0.3), radius: 18)
                        } else {
                            Image(systemName: "dial.medium")
                        }
                    }
                } description: {
                    Text("Set the dials, then press Preview. Don't ask for the thing: build the instrument, then play it.")
                } actions: {
                    Button("Preview") { model.generate(.preview, force: true) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }
}

/// One quiet line under the result: how it was made, when, and by what.
struct ResultCaption: View {
    let snapshot: Snapshot

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon(for: snapshot.origin))
            Text(snapshot.origin.label)
            Text("·")
            Text(snapshot.createdAt, style: .time)
            let by = [snapshot.output.agent, snapshot.output.provider].compactMap { $0 }.joined(separator: " · ")
            if !by.isEmpty {
                Text("·")
                Text(by)
            }
            Spacer(minLength: 0)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .help("Model: \(snapshot.output.model)")
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
            if let s = model.current {
                let rows = s.treeRows()
                if rows.isEmpty {
                    ContentUnavailableView("No History Yet", systemImage: "clock.arrow.circlepath",
                        description: Text("Each preview, render, sweep pick and edit is kept here as a tree. Click a state to return to it."))
                } else {
                    List {
                    Section("History") {
                    ForEach(rows) { row in
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
                        .listRowBackground(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(row.id == s.currentSnapshotID ? Color.accentColor.opacity(0.18) : Color.clear)
                                .padding(.horizontal, 6))
                    }
                    }
                    }
                    .listStyle(.sidebar)
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
                .frame(width: 34, height: 34)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
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
