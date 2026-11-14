import SwiftUI
import AppKit
import EthersPrismCore

/// The Color tab: Match to Reference, color wheels, LUT.
struct ColorPanel: View {
    @EnvironmentObject var studio: StudioModel
    @EnvironmentObject var auto: AutoImportController
    @State private var logWheels = false
    /// Color Studio shows only Shot Match and LUT (its wheels are in Primaries).
    var showWheels = true

    var body: some View {
        if showWheels {
            VStack(alignment: .leading, spacing: 12) {
                matchSection
                Divider()
                wheelsSection
                Divider()
                lutSection
            }
        } else {
            HStack(alignment: .top, spacing: 24) {
                matchSection.frame(maxWidth: 320, alignment: .leading)
                lutSection.frame(maxWidth: 320, alignment: .leading)
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    // MARK: Match

    private var matchSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                PrismHeading(title: "Shot Match")
                Spacer()
                Button("Auto Balance") { studio.autoBalance() }
                    .buttonStyle(PrismToolButtonStyle())
                    .help("Balance black, white and colour cast automatically")
            }
            if let name = studio.edit.matchReferenceName {
                HStack {
                    Image(systemName: "link").foregroundStyle(PrismTheme.teal)
                    Text(name).font(.caption).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Clear") { studio.clearMatch() }.buttonStyle(PrismToolButtonStyle())
                }
                let c = StudioControls.byID["matchStrength"]!
                PrismSlider(control: c, value: studio.binding(c.id)) { studio.commit(c.label) }
            } else {
                Text("Match this picture's colour, contrast and brightness to another, so a series looks like one set.")
                    .font(.caption).foregroundStyle(PrismTheme.secondaryText)
            }
            Menu {
                ForEach(auto.items.filter { $0.id != studio.item?.id }.prefix(30)) { it in
                    Button(it.fileName) { studio.matchTo(it) }
                }
                Divider()
                Button("Choose File…") { studio.chooseMatchFile() }
            } label: {
                Label("Choose Reference", systemImage: "eyedropper")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .buttonStyle(PrismToolButtonStyle())
        }
    }

    // MARK: Wheels

    private var wheelsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                PrismHeading(title: "Color Wheels")
                Spacer()
                Picker("", selection: $logWheels) {
                    Text("Primary").tag(false)
                    Text("Log").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 130)
            }
            let wheels = logWheels ? StudioColor.Wheel.log : StudioColor.Wheel.primary
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 12) {
                ForEach(wheels) { w in
                    WheelControl(wheel: w)
                }
            }
            Text(logWheels
                 ? "Shadows, Midtones and Highlights each touch only their part of the tonal range."
                 : "Lift: blacks · Gamma: middle · Gain: whites · Offset: everything. Drag the dot for colour, the slider for brightness; double-click to reset.")
                .font(.caption).foregroundStyle(PrismTheme.secondaryText)
        }
    }

    // MARK: LUT

    private var lutSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            PrismHeading(title: "LUT")
            if let path = studio.edit.lutPath {
                HStack {
                    Image(systemName: "cube.transparent").foregroundStyle(PrismTheme.teal)
                    Text((path as NSString).lastPathComponent).font(.caption).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Clear") { studio.clearLUT() }.buttonStyle(PrismToolButtonStyle())
                }
                let c = StudioControls.byID["lutStrength"]!
                PrismSlider(control: c, value: studio.binding(c.id)) { studio.commit(c.label) }
            } else {
                Text("Load a 3D .cube LUT (film emulations, looks from other apps).")
                    .font(.caption).foregroundStyle(PrismTheme.secondaryText)
            }
            Button { studio.loadLUT() } label: { Label("Load LUT…", systemImage: "square.and.arrow.down") }
                .buttonStyle(PrismToolButtonStyle())
        }
    }
}

/// One colour wheel: a hue disc with a draggable dot, and a brightness slider under it.
struct WheelControl: View {
    @EnvironmentObject var studio: StudioModel
    let wheel: StudioColor.Wheel

    private static let ring: [Color] = (0...12).map { i in
        // Clockwise on screen from 3 o'clock = negative maths angle.
        let c = StudioColor.displayColor(angle: -Double(i) / 12 * 2 * .pi)
        return Color(.sRGB, red: c.r, green: c.g, blue: c.b)
    }

    var body: some View {
        let x = studio.edit[wheel.xKey], y = studio.edit[wheel.yKey]
        let level = StudioControls.byID[wheel.levelKey]!
        VStack(spacing: 4) {
            HStack {
                Text(wheel.label).font(.system(size: 11, weight: .semibold))
                Spacer()
                Text(level.format(studio.edit[wheel.levelKey])).font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(studio.edit[wheel.levelKey] == 0 ? PrismTheme.secondaryText : PrismTheme.teal)
            }
            GeometryReader { geo in
                let d = min(geo.size.width, geo.size.height)
                let r = d / 2
                ZStack {
                    Circle().fill(AngularGradient(colors: Self.ring, center: .center))
                    Circle().fill(RadialGradient(colors: [Color(hex: 0x17232E), Color(hex: 0x17232E).opacity(0)],
                                                 center: .center, startRadius: 0, endRadius: r))
                    Circle().strokeBorder(PrismTheme.border, lineWidth: 1)
                    Path { p in
                        p.move(to: CGPoint(x: r, y: r - 4)); p.addLine(to: CGPoint(x: r, y: r + 4))
                        p.move(to: CGPoint(x: r - 4, y: r)); p.addLine(to: CGPoint(x: r + 4, y: r))
                    }
                    .stroke(PrismTheme.secondaryText.opacity(0.6), lineWidth: 1)
                    Circle().fill(Color.white).frame(width: 10, height: 10)
                        .overlay(Circle().strokeBorder(PrismTheme.teal, lineWidth: 2))
                        .shadow(color: PrismTheme.teal.opacity(0.7), radius: 4)
                        .position(x: r + x * r * 0.9, y: r - y * r * 0.9)
                }
                .frame(width: d, height: d)
                .contentShape(Circle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        var dx = (g.location.x - r) / (r * 0.9), dy = -(g.location.y - r) / (r * 0.9)
                        let m = hypot(dx, dy)
                        if m > 1 { dx /= m; dy /= m }
                        studio.setWheel(wheel, x: Double(dx), y: Double(dy))
                    }
                    .onEnded { _ in studio.commit("\(wheel.label) Wheel") })
                .simultaneousGesture(TapGesture(count: 2).onEnded {
                    studio.setWheel(wheel, x: 0, y: 0)
                    studio.edit[wheel.levelKey] = 0
                    studio.commit("Reset \(wheel.label)")
                })
            }
            .aspectRatio(1, contentMode: .fit)
            Slider(value: studio.binding(wheel.levelKey), in: level.range) { editing in
                if !editing { studio.commit(wheel.label) }
            }
            .controlSize(.mini)
            .tint(PrismTheme.teal)
        }
    }
}
