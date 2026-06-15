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
    /// Removable non-tool buttons: ruler, text box, and the editor's extras.
    @AppStorage("toolbar.accessories") private var enabledAccessoriesRaw = "ruler,textbox,ask-ai,ai-history"
    /// The quick strip (colors/sizes) — opened by re-tapping the active tool.
    @State private var showInlineOptions = false
    /// Measured bar size — the dock placeholders mirror it.
    @State private var barSize: CGSize = .zero
    @State private var showCustomize = false
    @State private var dragOffset: CGSize = .zero
    /// Global finger position while the grip is being dragged; drives the
    /// edge indicators that show where the bar can dock.
    @State private var gripDragLocation: CGPoint?
    @Environment(\.colorScheme) private var colorScheme

    var onInsertTextBox: () -> Void
    /// Re-arms select-and-rotate (lasso re-tap; selecting the lasso arms it
    /// automatically via the editor).
    var onTransformSelection: () -> Void = {}
    var extraItems: [ToolbarExtraItem] = []
    /// Extra trailing inset so a trailing-docked bar isn't covered by the
    /// page-navigator strip.
    var trailingInset: CGFloat = 0

    private var dock: ToolbarDock { ToolbarDock(rawValue: dockRaw) ?? .top }
    private var enabledTools: [ToolKind] {
        enabledToolsRaw.split(separator: ",").compactMap { ToolKind(rawValue: String($0)) }
    }
    private var enabledAccessories: Set<String> {
        Set(enabledAccessoriesRaw.split(separator: ",").map(String.init))
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
                // NOTE: no full-screen tap catcher here — it blocked the
                // first pen stroke while the strip was open. The strip closes
                // via re-tap, tool switch, or the drawing-gesture token below
                // (start writing → strip closes AND the stroke lands).
                if let location = gripDragLocation {
                    dockIndicators(highlighting: nearestDock(for: location))
                }
                content
                    .offset(dragOffset)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: dock.alignment)
                    .padding(12)
                    // Step aside when the pages strip shares the trailing edge.
                    .padding(.trailing, dock == .trailing ? trailingInset : 0)
                    .animation(.spring(response: 0.3, dampingFraction: 0.8), value: dockRaw)
                    .animation(.spring(response: 0.3, dampingFraction: 0.8), value: trailingInset)
            }
        }
        .allowsHitTesting(true)
        // Writing on the page closes the color/options strip.
        .onChange(of: controller.drawingGestureBeganToken) { _, _ in
            if showInlineOptions {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { showInlineOptions = false }
            }
        }
    }

    /// Bar-shaped placeholders at every edge while the grip is dragged — each
    /// previews the bar's actual footprint there; the snap target lights up.
    private func dockIndicators(highlighting target: ToolbarDock) -> some View {
        ZStack {
            ForEach(ToolbarDock.allCases, id: \.self) { edge in
                let size = placeholderSize(for: edge)
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(
                        edge == target ? Color.accentColor : Color.secondary.opacity(0.35),
                        style: StrokeStyle(lineWidth: 2, dash: [7, 5])
                    )
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color.accentColor.opacity(edge == target ? 0.10 : 0))
                    )
                    .frame(width: size.width, height: size.height)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: edge.alignment)
                    .padding(12)
                    .animation(.easeOut(duration: 0.15), value: target)
            }
        }
        .allowsHitTesting(false)
        .transition(.opacity)
    }

    /// The bar's measured size, transposed for edges of the other orientation.
    private func placeholderSize(for edge: ToolbarDock) -> CGSize {
        let measured = barSize == .zero ? CGSize(width: 330, height: 42) : barSize
        if edge.isHorizontal == dock.isHorizontal { return measured }
        return CGSize(width: measured.height, height: measured.width)
    }

    /// The bar plus (when open) its inline options strip — no UIKit popover,
    /// which mis-anchored inside the floating/draggable bar.
    @ViewBuilder
    private var content: some View {
        switch dock {
        case .top:
            VStack(spacing: 8) { bar; inlineStrip }
        case .bottom:
            VStack(spacing: 8) { inlineStrip; bar }
        case .leading:
            HStack(alignment: .top, spacing: 8) { bar; inlineStrip }
        case .trailing:
            HStack(alignment: .top, spacing: 8) { inlineStrip; bar }
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
                InkOptionsStrip(controller: controller, horizontal: dock.isHorizontal)
                    .studyGlass(cornerRadius: 18)
                    .transition(.scale(scale: 0.92, anchor: dock == .bottom ? .bottom : .top).combined(with: .opacity))
            } else if kind == .eraserPixel || kind == .eraserObject {
                EraserOptionsStrip(controller: controller, horizontal: dock.isHorizontal)
                    .studyGlass(cornerRadius: 18)
                    .transition(.scale(scale: 0.92, anchor: dock == .bottom ? .bottom : .top).combined(with: .opacity))
            } else if kind == .lasso {
                LassoOptionsStrip(controller: controller, horizontal: dock.isHorizontal)
                    .studyGlass(cornerRadius: 18)
                    .transition(.scale(scale: 0.92, anchor: dock == .bottom ? .bottom : .top).combined(with: .opacity))
            }
        }
    }

    @ViewBuilder
    private var bar: some View {
        let layout = dock.isHorizontal
            ? AnyLayout(HStackLayout(spacing: 6))
            : AnyLayout(VStackLayout(spacing: 6))

        layout {
            grip
            toolsSection
            if !enabledAccessories.isEmpty {
                Divider().frame(maxHeight: 22).frame(maxWidth: 22)
            }
            if enabledAccessories.contains("ruler") {
                Button(action: { controller.isRulerActive.toggle() }) {
                    Image(systemName: "ruler")
                        .symbolVariant(controller.isRulerActive ? .fill : .none)
                }
                .accessibilityLabel(Text("tool.ruler"))
            }
            if enabledAccessories.contains("textbox") {
                Button(action: onInsertTextBox) {
                    Image(systemName: "textbox")
                }
                .accessibilityLabel(Text("tool.textbox"))
            }
            ForEach(extraItems.filter { enabledAccessories.contains($0.id) }) { item in
                Button(action: item.action) {
                    Image(systemName: item.symbolName)
                        // The AI pen wears the AI accent (teal), set apart from
                        // the ink tools.
                        .foregroundStyle(item.id == "ask-ai" ? AppTheme.current.aiAccent : Color.primary)
                }
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
        .padding(6)
        .studyGlass(cornerRadius: 16)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
            // Defer: writing state inside the layout pass trips "publishing
            // changes from within view updates".
            DispatchQueue.main.async { barSize = size }
        }
        .sheet(isPresented: $showCustomize) {
            CustomizeToolbarSheet(
                enabledToolsRaw: $enabledToolsRaw,
                accessories: accessoryDefs,
                enabledAccessoriesRaw: $enabledAccessoriesRaw
            )
        }
    }

    /// Non-tool bar buttons (ruler, text box, AI shortcuts) — all removable.
    private var accessoryDefs: [ToolbarAccessory] {
        [
            ToolbarAccessory(id: "ruler", symbolName: "ruler", labelKey: "tool.ruler"),
            ToolbarAccessory(id: "textbox", symbolName: "textbox", labelKey: "tool.textbox"),
        ] + extraItems.map { ToolbarAccessory(id: $0.id, symbolName: $0.symbolName, labelKey: $0.labelKey) }
    }

    /// At most five tool slots are visible; more tools scroll in page-sized
    /// steps along the bar's axis, keeping the bar itself compact.
    @ViewBuilder
    private var toolsSection: some View {
        let stack = dock.isHorizontal
            ? AnyLayout(HStackLayout(spacing: 4))
            : AnyLayout(VStackLayout(spacing: 4))
        let buttons = stack {
            ForEach(displayTools) { kind in
                toolButton(kind)
            }
        }
        if displayTools.count > 5 {
            // 5 × (30pt button + 4pt spacing) per "page" of tools.
            ScrollView(dock.isHorizontal ? .horizontal : .vertical, showsIndicators: false) {
                buttons
            }
            .frame(
                maxWidth: dock.isHorizontal ? 166 : nil,
                maxHeight: dock.isHorizontal ? nil : 166
            )
            .scrollTargetBehavior(.paging)
        } else {
            buttons
        }
    }

    private var grip: some View {
        Image(systemName: "line.3.horizontal")
            .foregroundStyle(.tertiary)
            // Full button-sized hit target — the bare glyph was ~16pt and
            // nearly impossible to grab.
            .frame(width: 30, height: 30)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(coordinateSpace: .global)
                    .onChanged { value in
                        dragOffset = value.translation
                        withAnimation(.easeOut(duration: 0.15)) { gripDragLocation = value.location }
                    }
                    .onEnded { value in
                        withAnimation(.easeOut(duration: 0.15)) { gripDragLocation = nil }
                        // One animated transaction: the bar glides from its
                        // dragged position into the new dock.
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            dragOffset = .zero
                            dockRaw = nearestDock(for: value.location).rawValue
                        }
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
                // (lasso's strip is the free/square shape selector).
                if hasOptions {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        showInlineOptions.toggle()
                    }
                }
            } else {
                Haptics.selection()
                controller.select(kind)
                // Options belong to the tool that was tapped twice — switching
                // tools always starts with them closed.
                if showInlineOptions {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        showInlineOptions = false
                    }
                }
            }
        } label: {
            let ink = controller.inkColor(for: kind)
            ZStack(alignment: .bottom) {
                Image(systemName: kind.symbolName)
                    // Ink tools wear their own color; others use the accent when active.
                    .foregroundStyle(ink ?? (isActive ? Color.accentColor : Color.primary))
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(isActive ? (ink ?? Color.accentColor).opacity(0.16) : .clear)
                            .frame(width: 28, height: 28)
                    )
                // Current-color indicator dot, centered under the tool.
                if let ink {
                    Circle()
                        .fill(ink)
                        .frame(width: 6, height: 6)
                        .overlay(Circle().strokeBorder(Color(.systemBackground), lineWidth: 1))
                        .offset(y: 5)
                }
            }
        }
        .accessibilityLabel(Text(kind.labelKey))
        .accessibilityHint(isActive ? Text("tool.optionsHint") : Text(""))
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

