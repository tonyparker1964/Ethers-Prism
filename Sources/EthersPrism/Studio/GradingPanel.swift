import SwiftUI
import AppKit
import EthersPrismCore

/// Color Studio's grading panel (after DaVinci Resolve's Color page): Primaries, Curves and Hue Curves on the
/// left, a live scope on the right.
struct GradingPanel: View {
    @EnvironmentObject var studio: StudioModel

    var body: some View {
        HStack(spacing: 10) {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    ForEach(StudioModel.GradingTab.allCases) { t in
                        Button(t.title) { withAnimation(PrismTheme.spring) { studio.gradingTab = t } }
                            .buttonStyle(PrismToolButtonStyle(active: studio.gradingTab == t))
                    }
                    Spacer()
                    if studio.gradingTab == .primaries {
                        Picker("", selection: $studio.logWheels) {
                            Text("Color Wheels").tag(false)
                            Text("Log Wheels").tag(true)
                        }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 210)
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
                Rectangle().fill(PrismTheme.border).frame(height: 1)
                Group {
                    switch studio.gradingTab {
                    case .primaries: PrimariesView()
                    case .curves: CurvesView(kinds: CurveKind.custom, selection: $studio.curveKind)
                    case .hueCurves: CurvesView(kinds: CurveKind.hue, selection: $studio.hueCurveKind)
                    case .matchLUT: ColorPanel(showWheels: false)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity)
            }
            .prismPanel(padding: 0)

            ScopePanel()
                .frame(width: 270)
                .prismPanel(padding: 0)
        }
        .disabled(!studio.hasImage)
    }
}

// MARK: - Primaries

struct PrimariesView: View {
    @EnvironmentObject var studio: StudioModel

    var body: some View {
        VStack(spacing: 6) {
            // Top bar: Auto, Temp, Tint, Contrast, Pivot, Mid/Detail
            HStack(spacing: 10) {
                Button { studio.autoBalance() } label: {
                    Text("A").font(.system(size: 12, weight: .bold))
                        .frame(width: 22, height: 22)
                        .overlay(Circle().strokeBorder(PrismTheme.teal, lineWidth: 1.5))
                }
                .buttonStyle(.plain).foregroundStyle(PrismTheme.teal)
                .help("Auto Balance: sets black, white and colour balance from the picture")
                ParamField(id: "temperature", label: "Temp")
                ParamField(id: "tint", label: "Tint")
                ParamField(id: "contrastP", label: "Contrast")
                ParamField(id: "pivot", label: "Pivot")
                ParamField(id: "midDetail", label: "Mid/Detail")
            }
            .padding(.horizontal, 10)

            let wheels = studio.logWheels ? StudioColor.Wheel.log : StudioColor.Wheel.primary
            HStack(spacing: 8) {
                ForEach(wheels) { w in PrimaryWheel(wheel: w) }
            }
            .padding(.horizontal, 10)
            .frame(maxHeight: .infinity)

            // Bottom bar: Color Boost, Shadows, Highlights, Saturation, Hue, Lum Mix
            HStack(spacing: 10) {
                ParamField(id: "colorBoost", label: "Color Boost")
                ParamField(id: "shadowsP", label: "Shadows")
                ParamField(id: "highlightsP", label: "Highlights")
                ParamField(id: "saturationP", label: "Saturation")
                ParamField(id: "hue", label: "Hue")
                ParamField(id: "lumMix", label: "Lum Mix")
            }
            .padding(.horizontal, 10).padding(.bottom, 8)
        }
        .padding(.top, 6)
    }
}

/// A Resolve-style parameter: label, a value box you can type in, and a thin slider to scrub.
struct ParamField: View {
    @EnvironmentObject var studio: StudioModel
    let id: String
    let label: String

