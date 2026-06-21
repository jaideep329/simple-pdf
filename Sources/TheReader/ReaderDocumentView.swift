import SwiftUI

struct ReaderDocumentView: View {
    @EnvironmentObject private var store: ReaderStore
    @State private var columnVisibility = NavigationSplitViewVisibility.detailOnly

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            PDFOutlineSidebar()
                .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 380)
        } detail: {
            HStack(spacing: 0) {
                PDFPanel()
                    .navigationTitle(store.displayTitle)

                if store.activeCommentThread != nil {
                    Divider()
                    CommentThreadPanel()
                        .frame(width: 340)
                }
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    store.openPDF()
                } label: {
                    Label("Open PDF", systemImage: "doc.badge.plus")
                }

                Text(store.currentPageText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 72)
            }

            ToolbarItemGroup {
                Button {
                    store.addPDFNote()
                } label: {
                    Image(systemName: "note.text.badge.plus")
                }
                .help("Add Note")
                .disabled(store.document == nil)

                Button {
                    store.isRegionCommentMode.toggle()
                } label: {
                    Image(systemName: store.isRegionCommentMode ? "viewfinder.circle.fill" : "viewfinder")
                }
                .help("Ask about a region — drag a box over a figure/equation")
                .disabled(store.document == nil)
            }

            ToolbarItemGroup {
                Button {
                    store.zoomOut()
                } label: {
                    Image(systemName: "minus.magnifyingglass")
                }
                .help("Zoom Out")
                .disabled(store.document == nil)

                Text(store.zoomPercentText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 44)

                Button {
                    store.zoomIn()
                } label: {
                    Image(systemName: "plus.magnifyingglass")
                }
                .help("Zoom In")
                .disabled(store.document == nil)

                Button {
                    store.fitPage()
                } label: {
                    Image(systemName: "rectangle.dashed")
                }
                .help("Fit Page")
                .disabled(store.document == nil)
            }
        }
        .alert(
            "Simple PDF",
            isPresented: Binding(
                get: { store.errorMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        store.errorMessage = nil
                    }
                }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.errorMessage ?? "")
        }
        .onOpenURL { url in
            if url.isFileURL, url.pathExtension.lowercased() == "pdf" {
                store.loadPDF(at: url)
            } else {
                store.openReaderURL(url)
            }
        }
    }
}

private struct PDFOutlineSidebar: View {
    @EnvironmentObject private var store: ReaderStore

    var body: some View {
        List {
            if store.document == nil {
                SidebarPlaceholder(
                    systemImage: "doc.richtext",
                    title: "No PDF Open",
                    detail: "Open a PDF to see its outline."
                )
            } else if store.outlineItems.isEmpty {
                SidebarPlaceholder(
                    systemImage: "list.bullet.rectangle",
                    title: "No Outline",
                    detail: "This PDF does not include table-of-contents metadata."
                )
            } else {
                OutlineGroup(store.outlineItems, children: \.outlineChildren) { item in
                    PDFOutlineRow(item: item)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Contents")
    }
}

private struct PDFOutlineRow: View {
    @EnvironmentObject private var store: ReaderStore
    let item: PDFOutlineItem

    private var isCurrent: Bool {
        store.currentOutlineItemID == item.id
    }

    var body: some View {
        Button {
            store.goToOutlineItem(item)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: item.pageIndex == nil ? "folder" : "doc.text")
                    .foregroundStyle(.secondary)
                    .frame(width: 15)

                Text(item.title)
                    .lineLimit(1)
                    .fontWeight(isCurrent ? .semibold : .regular)

                Spacer(minLength: 6)

                if let pageIndex = item.pageIndex {
                    Text("\(pageIndex + 1)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(item.pageIndex == nil)
    }
}

private struct SidebarPlaceholder: View {
    let systemImage: String
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(.secondary)

            Text(title)
                .font(.headline)

            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 12)
    }
}

private struct PDFPanel: View {
    @EnvironmentObject private var store: ReaderStore

    var body: some View {
        Group {
            if store.document == nil {
                EmptyPDFView()
            } else {
                PDFReaderView(store: store)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct EmptyPDFView: View {
    @EnvironmentObject private var store: ReaderStore

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.richtext")
                .font(.system(size: 44, weight: .regular))
                .foregroundStyle(.secondary)

            Button {
                store.openPDF()
            } label: {
                Label("Open PDF", systemImage: "doc.badge.plus")
            }
            .modernProminentButton()
        }
        .modernEmptyStateSurface()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}

private extension View {
    @ViewBuilder
    func modernProminentButton() -> some View {
        if #available(macOS 26.0, *) {
            buttonStyle(.glassProminent)
        } else {
            buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    func modernEmptyStateSurface() -> some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)

        if #available(macOS 26.0, *) {
            padding(28)
                .glassEffect(.regular, in: shape)
        } else {
            padding(28)
                .background(.regularMaterial, in: shape)
        }
    }
}
