import SwiftUI

/// Per-page template and size settings. Each page keeps its own background;
/// "apply to all" stamps the choice across the note.
struct PageSettingsSheet: View {
    @ObservedObject var page: Page
    @Environment(\.dismiss) private var dismiss
    @State private var importingPDF = false
    @State private var spacingValue = 1.0

    private let grid = [GridItem(.adaptive(minimum: 96), spacing: 14)]

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

                    if page.template != .blank && page.template != .customPDF {
                        Text("page.spacing")
                            .font(.headline)
                        HStack(spacing: 16) {
                            // Live preview: the thumbnail re-renders at every step,
                            // the real page only on commit.
                            Canvas { ctx, size in
                                ctx.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 8), with: .color(Color("canvasBackground")))
                                page.template.draw(
                                    in: &ctx,
                                    rect: CGRect(origin: .zero, size: size),
                                    scale: 0.22,
                                    lineColor: Color("templateLine"),
                                    accentColor: Color("accentBlue"),
                                    spacing: spacingValue
                                )
                            }
                            .frame(width: 96, height: 84)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))

                            VStack(alignment: .leading, spacing: 6) {
                                Stepper(value: $spacingValue, in: 0.6...1.8, step: 0.1) {
                                    Text(verbatim: String(format: "%.1f×", spacingValue))
                                        .font(.body.monospacedDigit())
                                } onEditingChanged: { editing in
                                    // Commit on release: each change rebuilds the
                                    // page stack, so live-commit would stutter.
                                    if !editing { commitSpacing() }
                                }
                                Text("page.spacing.hint")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
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
        Button {
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
                        scale: 0.22,
                        lineColor: Color("templateLine"),
                        accentColor: Color("accentBlue")
                    )
                }
                .frame(width: 96, height: 84)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                Text(template.labelKey).font(.caption2)
            }
            .frame(width: 96, height: 110)
            .overlay {
                if page.template == template {
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