/// Inline quick options for inking tools: scrollable color dots, a custom-color
/// well, stroke-size dots, and a pressure toggle — the whole story, no second
/// panel. Runs along the same axis as the bar it belongs to.
private struct InkOptionsStrip: View {
    @ObservedObject var controller: CanvasController
    var horizontal = true
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

/// Inline eraser options: pixel/object mode and (for pixel) eraser size.
/// Runs along the same axis as the bar it belongs to.
/// Free-loop vs drag-rectangle selector for the lasso, shown when the lasso is
/// re-tapped — the shape choice lives here, not as an on-canvas toast.
private struct LassoOptionsStrip: View {
    @ObservedObject var controller: CanvasController
    var horizontal = true

    var body: some View {
        let layout = horizontal ? AnyLayout(HStackLayout(spacing: 8)) : AnyLayout(VStackLayout(spacing: 8))
        layout {
            modeButton(symbol: "lasso", labelKey: "tool.lasso.freeform", isRect: false)
            modeButton(symbol: "rectangle.dashed", labelKey: "tool.lasso.rect", isRect: true)
        }
        .padding(8)
    }

    private func modeButton(symbol: String, labelKey: LocalizedStringKey, isRect: Bool) -> some View {
        let selected = controller.lassoRectangular == isRect
        return Button {
            Haptics.selection()
            controller.lassoRectangular = isRect
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 7).fill(selected ? Color.accentColor.opacity(0.16) : .clear))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(labelKey))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

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
            .font(.system(size: 15, weight: .medium))
            .frame(width: 30, height: 30)
            .background(configuration.isPressed ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
    }
}

