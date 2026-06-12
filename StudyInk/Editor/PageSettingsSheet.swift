import SwiftUI

/// Per-page template and size settings. Each page keeps its own background;
/// "apply to all" stamps the choice across the note.
struct PageSettingsSheet: View {
    @ObservedObject var page: Page
    @Environment(\.dismiss) private var dismiss
    @State private var importingPDF = false
    @State private var spacingValue = 1.0
    @State private var showSpacingPopover = false
    @State private var savedFavorite = false

    // Must track the swatch width (120) — smaller columns overlap the cells.
    private let grid = [GridItem(.adaptive(minimum: 120), spacing: 16)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("page.template")
                        .font(.headline)
                    LazyVGrid(columns: grid, spacing: 14) {
                        ForEach(PageTemplate.allCases.filter { $0 != .customPDF }) { template in
                            templateSwatch(template)
                        }
                        Button { importingPDF = true } label: {
                            VStack(spacing: 6) {
                                Image(systemName: "doc.badge.plus").font(.title2)
                                Text("template.customPDF").font(.caption2)
                            }
                            .frame(width: 96, height: 110)
                            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
                            .overlay {
                                if page.template == .customPDF {
                                    RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor, lineWidth: 2)
                                }
                            }
                        }
                    }

                    Text("page.size")
                        .font(.headline)
                    Picker("page.size", selection: sizeBinding) {
                        Text("page.size.letter").tag(PageSize.letter)
                        Text("page.size.a4").tag(PageSize.a4)
                        Text("page.size.screen").tag(PageSize.screen)
                        Text("page.size.custom").tag(PageSize.custom)
                    }
                    .pickerStyle(.segmented)

                    Button {
                        applyToAllPages()
                    } label: {
                        Label("page.applyToAll", systemImage: "square.on.square")
                    }
                    .buttonStyle(.bordered)
                }
                .padding(20)
            }
            .navigationTitle(Text("page.settings"))
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    // Stamp this template + spacing as the default for new notes.
                    Button {
                        UserDefaults.standard.set(page.templateID ?? "blank", forKey: "settings.defaultTemplate")
                        UserDefaults.standard.set(page.templateSpacing > 0 ? page.templateSpacing : 1.0, forKey: "settings.defaultTemplateSpacing")
                        withAnimation { savedFavorite = true }
                        Haptics.success()
                    } label: {
                        Label("page.saveFavorite", systemImage: savedFavorite ? "star.fill" : "star")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("action.done") { dismiss() }
                }
            }
            .onAppear { spacingValue = page.templateSpacing > 0 ? page.templateSpacing : 1.0 }
            .fileImporter(isPresented: $importingPDF, allowedContentTypes: [.pdf]) { result in
                if case .success(let url) = result {
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    if let data = try? Data(contentsOf: url) {
                        PDFImporter.importAsTemplate(data: data, for: page)
                        PersistenceController.shared.save()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func commitSpacing() {
        page.templateSpacing = spacingValue
        page.note?.touch()
        PersistenceController.shared.save()
    }

    private var sizeBinding: Binding<PageSize> {
        Binding(
            get: { PageSize.from(id: page.pageSizeID) },
            set: { page.pageSizeID = $0.rawValue; page.note?.touch(); PersistenceController.shared.save() }
        )
    }

    private func templateSwatch(_ template: PageTemplate) -> some View {
        let isSelected = page.template == template
        let hasSpacing = template != .blank && template != .customPDF
        return Button {
            page.templateID = template.rawValue
            page.customTemplatePDF = nil
            page.note?.touch()
            PersistenceController.shared.save()
        } label: {
            VStack(spacing: 6) {
                Canvas { ctx, size in
                    ctx.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 8), with: .color(Color("canvasBackground")))
                    template.draw(
                        in: &ctx,
                        rect: CGRect(origin: .zero, size: size),
                        scale: 0.28,
                        lineColor: Color("templateLine"),
                        accentColor: Color("accentBlue"),
                        // The selected swatch IS the spacing preview.
                        spacing: isSelected ? spacingValue : 1
                    )
                }
                .frame(width: 120, height: 104)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                // ⋯ pinned to the THUMBNAIL's corner, clear of the label.
                .overlay(alignment: .bottomTrailing) {
                    if isSelected && hasSpacing {
                        Button {
                            showSpacingPopover = true
                        } label: {
                            Image(systemName: "ellipsis.circle.fill")
                                .font(.title3)
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, Color.accentColor)
                                .background(Circle().fill(.background))
                        }
                        .buttonStyle(.plain)
                        .padding(5)
                        .accessibilityLabel(Text("page.spacing"))
                        .popover(isPresented: $showSpacingPopover, arrowEdge: .bottom) {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text("page.spacing").font(.headline)
                                    Spacer()
                                    Text(verbatim: String(format: "%.2f×", spacingValue))
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                                Slider(value: $spacingValue, in: 0.6...1.8) { editing in
                                    // The swatch previews every tick; the real page
                                    // rebuilds only on release.
                                    if !editing { commitSpacing() }
                                }
                            }
                            .padding(16)
                            .frame(width: 280)
                            .presentationCompactAdaptation(.popover)
                        }
                    }
                }
                Text(template.labelKey).font(.caption2)
            }
            .frame(width: 120, height: 134)
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor, lineWidth: 2)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func applyToAllPages() {
        guard let note = page.note else { return }
        for other in note.sortedPages where other != page {
            other.templateID = page.templateID
            other.templateSpacing = page.templateSpacing
            other.pageSizeID = page.pageSizeID
            other.customTemplatePDF = page.customTemplatePDF
        }
        note.touch()
        PersistenceController.shared.save()
    }
}
