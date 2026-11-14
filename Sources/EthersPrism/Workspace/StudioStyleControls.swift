import SwiftUI
import ImageIO
import EthersPrismCore

struct StudioStyle: Decodable, Identifiable {
    let id: String
    let name: String
    let description: String
    let collection: String
    let atlas: String
    let cols: Int
    let rows: Int
    let tile: Int

    /// The Studio's collections, in the Studio's order.
    static let collections = ["Images", "3D", "Anime", "Donghua", "World", "Visions"]

    private static let directory = Bundle.module.resourceURL?.appendingPathComponent("StudioCatalog")
    static let catalog: [Self] = {
        guard let url = directory?.appendingPathComponent("styles.json"),
              let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Self].self, from: data)) ?? []
    }()

    static func styles(in collection: String) -> [Self] { catalog.filter { $0.collection == collection } }

    // Sample sheets are decoded once and each sample is cut once, so the thumbnail grid scrolls smoothly.
    private static var atlasCache: [String: CGImage] = [:]
    private static var sampleCache: [String: CGImage] = [:]

    func sample() -> CGImage? {
        if let cached = Self.sampleCache[id] { return cached }
        let sheet: CGImage
        if let cached = Self.atlasCache[atlas] {
            sheet = cached
        } else {
            guard let url = Self.directory?.appendingPathComponent(atlas),
                  let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
            Self.atlasCache[atlas] = image
            sheet = image
        }
        let width = Double(sheet.width) / Double(cols)
        let height = Double(sheet.height) / Double(rows)
        guard let cut = sheet.cropping(to: CGRect(x: Double(tile % cols) * width, y: Double(tile / cols) * height,
                                                  width: width, height: height)) else { return nil }
        Self.sampleCache[id] = cut
        return cut
    }

    var prompt: String {
        "Restyle the reference as \(name). \(description). Preserve the subject identity, pose, silhouette, framing, and distinctive markings."
    }

    /// The goal with this look added on its own last line, replacing any look chosen before.
    func goal(adding to: String) -> String {
        var base = to.components(separatedBy: "\n\nLook: ").first ?? ""
        if base.hasPrefix("Look: ") { base = "" }
        base = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let line = "Look: \(name) — \(description)."
        return base.isEmpty ? line : base + "\n\n" + line
    }
}

/// "Choose your look": the Studio's six collections as tabs, each with a grid of sample thumbnails.
/// In Image it restyles the reference (ComfyUI) or adds the look to the goal; in Line Logo it restyles the chosen image.
struct StudioStyleControls: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("studioLookCollection") private var collection = "3D"
    @State private var styleID = ""

    private var styles: [StudioStyle] { StudioStyle.styles(in: collection) }
    private var style: StudioStyle? { styles.first { $0.id == styleID } ?? styles.first }
    private let tabColumns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 3)
    private let thumbColumns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)

    var body: some View {
        if StudioStyle.catalog.isEmpty {
            Text("The Studio catalog couldn't be loaded.").font(.caption)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                LazyVGrid(columns: tabColumns, spacing: 6) {
                    ForEach(StudioStyle.collections, id: \.self) { name in
                        CollectionTab(name: name, count: StudioStyle.styles(in: name).count,
                                      selected: name == collection) { collection = name }
                    }
                }
                ScrollView {
                    LazyVGrid(columns: thumbColumns, spacing: 10) {
                        ForEach(styles) { s in
                            LookTile(style: s, selected: s.id == style?.id) { styleID = s.id }
                        }
                    }
                    .padding(3)
                }
                .frame(height: 300)
                if let style {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(style.name).font(.headline)
                        Text(style.description).font(.caption).foregroundStyle(.secondary)
                    }
                    applyButton(style)
                }
            }
            .onChange(of: collection, initial: true) {
                if !styles.contains(where: { $0.id == styleID }) { styleID = styles.first?.id ?? "" }
            }
        }
    }

    @ViewBuilder
    private func applyButton(_ style: StudioStyle) -> some View {
        let comfy = model.imageProviderKind == "comfyui"
        if model.adapter.id == "linelogo" {
            let hasImage = model.current.flatMap { GreasePencilLogoAdapter.imagePath(from: $0.goal) } != nil
            Button { model.restyleLineLogo(with: style) } label: {
                Label("Restyle Image with This Look", systemImage: "paintpalette")
            }
            .disabled(!hasImage || !comfy)
            if !hasImage {
                hint("Choose an image first, then restyle it with this look before tracing.")
            } else if !comfy {
                hint("Select ComfyUI on this Mac in Settings to restyle the image.")
            }
        } else if model.current?.imageReference != nil {
            Button { model.applyStudioStyle(style) } label: {
                Label("Apply Look to Reference", systemImage: "paintpalette")
            }
            .disabled(!comfy)
            if !comfy { hint("Select ComfyUI on this Mac in Settings to restyle a reference image.") }
        } else {
            Button { model.useStudioLook(style) } label: {
                Label("Use This Look", systemImage: "paintpalette")
            }
            hint("Adds the look to your goal and makes a preview. Choose a reference image to restyle a picture instead.")
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
    }
}

private struct CollectionTab: View {
    let name: String
    let count: Int
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(name).lineLimit(1)
                Text("\(count)").foregroundStyle(.secondary)
            }
            .font(.caption.weight(selected ? .semibold : .regular))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7)
                .fill(selected ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 7)
                .strokeBorder(selected ? Color.accentColor : Color.clear, lineWidth: 1.5))
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(name), \(count) looks")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct LookTile: View {
    let style: StudioStyle
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Group {
                    if let sample = style.sample() {
                        Image(decorative: sample, scale: 1).resizable().scaledToFill()
                    } else {
                        Color.primary.opacity(0.08)
                    }
                }
                .frame(minWidth: 0, maxWidth: .infinity)
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.12),
                                  lineWidth: selected ? 3 : 1))
                Text(style.name)
                    .font(.caption2)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(selected ? .primary : .secondary)
                    .frame(maxWidth: .infinity, minHeight: 26, alignment: .top)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(style.name): \(style.description)")
        .accessibilityLabel(style.name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