    var body: some View {
        let c = StudioControls.byID[id]!
        let changed = studio.edit[id] != c.neutral
        VStack(spacing: 1) {
            Text(label).font(.system(size: 10)).foregroundStyle(PrismTheme.secondaryText).lineLimit(1).fixedSize()
            VStack(spacing: 1) {
                TextField("", value: Binding(get: { studio.edit[id] }, set: { studio.edit[id] = min(max($0, c.range.lowerBound), c.range.upperBound); studio.commit(label) }),
                          format: .number.precision(.fractionLength(c.unit == "x" ? 3 : (c.unit == "n" ? 2 : 0))))
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .multilineTextAlignment(.center)
                    .foregroundStyle(changed ? PrismTheme.teal : PrismTheme.text)
                    .frame(width: 50)
                    .padding(.vertical, 1)
                    .background(PrismTheme.background, in: RoundedRectangle(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(PrismTheme.border))
                Slider(value: studio.binding(id), in: c.range) { editing in if !editing { studio.commit(label) } }
                    .controlSize(.mini).tint(PrismTheme.teal).frame(width: 56)
            }
            .contextMenu { Button("Reset \(label)") { studio.edit[id] = c.neutral; studio.commit("Reset \(label)") } }
        }
    }
}

/// One Primaries wheel: title and reset, the wheel, Y/R/G/B numbers and the master (Y) wheel underneath.
struct PrimaryWheel: View {
    @EnvironmentObject var studio: StudioModel
    let wheel: StudioColor.Wheel

    var body: some View {
        let n = studio.wheelNumbers(wheel)
        VStack(spacing: 4) {
            HStack {
                Spacer()
                Text(wheel.label).font(.system(size: 12, weight: .semibold))
                Spacer()
                Button { studio.resetWheel(wheel) } label: { Image(systemName: "arrow.counterclockwise") }
                    .buttonStyle(.plain).foregroundStyle(PrismTheme.secondaryText).help("Reset \(wheel.label)")
            }
            WheelDisc(wheel: wheel)
                .frame(maxWidth: 150, maxHeight: 150)
            HStack(spacing: 2) {
                number(n.y, .white) { studio.setWheelNumbers(wheel, y: $0) }
                number(n.r, .red) { studio.setWheelNumbers(wheel, r: $0) }
                number(n.g, .green) { studio.setWheelNumbers(wheel, g: $0) }
                number(n.b, .blue) { studio.setWheelNumbers(wheel, b: $0) }
            }
            Slider(value: studio.binding(wheel.levelKey), in: -100...100) { e in if !e { studio.commit(wheel.label) } }
                .controlSize(.mini).tint(PrismTheme.teal)
        }
        .frame(maxWidth: .infinity)
    }

    private func number(_ v: Double, _ color: Color, set: @escaping (Double) -> Void) -> some View {
        VStack(spacing: 1) {
            TextField("", value: Binding(get: { v }, set: set), format: .number.precision(.fractionLength(2)))
                .textFieldStyle(.plain)
                .font(.system(size: 10).monospacedDigit())
                .multilineTextAlignment(.center)
                .frame(width: 30)
                .padding(.vertical, 1)
                .background(PrismTheme.background, in: RoundedRectangle(cornerRadius: 3))
                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(PrismTheme.border))
            Rectangle().fill(color).frame(width: 26, height: 2)
        }
    }
}

/// The wheel itself (shared look with the inspector's smaller wheels).
struct WheelDisc: View {
    @EnvironmentObject var studio: StudioModel
    let wheel: StudioColor.Wheel

    static let ring: [Color] = (0...24).map { i in
        let c = StudioColor.displayColor(angle: -Double(i) / 24 * 2 * .pi)
        return Color(.sRGB, red: c.r, green: c.g, blue: c.b)
    }

    var body: some View {
        GeometryReader { geo in
            let d = min(geo.size.width, geo.size.height)
            let r = d / 2
            let x = studio.edit[wheel.xKey], y = studio.edit[wheel.yKey]
            ZStack {
                Circle().fill(Color(hex: 0x10171E))
                Circle().strokeBorder(AngularGradient(colors: Self.ring, center: .center), lineWidth: 5)
                Circle().fill(RadialGradient(colors: [Color.clear, Color(hex: 0x10171E)], center: .center, startRadius: 0, endRadius: r))
                    .opacity(0.4)
                Path { p in
                    p.move(to: CGPoint(x: r, y: 8)); p.addLine(to: CGPoint(x: r, y: d - 8))
                    p.move(to: CGPoint(x: 8, y: r)); p.addLine(to: CGPoint(x: d - 8, y: r))
                }
                .stroke(PrismTheme.border, lineWidth: 1)
                // The level arc (like Resolve's grey arc), showing the master value.
                Circle().trim(from: 0, to: CGFloat(abs(studio.edit[wheel.levelKey]) / 100))
                    .stroke(PrismTheme.teal, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(90))
                    .scaleEffect(x: studio.edit[wheel.levelKey] < 0 ? -1 : 1, y: 1)
                    .padding(-4)
                Circle().fill(Color.white).frame(width: 9, height: 9)
                    .shadow(color: PrismTheme.teal, radius: 4)
                    .position(x: r + x * (r - 10), y: r - y * (r - 10))
            }
            .frame(width: d, height: d)
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
            .contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    let ox = (geo.size.width - d) / 2, oy = (geo.size.height - d) / 2
                    var dx = Double((g.location.x - ox - r) / (r - 10)), dy = Double(-(g.location.y - oy - r) / (r - 10))
                    let m = hypot(dx, dy)
                    if m > 1 { dx /= m; dy /= m }
                    studio.setWheel(wheel, x: dx, y: dy)
                }
                .onEnded { _ in studio.commit("\(wheel.label) Wheel") })
            .simultaneousGesture(TapGesture(count: 2).onEnded { studio.resetWheel(wheel) })
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

// MARK: - Curves

struct CurvesView: View {
    @EnvironmentObject var studio: StudioModel
    let kinds: [CurveKind]
    @Binding var selection: CurveKind

