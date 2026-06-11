import SwiftUI

enum ToolbarDock: String, CaseIterable, Codable {
    case top, bottom, leading, trailing
    var isHorizontal: Bool { self == .top || self == .bottom }

    var alignment: Alignment {
        switch self {
        case .top: return .top
        case .bottom: return .bottom
        case .leading: return .leading
        case .trailing: return .trailing
        }
    }
}

/// Floating, repositionable glass toolbar. Drag the grip toward a screen edge
/// to re-dock; the visible tool set is user-customizable and persisted.
/// Re-tapping the active inking tool (or tapping the color swatch) opens that
/// tool's options panel; re-tapping the lasso arms select-and-rotate.
struct FloatingToolbar: View {
    @ObservedObject var controller: CanvasController
    @AppStorage("toolbar.dock") private var dockRaw = ToolbarDock.top.rawValue
    // v2: hand tool added, eraser collapsed to one slot (object/pixel toggles inline).
    @AppStorage("toolbar.tools.v2") private var enabledToolsRaw = ToolKind.allCases
        .filter { $0 != .eraserObject }
        .map(\.rawValue).joined(separator: ",")
    @State private var showToolOptions = false
    /// The quick strip (colors/sizes) — opened by re-tapping the active tool.
    @State private var showInlineOptions = false
    @State private var showCustomize = false
    @State private var dragOffset: CGSize = .zero
    /// Global finger position while the grip is being dragged; drives the
    /// edge indicators that show where the bar can dock.
    @State private var gripDragLocation: CGPoint?
    @Environment(\.colorScheme) private var colorScheme

    var onInsertTextBox: () -> Void
    /// Freeform select-and-rotate (lasso strip).
    var onTransformSelection: () -> Void = {}
    /// Rectangle-marquee select-and-rotate (lasso strip).
    var onRectSelect: () -> Void = {}
    var extraItems: [ToolbarExtraItem] = []

