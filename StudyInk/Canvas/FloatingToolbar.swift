import SwiftUI

enum ToolbarDock: String, CaseIterable, Codable {
    case top, bottom, leading, trailing
    var isHorizontal: Bool { self == .top || self == .bottom }
}

/// Floating, repositionable toolbar. Drag the grip toward a screen edge to re-dock;
/// the visible tool set is user-customizable and persisted.
struct FloatingToolbar: View {
    @ObservedObject var controller: CanvasController
    @AppStorage("toolbar.dock") private var dockRaw = ToolbarDock.top.rawValue
    @AppStorage("toolbar.tools") private var enabledToolsRaw = ToolKind.allCases.map(\.rawValue).joined(separator: ",")
    @State private var showColorPopover = false
    @State private var showCustomize = false
    /// Re-tapping the active tool opens its own color/width/opacity popover.
    @State private var optionsForTool: ToolKind?
    @State private var dragOffset: CGSize = .zero
    @Environment(\.colorScheme) private var colorScheme

    var onInsertTextBox: () -> Void
    var extraItems: [ToolbarExtraItem] = []

    private var dock: ToolbarDock { ToolbarDock(rawValue: dockRaw) ?? .top }
    private var enabledTools: [ToolKind] {
        enabledToolsRaw.split(separator: ",").compactMap { ToolKind(rawValue: String($0)) }
    }

    var body: some View {
        GeometryReader { geo in
            content
                .offset(dragOffset)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
                .padding(12)
                .animation(.spring(response: 0.3, dampingFraction: 0.8), value: dockRaw)
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

    @ViewBuilder
    private var content: some View {
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
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
        .buttonStyle(ToolbarButtonStyle())
        .padding(8)
        .background(toolbarBackground)
        .sheet(isPresented: $showCustomize) { CustomizeToolbarSheet(enabledToolsRaw: $enabledToolsRaw) }
    }

    private var grip: some View {
        Image(systemName: "line.3.horizontal")
            .foregroundStyle(.tertiary)
            .rotationEffect(dock.isHorizontal ? .zero : .degrees(90))
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
                // Second tap on the active tool = open its options.
                if kind.isInking { optionsForTool = kind }
            } else {
                Haptics.selection()
                controller.select(kind)
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
        .popover(isPresented: optionsBinding(for: kind)) {
            ColorPickerPopover(toolState: $controller.toolState)
        }
        .accessibilityLabel(Text(kind.labelKey))
        .accessibilityHint(controller.toolState.kind == kind ? Text("tool.optionsHint") : Text(""))
        .accessibilityAddTraits(controller.toolState.kind == kind ? .isSelected : [])
    }

    private func optionsBinding(for kind: ToolKind) -> Binding<Bool> {
        Binding(
            get: { optionsForTool == kind },
            set: { if !$0 { optionsForTool = nil } }
        )
    }

    private var colorButton: some View {
        Button { showColorPopover = true } label: {
            Circle()
                .fill(Color(hex: controller.toolState.colorHex) ?? .black)
                .frame(width: 22, height: 22)
                .overlay(Circle().strokeBorder(.quaternary))
        }
        .accessibilityLabel(Text("tool.color"))
        .popover(isPresented: $showColorPopover) {
            ColorPickerPopover(toolState: $controller.toolState)
        }
    }

    /// Light mode floats on a soft shadow; dark mode uses an inner border instead,
    /// matching Notability's toolbar treatment.
    private var toolbarBackground: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(SemanticColor.toolbarBackground.opacity(0.92))
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(SemanticColor.toolbarBorder, lineWidth: colorScheme == .dark ? 1 : 0.5)
            )
            .shadow(
                color: colorScheme == .dark ? .clear : .black.opacity(0.12),
                radius: 8, y: 2
            )
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

/// Color presets + system picker + opacity & width sliders.
struct ColorPickerPopover: View {
    @Binding var toolState: ToolState
    @State private var customColor: Color = .black

    private static let presets = [
        "#000000", "#FFFFFF", "#0A84FF", "#FF453A", "#30D158",
        "#FFD60A", "#FF9F0A", "#BF5AF2", "#5E5CE6", "#8E8E93",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(34)), count: 5), spacing: 10) {
                ForEach(Self.presets, id: \.self) { hex in
                    Button {
                        toolState.colorHex = hex
                    } label: {
                        Circle()
                            .fill(Color(hex: hex) ?? .black)
                            .frame(width: 30, height: 30)
                            .overlay(Circle().strokeBorder(.quaternary))
                            .overlay {
                                if toolState.colorHex == hex {
                                    Image(systemName: "checkmark")
                                        .font(.caption.bold())
                                        .foregroundStyle((Color(hex: hex) == .white || hex == "#FFD60A") ? .black : .white)
                                }
                            }
                    }
                }
            }
            ColorPicker("tool.customColor", selection: $customColor, supportsOpacity: false)
                .onChange(of: customColor) { _, newValue in
                    toolState.colorHex = UIColor(newValue).hexString
                }
            VStack(alignment: .leading, spacing: 4) {
                Text("tool.opacity")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Slider(value: $toolState.opacity, in: 0.1...1)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("tool.width")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Slider(value: $toolState.width, in: 1...24)
            }
        }
        .padding(16)
        .frame(width: 240)
        .onAppear { customColor = Color(hex: toolState.colorHex) ?? .black }
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