    var body: some View {
        HStack(spacing: 10) {
            CurveEditor(kind: kinds.contains(selection) ? selection : kinds[0])
                .padding(10)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(kinds) { k in
                    Button {
                        selection = k
                    } label: {
                        HStack {
                            Circle().fill(color(k)).frame(width: 8, height: 8)
                            Text(k.label).font(.system(size: 12))
                            Spacer()
                            if !studio.edit.curve(k).isEmpty { Image(systemName: "circle.fill").font(.system(size: 5)).foregroundStyle(PrismTheme.teal) }
                        }
                    }
                    .buttonStyle(PrismToolButtonStyle(active: selection == k))
                }
                Spacer()
                Button("Reset Curve") { studio.resetCurve(selection) }.buttonStyle(PrismToolButtonStyle())
                Text(selection.isCustom
                     ? "Click to add a point, drag to move, double-click a point to remove it."
                     : "Click a colour to add a point (with neutral points either side); drag up or down.")
                    .font(.caption2).foregroundStyle(PrismTheme.secondaryText)
            }
            .frame(width: 150)
            .padding(.vertical, 10).padding(.trailing, 10)
        }
    }

    private func color(_ k: CurveKind) -> Color {
        switch k {
        case .red: return .red
        case .green: return .green
        case .blue: return .blue
        case .luma: return .white
        default: return PrismTheme.teal
        }
    }
}

