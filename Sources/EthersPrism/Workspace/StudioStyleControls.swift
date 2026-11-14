import SwiftUI
import ImageIO

struct StudioStyle: Decodable, Identifiable {
    let id: String
    let name: String
    let description: String
    let collection: String
    let atlas: String
    let cols: Int
    let rows: Int
    let tile: Int

    private static let directory = Bundle.module.resourceURL?.appendingPathComponent("StudioCatalog")
    static let catalog: [Self] = {
        guard let url = directory?.appendingPathComponent("styles.json"),
              let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Self].self, from: data)) ?? []
    }()

    func sample() -> CGImage? {
        guard let url = Self.directory?.appendingPathComponent(atlas),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let width = Double(image.width) / Double(cols)
        let height = Double(image.height) / Double(rows)
        return image.cropping(to: CGRect(x: Double(tile % cols) * width, y: Double(tile / cols) * height,
                                         width: width, height: height))
    }

    var prompt: String {
        "Restyle the reference as \(name). \(description). Preserve the subject identity, pose, silhouette, framing, and distinctive markings."
    }
}

struct StudioStyleControls: View {
    @EnvironmentObject var model: AppModel
    @State private var collection = "3D"
    @State private var styleID = "d2"

    private let collections = ["Images", "3D", "Anime", "Donghua", "World", "Visions"]
    private var styles: [StudioStyle] { StudioStyle.catalog.filter { $0.collection == collection } }
    private var style: StudioStyle? { styles.first { $0.id == styleID } ?? styles.first }

    var body: some View {
        DisclosureGroup("Studio Styles") {
            Picker("Collection", selection: $collection) {
                ForEach(collections, id: \.self) { Text($0).tag($0) }
            }
            Picker("Style", selection: $styleID) {
                ForEach(styles) { Text($0.name).tag($0.id) }
            }
            if let style {
                if let sample = style.sample() {
                    Image(decorative: sample, scale: 1)
                        .resizable().scaledToFit().frame(maxHeight: 140)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .accessibilityLabel("\(style.name) Studio sample")
                }
                Text(style.description).font(.caption).foregroundStyle(.secondary)
                Button("Apply Style to Reference") { model.applyStudioStyle(style) }
                    .disabled(model.imageProviderKind != "comfyui" || model.current?.imageReference == nil)
                if model.current?.imageReference == nil {
                    Text("Choose a reference image to apply this look.").font(.caption)
                }
            } else {
                Text("The Studio catalog couldn't be loaded.").font(.caption)
            }
        }
        .onChange(of: collection, initial: true) {
            if !styles.contains(where: { $0.id == styleID }) { styleID = styles.first?.id ?? "" }
        }
    }
}