    private var dock: ToolbarDock { ToolbarDock(rawValue: dockRaw) ?? .top }
    private var enabledTools: [ToolKind] {
        enabledToolsRaw.split(separator: ",").compactMap { ToolKind(rawValue: String($0)) }
    }
    /// Bar slots: both eraser variants collapse into one button that shows the
    /// variant currently in use (inline strip switches between them).
    private var displayTools: [ToolKind] {
        var eraserShown = false
        return enabledTools.compactMap { kind in
            guard kind == .eraserPixel || kind == .eraserObject else { return kind }
            if eraserShown { return nil }
            eraserShown = true
            let active = controller.toolState.kind
            return (active == .eraserPixel || active == .eraserObject) ? active : controller.lastEraserKind
        }
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // While options are open, the first tap anywhere outside
                // dismisses (popover behavior).
                if showToolOptions || showInlineOptions {
                    Color.clear
                        .contentShape(Rectangle())
                        .ignoresSafeArea()
                        .onTapGesture {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                                showToolOptions = false
                                showInlineOptions = false
                            }
                        }
                }
                if let location = gripDragLocation {
                    dockIndicators(highlighting: nearestDock(for: location))
                }
                content
                    .offset(dragOffset)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: dock.alignment)
                    .padding(12)
                    .animation(.spring(response: 0.3, dampingFraction: 0.8), value: dockRaw)
            }
        }
        .allowsHitTesting(true)
    }

    /// Four edge capsules shown while the grip is dragged; the dock the bar
    /// would snap to on release lights up.
    private func dockIndicators(highlighting target: ToolbarDock) -> some View {
        ZStack {
            ForEach(ToolbarDock.allCases, id: \.self) { edge in
                Capsule()
                    .fill(edge == target ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(
                        width: edge.isHorizontal ? 160 : 5,
                        height: edge.isHorizontal ? 5 : 160
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: edge.alignment)
                    .padding(4)
                    .animation(.easeOut(duration: 0.15), value: target)
            }
        }
        .allowsHitTesting(false)
        .transition(.opacity)
    }

    /// The bar plus (when open) its inline options panel — no UIKit popover,
    /// which mis-anchored inside the floating/draggable bar.
    @ViewBuilder
    private var content: some View {
        switch dock {
        case .top:
            VStack(spacing: 8) { bar; inlineStrip; optionsPanelIfNeeded }
        case .bottom:
            VStack(spacing: 8) { optionsPanelIfNeeded; inlineStrip; bar }
        case .leading:
            HStack(alignment: .top, spacing: 8) { bar; VStack(spacing: 8) { inlineStrip; optionsPanelIfNeeded } }
        case .trailing:
            HStack(alignment: .top, spacing: 8) { VStack(spacing: 8) { inlineStrip; optionsPanelIfNeeded }; bar }
        }
    }

    /// Per-tool quick options laid out parallel to the bar (same axis): colors
    /// and sizes for inking tools, mode + sizes for the eraser. Hidden until
    /// the active tool is tapped a second time.
    @ViewBuilder
    private var inlineStrip: some View {
        let kind = controller.toolState.kind
        if showInlineOptions {
            if kind.isInking {
                InkOptionsStrip(controller: controller, horizontal: dock.isHorizontal) {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { showToolOptions.toggle() }
                }
                .studyGlass(cornerRadius: 18)
                .transition(.scale(scale: 0.92, anchor: dock == .bottom ? .bottom : .top).combined(with: .opacity))
            } else if kind == .eraserPixel || kind == .eraserObject {
                EraserOptionsStrip(controller: controller, horizontal: dock.isHorizontal)
                    .studyGlass(cornerRadius: 18)
                    .transition(.scale(scale: 0.92, anchor: dock == .bottom ? .bottom : .top).combined(with: .opacity))
            } else if kind == .lasso {
                LassoOptionsStrip(horizontal: dock.isHorizontal) { rectangular in
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { showInlineOptions = false }
                    rectangular ? onRectSelect() : onTransformSelection()
                }
                .studyGlass(cornerRadius: 18)
                .transition(.scale(scale: 0.92, anchor: dock == .bottom ? .bottom : .top).combined(with: .opacity))
            }
        }
    }

    @ViewBuilder
    private var optionsPanelIfNeeded: some View {
        if showToolOptions {
            ToolOptionsPanel(controller: controller) {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { showToolOptions = false }
            }
            .studyGlass(cornerRadius: 18)
            .transition(.scale(scale: 0.92, anchor: dock == .bottom ? .bottom : .top).combined(with: .opacity))
        }
    }

    @ViewBuilder
    private var bar: some View {
        let layout = dock.isHorizontal
            ? AnyLayout(HStackLayout(spacing: 6))
            : AnyLayout(VStackLayout(spacing: 6))

        layout {
            grip
            ForEach(displayTools) { kind in
                toolButton(kind)
            }
            Divider().frame(maxHeight: 22).frame(maxWidth: 22)
            Button(action: { controller.isRulerActive.toggle() }) {
                Image(systemName: "ruler")
                    .symbolVariant(controller.isRulerActive ? .fill : .none)
            }
            .accessibilityLabel(Text("tool.ruler"))
            Button(action: onInsertTextBox) {
                Image(systemName: "textbox")
            }
            .accessibilityLabel(Text("tool.textbox"))
            ForEach(extraItems) { item in
                Button(action: item.action) { Image(systemName: item.symbolName) }
                    .accessibilityLabel(Text(item.labelKey))
            }
            Menu {
                Button { showCustomize = true } label: { Label("toolbar.customize", systemImage: "slider.horizontal.3") }
                Toggle(isOn: $controller.pencilOnly) { Label("toolbar.pencilOnly", systemImage: "applepencil") }
                Toggle(isOn: $controller.autoShapes) { Label("tool.autoShapes", systemImage: "square.on.circle") }
                Toggle(isOn: $controller.snapToGrid) { Label("tool.snapToGrid", systemImage: "grid") }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
        .buttonStyle(ToolbarButtonStyle())
        .padding(8)
        .studyGlass(cornerRadius: 18)
        .sheet(isPresented: $showCustomize) { CustomizeToolbarSheet(enabledToolsRaw: $enabledToolsRaw) }
    }

    private var grip: some View {
        Image(systemName: "line.3.horizontal")
            .foregroundStyle(.tertiary)
            // Full button-sized hit target — the bare glyph was ~16pt and
            // nearly impossible to grab.
            .frame(width: 34, height: 34)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(coordinateSpace: .global)
                    .onChanged { value in
                        dragOffset = value.translation
                        withAnimation(.easeOut(duration: 0.15)) { gripDragLocation = value.location }
                    }
                    .onEnded { value in
                        dragOffset = .zero
                        withAnimation(.easeOut(duration: 0.15)) { gripDragLocation = nil }
                        dockRaw = nearestDock(for: value.location).rawValue
                    }
            )
            .accessibilityLabel(Text("toolbar.move"))
    }

    private func nearestDock(for point: CGPoint) -> ToolbarDock {
        let bounds = UIScreen.main.bounds
        let distances: [(ToolbarDock, CGFloat)] = [
            (.top, point.y),
            (.bottom, bounds.height - point.y),
            (.leading, point.x),
            (.trailing, bounds.width - point.x),
        ]
        return distances.min { $0.1 < $1.1 }?.0 ?? .top
    }

    private func toolButton(_ kind: ToolKind) -> some View {
        let isActive = controller.toolState.kind == kind
        let hasOptions = kind != .hand
        return Button {
            if isActive {
                // Second tap on the active tool = toggle its quick options strip
                // (the lasso's strip offers freeform/rect select-and-rotate).
                if hasOptions {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        showInlineOptions.toggle()
                        if !showInlineOptions { showToolOptions = false }
                    }
                }
            } else {
                Haptics.selection()
                controller.select(kind)
                // Options belong to the tool that was tapped twice — switching
                // tools always starts with them closed.
                if showInlineOptions || showToolOptions {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        showInlineOptions = false
                        showToolOptions = false
                    }
                }
            }
        } label: {
            Image(systemName: kind.symbolName)
                .foregroundStyle(isActive ? Color.accentColor : Color.primary)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isActive ? Color.accentColor.opacity(0.16) : .clear)
                        .frame(width: 32, height: 32)
                )
        }
        .accessibilityLabel(Text(kind.labelKey))
        .accessibilityHint(isActive ? Text("tool.optionsHint") : Text(""))
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