struct CurveEditor: View {
    @EnvironmentObject var studio: StudioModel
    let kind: CurveKind
    @State private var dragging: Int?

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let pts = studio.edit.curve(kind)
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Color(hex: 0x0B1219))
                background(size)
                grid(size)
                curvePath(size).stroke(curveColor, lineWidth: 2)
                    .shadow(color: curveColor.opacity(0.6), radius: 3)
                ForEach(Array(pts.enumerated()), id: \.offset) { i, p in
                    Circle().fill(dragging == i ? PrismTheme.teal : Color.white).frame(width: 9, height: 9)
                        .overlay(Circle().strokeBorder(PrismTheme.teal, lineWidth: 1.5))
                        .position(x: p.x * size.width, y: (1 - p.y) * size.height)
                        .onTapGesture(count: 2) {
                            var q = pts; q.remove(at: i)
                            studio.setCurve(kind, q); studio.commit("\(kind.label) Curve")
                        }
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in drag(g.location, size: size, start: g.startLocation, first: dragging == nil) }
                .onEnded { _ in dragging = nil; studio.commit("\(kind.label) Curve") })
        }
    }

    private var curveColor: Color {
        switch kind {
        case .red: return .red
        case .green: return .green
        case .blue: return Color(hex: 0x4D7CFF)
        default: return Color.white
        }
    }

    private func drag(_ loc: CGPoint, size: CGSize, start: CGPoint, first: Bool) {
        var pts = studio.edit.curve(kind)
        let x = min(max(loc.x / size.width, 0), 1), y = min(max(1 - loc.y / size.height, 0), 1)
        if first {
            // Grab the nearest point, or add one.
            let near = pts.enumerated().min { a, b in
                hypot(a.element.x * size.width - start.x, (1 - a.element.y) * size.height - start.y)
                    < hypot(b.element.x * size.width - start.x, (1 - b.element.y) * size.height - start.y)
            }
            if let near, hypot(near.element.x * size.width - start.x, (1 - near.element.y) * size.height - start.y) < 12 {
                dragging = near.offset
            } else {
                let sx = min(max(start.x / size.width, 0), 1)
                // A hue curve gets neutral neighbours, so only nearby colours change (as in Resolve).
                if kind.isPeriodic && pts.isEmpty {
                    pts.append(CurvePoint((sx - 0.1 + 1).truncatingRemainder(dividingBy: 1), 0.5))
                    pts.append(CurvePoint((sx + 0.1).truncatingRemainder(dividingBy: 1), 0.5))
                }
                pts.append(CurvePoint(sx, StudioCurves.evaluate(kind, studio.edit.curve(kind), at: sx)))
                dragging = pts.count - 1
            }
        }
        guard let i = dragging, i < pts.count else { return }
        // Custom curves keep points in order; hue curves move only up and down once placed.
        pts[i] = CurvePoint(kind.isPeriodic ? pts[i].x : x, y)
        studio.setCurve(kind, pts)
    }

    private func curvePath(_ size: CGSize) -> Path {
        let pts = studio.edit.curve(kind)
        return Path { p in
            for i in 0...120 {
                let x = Double(i) / 120
                let y = StudioCurves.evaluate(kind, pts, at: x)
                let pt = CGPoint(x: x * size.width, y: (1 - min(max(y, 0), 1)) * size.height)
                if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
            }
        }
    }

    private func grid(_ size: CGSize) -> some View {
        Path { p in
            for i in 1..<4 {
                let x = size.width * CGFloat(i) / 4, y = size.height * CGFloat(i) / 4
                p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: size.height))
                p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: size.width, y: y))
            }
        }
        .stroke(PrismTheme.border.opacity(0.7), lineWidth: 0.5)
    }

    /// A live histogram behind custom curves; a hue spectrum behind hue curves.
    @ViewBuilder private func background(_ size: CGSize) -> some View {
        if kind.isPeriodic {
            LinearGradient(colors: (0...12).map { i in
                let c = StudioCurves.fromHSV(SIMD3(Double(i) / 12, 0.75, 0.55))
                return Color(.sRGB, red: c.x, green: c.y, blue: c.z)
            }, startPoint: .leading, endPoint: .trailing)
            .opacity(0.35)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        } else if kind == .lumSat {
            LinearGradient(colors: [.black, .white], startPoint: .leading, endPoint: .trailing).opacity(0.18)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        } else if studio.histogram.count == 4 {
            let channels: [(Int, Color)] = kind == .luma ? [(0, .red), (1, .green), (2, .blue)]
                : [(kind == .red ? 0 : kind == .green ? 1 : 2, kind == .red ? .red : kind == .green ? .green : .blue)]
            let peak = Double(max(studio.histogram[0...2].flatMap { $0.dropFirst(2).dropLast(2) }.max() ?? 1, 1))
            ZStack {
                ForEach(channels, id: \.0) { ch, color in
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: size.height))
                        for (i, n) in studio.histogram[ch].enumerated() {
                            p.addLine(to: CGPoint(x: Double(i) / 255 * size.width,
                                                  y: size.height - min(Double(n) / peak, 1) * size.height * 0.9))
                        }
                        p.addLine(to: CGPoint(x: size.width, y: size.height))
                        p.closeSubpath()
                    }
                    .fill(color.opacity(0.22))
                }
            }
        }
    }
}

// MARK: - Scopes

struct ScopePanel: View {
    @EnvironmentObject var studio: StudioModel

