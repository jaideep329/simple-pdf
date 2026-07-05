import SwiftUI

struct ReaderDocumentView: View {
    @EnvironmentObject private var store: ReaderStore
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 400)
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

private struct SidebarView: View {
    @EnvironmentObject private var store: ReaderStore
    @State private var tab: SidebarTab = .contents
    @State private var query = ""
    @State private var bookHits: [MCPSearchHit] = []

    enum SidebarTab: String, CaseIterable, Identifiable {
        case contents, highlights, notes, comments
        var id: String { rawValue }
        var label: String {
            switch self {
            case .contents: return "Contents"
            case .highlights: return "Highlights"
            case .notes: return "Notes"
            case .comments: return "Comments"
            }
        }
        var symbol: String {
            switch self {
            case .contents: return "list.bullet"
            case .highlights: return "highlighter"
            case .notes: return "note.text"
            case .comments: return "text.bubble"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            GlassTabSwitcher(selection: $tab)
                .padding(.horizontal, 8)
                .padding(.top, 10)
                .padding(.bottom, 2)

            searchField
            Divider()
            content
        }
        .navigationTitle(tab.label)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.caption).foregroundStyle(.secondary)
            TextField(tab == .contents ? "Search book text & chapters" : "Search \(tab.label.lowercased())", text: $query)
                .textFieldStyle(.plain)
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Color.secondary.opacity(0.12), in: Capsule())
        .padding(8)
    }

    @ViewBuilder
    private var content: some View {
        if store.document == nil {
            VStack {
                SidebarPlaceholder(systemImage: "doc.richtext", title: "No PDF Open", detail: "Open a PDF to get started.")
                Spacer()
            }
        } else {
            switch tab {
            case .contents: contentsList
            case .highlights: highlightsList
            case .notes: notesList
            case .comments: commentsList
            }
        }
    }

    @ViewBuilder
    private var contentsList: some View {
        List {
            if query.isEmpty {
                if store.outlineItems.isEmpty {
                    SidebarPlaceholder(systemImage: "list.bullet.rectangle", title: "No Outline", detail: "This PDF has no table-of-contents metadata.")
                } else {
                    OutlineGroup(store.outlineItems, children: \.outlineChildren) { item in
                        PDFOutlineRow(item: item)
                    }
                }
            } else {
                let chapterMatches = flattenOutline(store.outlineItems).filter { $0.title.localizedCaseInsensitiveContains(query) }
                if !chapterMatches.isEmpty {
                    Section("Chapters") {
                        ForEach(chapterMatches) { item in
                            PDFOutlineRow(item: item)
                        }
                    }
                }

                Section("In the book") {
                    if bookHits.isEmpty {
                        emptyRow("No matches in the book text")
                    } else {
                        ForEach(Array(bookHits.enumerated()), id: \.offset) { _, hit in
                            Button { store.goToPage(number: hit.page) } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(hit.snippet)
                                        .font(.caption)
                                        .lineLimit(3)
                                    Text("p. \(hit.page)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        // Debounced full-text search of the PDF (same engine as the MCP
        // `search` tool); the outline filter above stays instant.
        .task(id: query) {
            guard !query.isEmpty else {
                bookHits = []
                return
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            bookHits = store.mcpSearch(query: query, limit: 50)
        }
    }

    @ViewBuilder
    private var highlightsList: some View {
        let items = store.sidebarHighlights().filter { query.isEmpty || $0.text.localizedCaseInsensitiveContains(query) }
        List {
            if items.isEmpty {
                emptyRow("No highlights yet")
            } else {
                ForEach(items, id: \.id) { highlight in
                    HighlightListRow(
                        highlight: highlight,
                        open: { store.goToPage(number: highlight.page) },
                        delete: { store.removeHighlight(id: highlight.id) }
                    )
                }
            }
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private var notesList: some View {
        let items = store.sidebarNotes().filter { query.isEmpty || $0.text.localizedCaseInsensitiveContains(query) }
        List {
            if items.isEmpty {
                emptyRow("No notes yet")
            } else {
                ForEach(items) { note in
                    Button { store.goToPage(number: note.page) } label: { NoteRow(note: note) }
                        .buttonStyle(.plain)
                }
            }
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private var commentsList: some View {
        let items = store.commentThreads.filter { thread in
            query.isEmpty
                || (thread.anchor.quote?.localizedCaseInsensitiveContains(query) ?? false)
                || thread.messages.contains { $0.body.localizedCaseInsensitiveContains(query) }
        }
        List {
            if items.isEmpty {
                emptyRow("No comments yet")
            } else {
                ForEach(items) { thread in
                    Button {
                        store.openComment(id: thread.id)
                        store.goToPage(number: thread.anchor.page)
                    } label: {
                        CommentRow(thread: thread, unread: store.unreadCommentThreadIDs.contains(thread.id))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func emptyRow(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
    }

    private func flattenOutline(_ items: [PDFOutlineItem]) -> [PDFOutlineItem] {
        items.flatMap { [$0] + flattenOutline($0.children) }
    }
}

private struct GlassTabSwitcher: View {
    @Binding var selection: SidebarView.SidebarTab
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(SidebarView.SidebarTab.allCases) { tab in
                Button {
                    withAnimation(.easeOut(duration: 0.16)) { selection = tab }
                } label: {
                    Image(systemName: tab.symbol)
                        .font(.system(size: 15, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .frame(height: 30)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .foregroundStyle(selection == tab ? Color.primary : Color.secondary)
                .background {
                    if selection == tab {
                        selectedThumb
                    }
                }
                .help(tab.label)
            }
        }
        .padding(4)
        .glassTrack()
    }

    @ViewBuilder
    private var selectedThumb: some View {
        let shape = Capsule(style: .continuous)
        if #available(macOS 26.0, *) {
            Color.clear
                .glassEffect(.regular.interactive(), in: shape)
                .matchedGeometryEffect(id: "selectedTab", in: namespace)
        } else {
            shape
                .fill(.thickMaterial)
                .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
                .matchedGeometryEffect(id: "selectedTab", in: namespace)
        }
    }
}

/// Sidebar highlight row: click to jump, hover-revealed trash (or right-click)
/// to remove — removal is undoable with ⌘Z.
private struct HighlightListRow: View {
    let highlight: MCPHighlight
    let open: () -> Void
    let delete: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .center, spacing: 4) {
            Button(action: open) { HighlightRow(highlight: highlight) }
                .buttonStyle(.plain)
            if isHovering {
                Button(action: delete) {
                    Image(systemName: "trash")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Remove highlight")
            }
        }
        .onHover { isHovering = $0 }
        .contextMenu {
            Button(role: .destructive, action: delete) {
                Label("Remove Highlight", systemImage: "trash")
            }
        }
    }
}

private struct HighlightRow: View {
    let highlight: MCPHighlight

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 2).fill(swatch).frame(width: 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(highlight.text.isEmpty ? "(highlight)" : highlight.text)
                    .font(.callout)
                    .lineLimit(3)
                Text("p. \(highlight.page)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 2)
    }

    private var swatch: Color {
        if let hex = highlight.color, let color = Color(hex: hex) { return color }
        return .yellow
    }
}

private struct NoteRow: View {
    let note: NoteItem

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "note.text").font(.caption).foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 2) {
                Text(note.text.isEmpty ? "(empty note)" : note.text)
                    .font(.callout)
                    .foregroundStyle(note.text.isEmpty ? .secondary : .primary)
                    .lineLimit(3)
                Text("p. \(note.page)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 2)
    }
}

private struct CommentRow: View {
    let thread: CommentThread
    let unread: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: thread.anchor.kind == .region ? "viewfinder" : "text.bubble")
                .font(.caption)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(preview)
                    .font(.callout)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text("p. \(thread.anchor.page)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if thread.status == .resolved {
                        Text("Resolved").font(.caption2).foregroundStyle(.green)
                    } else if unread {
                        Text("New reply").font(.caption2).foregroundStyle(.blue)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 2)
    }

    private var preview: String {
        if let last = thread.messages.last {
            return last.body
        }
        if let quote = thread.anchor.quote, !quote.isEmpty {
            return "“\(quote)”"
        }
        return thread.anchor.kind == .region ? "Region comment" : "Empty comment"
    }
}

private extension View {
    @ViewBuilder
    func glassTrack() -> some View {
        let shape = Capsule(style: .continuous)
        background(.regularMaterial, in: shape)
            .overlay(shape.strokeBorder(.separator.opacity(0.35)))
    }
}

private extension Color {
    init?(hex: String) {
        var value = hex
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, let int = Int(value, radix: 16) else { return nil }
        self.init(
            red: Double((int >> 16) & 0xFF) / 255,
            green: Double((int >> 8) & 0xFF) / 255,
            blue: Double(int & 0xFF) / 255
        )
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