/// Inline quick options for inking tools: scrollable color dots, a custom-color
/// well, stroke-size dots, pressure toggle, and a button into the full panel.
/// Runs along the same axis as the bar it belongs to.
private struct InkOptionsStrip: View {
    @ObservedObject var controller: CanvasController
    var horizontal = true
    var onMoreOptions: () -> Void
    @State private var customColor: Color = .black

    private static let presets = [
        "#000000", "#FFFFFF", "#0A84FF", "#FF453A", "#30D158",
        "#FFD60A", "#FF9F0A", "#BF5AF2", "#5E5CE6", "#8E8E93",
    ]
    private static let widths: [Double] = [2, 4, 7, 11, 16]

    var body: some View {
        let layout = horizontal ? AnyLayout(HStackLayout(spacing: 10)) : AnyLayout(VStackLayout(spacing: 10))
        let dotsLayout = horizontal ? AnyLayout(HStackLayout(spacing: 8)) : AnyLayout(VStackLayout(spacing: 8))
        layout {
            ScrollView(horizontal ? .horizontal : .vertical, showsIndicators: false) {
                dotsLayout {
                    ForEach(Self.presets, id: \.self) { hex in
                        colorDot(hex)
                    }
                }
                .padding(horizontal ? .vertical : .horizontal, 2)
            }
            .frame(maxWidth: horizontal ? 216 : nil, maxHeight: horizontal ? nil : 216)
            ColorPicker("tool.customColor", selection: $customColor, supportsOpacity: false)
                .labelsHidden()
                .frame(width: 30)
                .onChange(of: customColor) { _, newValue in
                    controller.toolState.colorHex = UIColor(newValue).hexString
                }

            stripDivider

            ForEach(Self.widths, id: \.self) { width in
                widthDot(width)
            }

            if controller.toolState.kind == .ballpoint || controller.toolState.kind == .fountain {
                stripDivider
                Button {
                    Haptics.selection()
                    controller.toolState.pressureSensitive.toggle()
                } label: {
                    Image(systemName: "scribble.variable")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(controller.toolState.pressureSensitive ? Color.accentColor : Color.secondary)
                        .frame(width: 30, height: 30)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(controller.toolState.pressureSensitive ? Color.accentColor.opacity(0.16) : .clear)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("tool.pressure"))
                .accessibilityAddTraits(controller.toolState.pressureSensitive ? .isSelected : [])
            }

            Button(action: onMoreOptions) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("tool.optionsHint"))
        }
        .padding(.horizontal, horizontal ? 12 : 6)
        .padding(.vertical, horizontal ? 6 : 12)
        .onAppear { customColor = Color(hex: controller.toolState.colorHex) ?? .black }
        .onChange(of: controller.toolState.kind) { _, _ in
            customColor = Color(hex: controller.toolState.colorHex) ?? .black
        }
    }

    private var stripDivider: some View {
        Divider().frame(
            maxWidth: horizontal ? nil : 22,
            maxHeight: horizontal ? 22 : nil
        )
    }

    private func colorDot(_ hex: String) -> some View {
        Button {
            Haptics.selection()
            controller.toolState.colorHex = hex
        } label: {
            Circle()
                .fill(Color(hex: hex) ?? .black)
                .frame(width: 26, height: 26)
                .overlay(Circle().strokeBorder(.quaternary))
                .overlay {
                    if controller.toolState.colorHex == hex {
                        Image(systemName: "checkmark")
                            .font(.caption2.bold())
                            .foregroundStyle((hex == "#FFFFFF" || hex == "#FFD60A") ? .black : .white)
                    }
                }
        }
        .buttonStyle(.plain)
    }

    private func widthDot(_ width: Double) -> some View {
        let selected = abs(controller.toolState.width - width) < 0.5
        return Button {
            Haptics.selection()
            controller.toolState.width = width
        } label: {
            Circle()
                .fill(selected ? Color.accentColor : Color.primary.opacity(0.7))
                // Dot diameter tracks the stroke width it sets (8…22pt).
                .frame(width: 6 + width, height: 6 + width)
                .frame(width: 26, height: 26)
                .background {
                    if selected {
                        Circle().fill(Color.accentColor.opacity(0.16))
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("tool.width"))
        .accessibilityValue(Text("\(Int(width))"))
    }
}

/// Inline lasso options: arm freeform or rectangle select-and-rotate.
private struct LassoOptionsStrip: View {
    var horizontal = true
    /// Called with `true` for rectangle mode, `false` for freeform.
    var onSelect: (Bool) -> Void

    var body: some View {
        let layout = horizontal ? AnyLayout(HStackLayout(spacing: 10)) : AnyLayout(VStackLayout(spacing: 10))
        layout {
            modeButton(symbol: "lasso", labelKey: "tool.lasso.freeform", rectangular: false)
            modeButton(symbol: "rectangle.dashed", labelKey: "tool.lasso.rect", rectangular: true)
        }
        .padding(.horizontal, horizontal ? 12 : 6)
        .padding(.vertical, horizontal ? 6 : 12)
    }

    private func modeButton(symbol: String, labelKey: LocalizedStringKey, rectangular: Bool) -> some View {
        Button {
            Haptics.selection()
            onSelect(rectangular)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color.primary)
                .frame(width: 30, height: 30)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(labelKey))
    }
}