    var body: some View {
        VStack(spacing: 6) {
            Picker("", selection: $studio.scopeKind) {
                ForEach(ScopeKind.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.menu).labelsHidden()
            .padding(.horizontal, 10).padding(.top, 8)
            ZStack {
                Color.black
                if let img = studio.scopeImage {
                    Image(decorative: img, scale: 1).resizable().interpolation(.medium)
                        .aspectRatio(studio.scopeKind.isSquare ? 1 : 2, contentMode: .fit)
                        .overlay { ScopeGraticule(kind: studio.scopeKind) }
                } else {
                    Text("Scopes appear when a picture is open").font(.caption).foregroundStyle(PrismTheme.secondaryText)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .padding(.horizontal, 8).padding(.bottom, 8)
            .frame(maxHeight: .infinity)
        }
    }
}

/// Lines and labels drawn over a scope.
struct ScopeGraticule: View {
    let kind: ScopeKind

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            switch kind {
            case .waveform, .parade, .histogram:
                ZStack(alignment: .topLeading) {
                    Path { p in
                        for i in 0...4 {
                            let y = h * CGFloat(i) / 4
                            p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: w, y: y))
                        }
                        if kind == .parade {
                            for i in 1...2 {
                                let x = w * CGFloat(i) / 3
                                p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: h))
                            }
                        }
                    }
                    .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
                    if kind != .histogram {
                        ForEach(0...4, id: \.self) { i in
                            Text("\([1023, 768, 512, 256, 0][i])")
                                .font(.system(size: 7).monospacedDigit()).foregroundStyle(Color.white.opacity(0.4))
                                .offset(x: 2, y: h * CGFloat(i) / 4 - (i == 4 ? 10 : 0))
                        }
                    }
                }
            case .vectorscope:
                let c = CGPoint(x: w / 2, y: h / 2), r = min(w, h) / 2 * 0.92
                ZStack {
                    Circle().stroke(Color.white.opacity(0.18), lineWidth: 0.8).frame(width: r * 2 * 0.92, height: r * 2 * 0.92)
                    Circle().stroke(Color.white.opacity(0.08), lineWidth: 0.5).frame(width: r * 0.92, height: r * 0.92)
                    Path { p in
                        p.move(to: CGPoint(x: c.x - r, y: c.y)); p.addLine(to: CGPoint(x: c.x + r, y: c.y))
                        p.move(to: CGPoint(x: c.x, y: c.y - r)); p.addLine(to: CGPoint(x: c.x, y: c.y + r))
                    }
                    .stroke(Color.white.opacity(0.1), lineWidth: 0.5)
                    // Skin tone line (about 123° on a vectorscope).
                    Path { p in
                        let a = 123.0 * .pi / 180
                        p.move(to: c); p.addLine(to: CGPoint(x: c.x + cos(a) * r, y: c.y - sin(a) * r))
                    }
                    .stroke(Color.orange.opacity(0.5), style: StrokeStyle(lineWidth: 0.8, dash: [3, 3]))
                    ForEach(targets, id: \.0) { name, r1, g1, b1 in
                        let v = StudioScopes.vectorPosition(r: r1 * 0.75, g: g1 * 0.75, b: b1 * 0.75)
                        Text(name).font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Color(red: r1, green: g1, blue: b1).opacity(0.8))
                            .position(x: w * (0.5 + v.x * 0.92), y: h * (0.5 - v.y * 0.92))
                    }
                }
            case .cie:
                ZStack {
                    Path { p in
                        for (i, (x, y)) in StudioScopes.spectralLocus.enumerated() {
                            let pt = CGPoint(x: x / 0.8 * w, y: (1 - y / 0.9) * h)
                            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                        }
                        p.closeSubpath()
                    }
                    .stroke(Color.white.opacity(0.35), lineWidth: 0.8)
                    triangle([(0.64, 0.33), (0.30, 0.60), (0.15, 0.06)], w, h).stroke(Color.white.opacity(0.6), lineWidth: 0.8)
                    triangle([(0.68, 0.32), (0.265, 0.69), (0.15, 0.06)], w, h)
                        .stroke(PrismTheme.teal.opacity(0.6), style: StrokeStyle(lineWidth: 0.8, dash: [3, 2]))
                    VStack(alignment: .trailing, spacing: 1) {
                        Text("Rec.709 / sRGB").foregroundStyle(Color.white.opacity(0.7))
                        Text("Display P3").foregroundStyle(PrismTheme.teal.opacity(0.8))
                    }
                    .font(.system(size: 8)).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing).padding(4)
                }
            }
        }
    }

    private var targets: [(String, Double, Double, Double)] {
        [("R", 1, 0, 0), ("Yl", 1, 1, 0), ("G", 0, 1, 0), ("Cy", 0, 1, 1), ("B", 0, 0, 1), ("Mg", 1, 0, 1)]
    }

    private func triangle(_ pts: [(Double, Double)], _ w: CGFloat, _ h: CGFloat) -> Path {
        Path { p in
            for (i, (x, y)) in pts.enumerated() {
                let pt = CGPoint(x: x / 0.8 * w, y: (1 - y / 0.9) * h)
                if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
            }
            p.closeSubpath()
        }
    }
}
