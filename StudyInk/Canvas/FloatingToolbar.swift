import SwiftUI

enum ToolbarDock: String, CaseIterable, Codable {
    case top, bottom, leading, trailing
    var isHorizontal: Bool { self == .top || self == .bottom }
}

/// Floating, repositionable glass toolbar. Drag the grip toward a screen edge
/// to re-dock; the visible tool set is user-customizable and persisted.
/// Re-tapping the active inking tool (or tapping the color swatch) opens that
/// tool's options panel; re-tapping the lasso arms select-and-rotate.
struct FloatingToolbar: View {
    @ObservedObject var controller: CanvasController
    @AppStorage("toolbar.dock") private var dockRaw = ToolbarDock.top.rawValue
    @AppStorage("toolbar.tools") private var enabledToolsRaw = ToolKind.allCases.map(\.rawValue).joined(separator: ",")
    @State private var showToolOptions = false
    @State private var showCustomize = false
    @State private var dragOffset: CGSize = .zero
    @Environment(\.colorScheme) private var colorScheme

    var onInsertTextBox: () -> Void
    /// Re-tapping the lasso tool arms select-and-rotate.
    var onTransformSelection: () -> Void = {}
    var extraItems: [ToolbarExtraItem] = []

    private var dock: ToolbarDock { ToolbarDock(rawValue: dockRaw) ?? .top }
    private var enabledTools: [ToolKind] {
        enabledToolsRaw.split(separator: ",").compactMap { ToolKind(rawValue: String($0)) }
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // While the options panel is open, the first tap anywhere
                // outside it dismisses (popover behavior).
                if showToolOptions {
                    Color.clear
                        .contentShape(Rectangle())
                        .ignoresSafeArea()
                        .onTapGesture {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { showToolOptions = false }
                        }
                }
                content
                    .offset(dragOffset)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
                    .padding(12)
                    .animation(.spring(response: 0.3, dampingFraction: 0.8), value: dockRaw)
            }
        }
        .allowsHitTesting(true)
    }

    private var alignment: Alignment {
        switch dock {
        case .top: return .top
        case .bottom: return .bottom
        case .leading: return .leading
        case .trailing: return .trailing
        }
    }

    /// The bar plus (when open) its inline options panel — no UIKit popover,
    /// which mis-anchored inside the floating/draggable bar.
    @ViewBuilder
    private var content: some View {
        switch dock {
        case .top:
            VStack(spacing: 8) { bar; optionsPanelIfNeeded }
        case .bottom:
            VStack(spacing: 8) { optionsPanelIfNeeded; bar }
        case .leading:
            HStack(alignment: .top, spacing: 8) { bar; optionsPanelIfNeeded }
        case .trailing:
            HStack(alignment: .top, spacing: 8) { optionsPanelIfNeeded; bar }
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
            ForEach(enabledTools) { kind in
                toolButton(kind)
            }
            Divider().frame(maxHeight: 22).frame(maxWidth: 22)
            colorButton
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
            Button(action: controller.undo) {
                Image(systemName: "arrow.uturn.backward")
            }
            .disabled(!controller.canUndo)
            .accessibilityLabel(Text("action.undo"))
            Button(action: controller.redo) {
                Image(systemName: "arrow.uturn.forward")
            }
            .disabled(!controller.canRedo)
            .accessibilityLabel(Text("action.redo"))
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
            .gesture(
                DragGesture(coordinateSpace: .global)
                    .onChanged { dragOffset = $0.translation }
                    .onEnded { value in
                        dragOffset = .zero
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
        Button {
            if controller.toolState.kind == kind {
                // Second tap on the active tool = toggle its options.
                if kind.isInking {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { showToolOptions.toggle() }
                } else if kind == .lasso {
                    onTransformSelection()
                }
            } else {
                Haptics.selection()
                controller.select(kind)
                // Eraser/lasso have no color options — a stale open panel
                // would show the previous pen's colors.
                if !kind.isInking, showToolOptions {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { showToolOptions = false }
                }
            }
        } label: {
            Image(systemName: kind.symbolName)
                .foregroundStyle(controller.toolState.kind == kind ? Color.accentColor : Color.primary)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(controller.toolState.kind == kind ? Color.accentColor.opacity(0.16) : .clear)
                        .frame(width: 32, height: 32)
                )
        }
        .accessibilityLabel(Text(kind.labelKey))
        .accessibilityHint(controller.toolState.kind == kind ? Text("tool.optionsHint") : Text(""))
        .accessibilityAddTraits(controller.toolState.kind == kind ? .isSelected : [])
    }

    private var colorButton: some View {
        Button {
            if !controller.toolState.kind.isInking {
                controller.select(.ballpoint)
            }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { showToolOptions.toggle() }
        } label: {
            Circle()
                .fill(Color(hex: controller.toolState.colorHex) ?? .black)
                .frame(width: 22, height: 22)
                .overlay(Circle().strokeBorder(.quaternary))
        }
        .accessibilityLabel(Text("tool.color"))
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
            List(ToolKind.allCases) { kind in
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