/// Inline eraser options: pixel/object mode and (for pixel) eraser size.
/// Runs along the same axis as the bar it belongs to.
private struct EraserOptionsStrip: View {
    @ObservedObject var controller: CanvasController
    var horizontal = true

    private static let widths: [Double] = [8, 16, 28]

    var body: some View {
        let layout = horizontal ? AnyLayout(HStackLayout(spacing: 10)) : AnyLayout(VStackLayout(spacing: 10))
        layout {
            // Icon buttons instead of a segmented picker: they stack along
            // either axis without forcing a wide control onto a vertical bar.
            modeButton(.eraserPixel)
            modeButton(.eraserObject)

            if controller.toolState.kind == .eraserPixel {
                Divider().frame(
                    maxWidth: horizontal ? nil : 22,
                    maxHeight: horizontal ? 22 : nil
                )
                ForEach(Self.widths, id: \.self) { width in
                    sizeDot(width)
                }
            }
        }
        .padding(.horizontal, horizontal ? 12 : 6)
        .padding(.vertical, horizontal ? 6 : 12)
    }

    private func modeButton(_ kind: ToolKind) -> some View {
        let isActive = controller.toolState.kind == kind
        return Button {
            guard !isActive else { return }
            Haptics.selection()
            controller.select(kind)
        } label: {
            Image(systemName: kind.symbolName)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(isActive ? Color.accentColor : Color.primary)
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isActive ? Color.accentColor.opacity(0.16) : .clear)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(kind.labelKey))
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    private func sizeDot(_ width: Double) -> some View {
        let selected = abs(controller.toolState.width - width) < 0.5
        return Button {
            Haptics.selection()
            controller.toolState.width = width
        } label: {
            Circle()
                .strokeBorder(selected ? Color.accentColor : Color.secondary, lineWidth: 2)
                .frame(width: 8 + width / 2, height: 8 + width / 2)
                .frame(width: 28, height: 28)
                .background {
                    if selected {
                        Circle().fill(Color.accentColor.opacity(0.16))
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("tool.eraserSize"))
        .accessibilityValue(Text("\(Int(width))"))
    }
}

struct ToolbarExtraItem: Identifiable {
    let id: String
    let symbolName: String
    let labelKey: LocalizedStringKey
    let action: () -> Void
}

private struct ToolbarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .medium))
            .frame(width: 34, height: 34)
            .background(configuration.isPressed ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
    }
}

