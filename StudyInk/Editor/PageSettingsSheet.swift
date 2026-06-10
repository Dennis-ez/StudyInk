import SwiftUI

/// Per-page template and size settings. Each page keeps its own background;
/// "apply to all" stamps the choice across the note.
struct PageSettingsSheet: View {
    @ObservedObject var page: Page
    @Environment(\.dismiss) private var dismiss
    @State private var importingPDF = false

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
                        Picker("page.spacing", selection: spacingBinding) {
                            Text("page.spacing.compact").tag(0.75)
                            Text("page.spacing.normal").tag(1.0)
                            Text("page.spacing.wide").tag(1.4)
                        }
                        .pickerStyle(.segmented)
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

    private var spacingBinding: Binding<Double> {
        Binding(
            get: {
                // Snap stored value to the nearest preset so the picker always selects.
                let value = page.templateSpacing > 0 ? page.templateSpacing : 1.0
                return [0.75, 1.0, 1.4].min { abs($0 - value) < abs($1 - value) } ?? 1.0
            },
            set: {
                page.templateSpacing = $0
                page.note?.touch()
                PersistenceController.shared.save()
            }
        )
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