struct ToolbarAccessory: Identifiable {
    let id: String
    let symbolName: String
    let labelKey: LocalizedStringKey
}

/// Lets the user choose which tools AND accessory buttons appear on the bar.
struct CustomizeToolbarSheet: View {
    @Binding var enabledToolsRaw: String
    var accessories: [ToolbarAccessory] = []
    @Binding var enabledAccessoriesRaw: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section(header: Text("toolbar.section.tools")) {
                    // One eraser slot — pixel/object is an inline toggle, not two buttons.
                    ForEach(ToolKind.allCases.filter { $0 != .eraserObject }) { kind in
                        Toggle(isOn: binding(for: kind)) {
                            Label { Text(kind.labelKey) } icon: { Image(systemName: kind.symbolName) }
                        }
                    }
                }
                Section(header: Text("toolbar.section.accessories")) {
                    ForEach(accessories) { accessory in
                        Toggle(isOn: accessoryBinding(for: accessory.id)) {
                            Label { Text(accessory.labelKey) } icon: { Image(systemName: accessory.symbolName) }
                        }
                    }
                }
            }
            .navigationTitle(Text("toolbar.customize"))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("action.done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
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

    private func accessoryBinding(for id: String) -> Binding<Bool> {
        Binding(
            get: { enabledAccessoriesRaw.split(separator: ",").contains(Substring(id)) },
            set: { include in
                var set = enabledAccessoriesRaw.split(separator: ",").map(String.init)
                if include, !set.contains(id) {
                    set.append(id)
                } else if !include {
                    set.removeAll { $0 == id }
                }
                // Canonical order = the order the bar renders them in.
                enabledAccessoriesRaw = accessories.map(\.id).filter(set.contains).joined(separator: ",")
            }
        )
    }
}