/// Options for the active tool: color presets, custom color, width, opacity —
/// writing straight through the controller so changes always reach the canvas.
struct ToolOptionsPanel: View {
    @ObservedObject var controller: CanvasController
    var onClose: () -> Void = {}
    @State private var customColor: Color = .black

    private static let presets = [
        "#000000", "#FFFFFF", "#0A84FF", "#FF453A", "#30D158",
        "#FFD60A", "#FF9F0A", "#BF5AF2", "#5E5CE6", "#8E8E93",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: controller.toolState.kind.symbolName)
                    .foregroundStyle(Color.accentColor)
                Text(controller.toolState.kind.labelKey)
                    .font(.headline)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel(Text("action.close"))
            }

            LazyVGrid(columns: Array(repeating: GridItem(.fixed(34)), count: 5), spacing: 10) {
                ForEach(Self.presets, id: \.self) { hex in
                    Button {
                        Haptics.selection()
                        controller.toolState.colorHex = hex
                    } label: {
                        Circle()
                            .fill(Color(hex: hex) ?? .black)
                            .frame(width: 30, height: 30)
                            .overlay(Circle().strokeBorder(.quaternary))
                            .overlay {
                                if controller.toolState.colorHex == hex {
                                    Image(systemName: "checkmark")
                                        .font(.caption.bold())
                                        .foregroundStyle((hex == "#FFFFFF" || hex == "#FFD60A") ? .black : .white)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                }
            }

            ColorPicker("tool.customColor", selection: $customColor, supportsOpacity: false)
                .onChange(of: customColor) { _, newValue in
                    controller.toolState.colorHex = UIColor(newValue).hexString
                }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("tool.width").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    // Live stroke preview at the chosen width and color.
                    Capsule()
                        .fill(Color(hex: controller.toolState.colorHex) ?? .black)
                        .frame(width: 56, height: min(max(controller.toolState.width, 2), 20))
                }
                Slider(value: $controller.toolState.width, in: 1...24)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("tool.opacity").font(.caption).foregroundStyle(.secondary)
                Slider(value: $controller.toolState.opacity, in: 0.1...1)
            }
        }
        .padding(16)
        .frame(width: 260)
        .onAppear { customColor = Color(hex: controller.toolState.colorHex) ?? .black }
    }
}

/// Lets the user choose which tools appear on the toolbar.
struct CustomizeToolbarSheet: View {
    @Binding var enabledToolsRaw: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            // One eraser slot — pixel/object is an inline toggle, not two buttons.
            List(ToolKind.allCases.filter { $0 != .eraserObject }) { kind in
                Toggle(isOn: binding(for: kind)) {
                    Label { Text(kind.labelKey) } icon: { Image(systemName: kind.symbolName) }
                }
            }
            .navigationTitle(Text("toolbar.customize"))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("action.done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func binding(for kind: ToolKind) -> Binding<Bool> {
        Binding(
            get: { enabledToolsRaw.split(separator: ",").contains(Substring(kind.rawValue)) },
            set: { include in
                var set = enabledToolsRaw.split(separator: ",").map(String.init)
                if include, !set.contains(kind.rawValue) {
                    set.append(kind.rawValue)
                } else if !include {
                    set.removeAll { $0 == kind.rawValue }
                }
                // Keep canonical tool order regardless of toggle order.
                enabledToolsRaw = ToolKind.allCases.map(\.rawValue).filter(set.contains).joined(separator: ",")
            }
        )
    }
}
