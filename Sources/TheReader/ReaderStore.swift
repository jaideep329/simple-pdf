import AppKit
import CryptoKit
import Foundation
import PDFKit

protocol StickyNotePresenting: AnyObject {
    func openStickyNote(_ annotation: PDFAnnotation, on page: PDFPage)
}

struct SelectionEntry: Identifiable, Equatable, Codable, Sendable {
    let id: String
    let text: String
    let pageIndex: Int
    let citation: String
    let deepLink: String?
    let capturedAt: Date
}

/// Sendable snapshots returned to the MCP layer (see MCPService.swift).
struct MCPPageInfo: Codable, Sendable {
    let documentTitle: String
    let documentPath: String?
    let page: Int
    let pageCount: Int
    let chapter: String?
    let text: String?
}

struct MCPHighlight: Codable, Sendable {
    let id: String
    let text: String
    let note: String?
    let page: Int
    let color: String?
    let deepLink: String?
    let modifiedAt: Date?
}

struct MCPSearchHit: Codable, Sendable {
    let page: Int
    let snippet: String
    let deepLink: String?
}

struct NoteItem: Identifiable, Sendable {
    let id: String
    let text: String
    let page: Int
    let deepLink: String?
}

/// A page + annotation pair, used to make annotation add/remove undoable.
struct AnnotationPlacement {
    let page: PDFPage
    let annotation: PDFAnnotation
}

final class ReaderStore: ObservableObject {
    @Published private(set) var document: PDFDocument?
    @Published private(set) var documentURL: URL?
    @Published private(set) var documentTitle = "No PDF Open"
    @Published private(set) var recentPDFs: [RecentPDF] = []
    @Published private(set) var outlineItems: [PDFOutlineItem] = []
    @Published private(set) var currentOutlineItemID: PDFOutlineItem.ID?
    @Published private(set) var currentPageIndex = 0
    @Published private(set) var zoomPercentText = "Fit"
    @Published var selectedText = ""
    @Published private(set) var selectionHistory: [SelectionEntry] = []
    @Published private(set) var commentThreads: [CommentThread] = []
    @Published var activeCommentThreadID: String?
    @Published private(set) var unreadCommentThreadIDs: Set<String> = []
    @Published var isRegionCommentMode = false
    @Published private(set) var annotationsRevision = 0
    @Published var errorMessage: String?

    weak var pdfView: PDFView?

    private let stateStore = PDFDocumentStateStore()
    private let commentStore = CommentStore()
    private let pdfSaveQueue = DispatchQueue(label: "SimplePDF.PDFSave", qos: .utility)
    private var pendingPDFSaveWorkItem: DispatchWorkItem?
    private var pendingSelectionRecord: DispatchWorkItem?
    private var currentViewState = PDFDocumentViewState.initial
    private var hasUnsavedPDFChanges = false
    private var pendingReaderLinkTarget: ReaderLinkTarget?
    private var isRestoringPDFView = false
    private var lifecycleObservers: [NSObjectProtocol] = []
    private var activeFileAccess: SecurityScopedFileAccess?
    private var mcpService: MCPService?

    init() {
        startLifecycleObservers()
        refreshRecentPDFs()
        restoreLastPDF()
        startMCPService()
    }

    deinit {
        for observer in lifecycleObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        flushPendingPDFSave()
        stopActiveFileAccess()
    }

    private func startMCPService() {
        let service = MCPService(bridge: ReaderMCPBridge(store: self))
        mcpService = service
        Task { await service.start() }
    }

    var displayTitle: String {
        documentTitle
    }

    var hasSelection: Bool {
        !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var currentPageText: String {
        guard document != nil else { return "No PDF" }
        return "Page \(currentPageIndex + 1)"
    }

    func currentPDFViewState() -> PDFDocumentViewState {
        currentViewState
    }

    func openPDF() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        loadPDF(at: url, bookmarkData: bookmarkData(for: url))
    }

    func openRecentPDF(_ recentPDF: RecentPDF) {
        loadPDF(at: recentPDF.url)
    }

    func loadPDF(at url: URL, targetPageIndex: Int? = nil) {
        loadPDF(at: url, targetPageIndex: targetPageIndex, bookmarkData: nil)
    }

    private func loadPDF(at url: URL, targetPageIndex: Int? = nil, bookmarkData: Data?) {
        flushPendingPDFSave()
        stopActiveFileAccess()

        let fileAccess = fileAccess(for: url, bookmarkData: bookmarkData)
        let standardizedURL = fileAccess.url.standardizedFileURL
        guard let loadedDocument = PDFDocument(url: standardizedURL) else {
            fileAccess.stop()
            errorMessage = "The selected PDF could not be opened."
            refreshRecentPDFs()
            return
        }
        activeFileAccess = fileAccess

        let changedAnnotations = normalizeAnnotations(in: loadedDocument)
        let loadedTitle = title(for: standardizedURL, document: loadedDocument)
        let savedState = stateStore.loadState(for: standardizedURL)
        let loadedOutlineItems = outlineItems(in: loadedDocument)
        let clampedPageIndex = max(
            0,
            min(
                targetPageIndex ?? savedState.currentPageIndex,
                max(loadedDocument.pageCount - 1, 0)
            )
        )

        document = loadedDocument
        documentURL = standardizedURL
        documentTitle = loadedTitle
        outlineItems = loadedOutlineItems
        selectedText = ""
        pendingSelectionRecord?.cancel()
        selectionHistory = []
        commentThreads = commentStore.loadThreads(forDocumentAt: standardizedURL)
        activeCommentThreadID = nil
        unreadCommentThreadIDs = []
        updateCommentBadge()
        isRegionCommentMode = false
        annotationsRevision &+= 1
        currentPageIndex = clampedPageIndex
        updateCurrentOutlineSelection(for: clampedPageIndex)
        currentViewState = PDFDocumentViewState(
            currentPageIndex: clampedPageIndex,
            autoScales: savedState.autoScales,
            scaleFactor: savedState.scaleFactor,
            updatedAt: savedState.updatedAt
        )
        zoomPercentText = zoomText(for: currentViewState)

        stateStore.recordOpened(
            standardizedURL,
            title: loadedTitle,
            bookmarkData: bookmarkData ?? refreshedBookmarkData(for: standardizedURL)
        )
        stateStore.saveState(currentViewState, for: standardizedURL)
        refreshRecentPDFs()

        if changedAnnotations {
            scheduleCurrentPDFSave()
        }
    }

    func updateSelection(from selection: PDFSelection?) {
        let text = selection?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        selectedText = text
        scheduleSelectionRecord(for: text)
    }

    private func scheduleSelectionRecord(for text: String) {
        pendingSelectionRecord?.cancel()
        guard !text.isEmpty else { return }

        let workItem = DispatchWorkItem { [weak self] in
            self?.recordCurrentSelection()
        }
        pendingSelectionRecord = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: workItem)
    }

    private func recordCurrentSelection() {
        let text = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, document != nil else { return }

        let pageIndex = selectedPageIndex() ?? currentPageIndex

        if let last = selectionHistory.first, last.text == text, last.pageIndex == pageIndex {
            return
        }

        let entry = SelectionEntry(
            id: UUID().uuidString,
            text: text,
            pageIndex: pageIndex,
            citation: citationText(forPageIndex: pageIndex),
            deepLink: readerLinkURL(forQuote: text, pageIndex: pageIndex)?.absoluteString,
            capturedAt: Date()
        )

        selectionHistory.insert(entry, at: 0)
        if selectionHistory.count > 100 {
            selectionHistory = Array(selectionHistory.prefix(100))
        }
    }

    func updateCurrentPage(from pdfView: PDFView) {
        guard !isRestoringPDFView else { return }

        guard
            let document,
            let page = visiblePage(in: pdfView)
        else {
            return
        }

        let pageIndex = document.index(for: page)
        guard pageIndex != NSNotFound, pageIndex != currentPageIndex else { return }
        currentPageIndex = pageIndex
        updateCurrentOutlineSelection(for: pageIndex)
        persistDocumentState(from: pdfView)
    }

    func goToOutlineItem(_ item: PDFOutlineItem) {
        guard let pageIndex = item.pageIndex else { return }
        goToPage(at: pageIndex)
    }

    func highlightSelection() {
        guard let selection = pdfView?.currentSelection, hasSelection else {
            errorMessage = "Select text in the PDF first."
            return
        }

        var added: [AnnotationPlacement] = []
        for lineSelection in selection.selectionsByLine() {
            for page in lineSelection.pages {
                let bounds = lineSelection.bounds(for: page).insetBy(dx: -1.5, dy: -1.5)
                guard !bounds.isNull, !bounds.isEmpty else { continue }

                let annotation = PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)
                annotation.color = NSColor.systemYellow.withAlphaComponent(0.45)
                annotation.userName = NSFullUserName()
                annotation.modificationDate = Date()
                page.addAnnotation(annotation)
                added.append(AnnotationPlacement(page: page, annotation: annotation))
            }
        }

        if added.isEmpty {
            errorMessage = "The current selection could not be highlighted."
        } else if let pdfView {
            pdfView.setNeedsDisplay(pdfView.bounds)
            registerUndoForAddedAnnotations(added, actionName: "Highlight")
            scheduleCurrentPDFSave()
        }
    }

    func addPDFNote() {
        guard let pdfView, let document else {
            errorMessage = "Open a PDF first."
            return
        }

        guard let placement = notePlacement(in: pdfView, document: document) else {
            errorMessage = "The note could not be placed on the PDF."
            return
        }

        let annotation = PDFAnnotation(bounds: placement.bounds, forType: .text, withProperties: nil)
        annotation.color = NSColor.systemYellow
        annotation.contents = ""
        annotation.iconType = .note
        annotation.shouldDisplay = true
        annotation.userName = NSFullUserName()
        annotation.modificationDate = Date()
        placement.page.addAnnotation(annotation)

        pdfView.setNeedsDisplay(pdfView.bounds)
        (pdfView as? StickyNotePresenting)?.openStickyNote(annotation, on: placement.page)
        registerUndoForAddedAnnotations([AnnotationPlacement(page: placement.page, annotation: annotation)], actionName: "Add Note")
        scheduleCurrentPDFSave()
    }

    // MARK: - Annotation undo

    private func registerUndoForAddedAnnotations(_ items: [AnnotationPlacement], actionName: String) {
        guard let undoManager = pdfView?.undoManager else { return }
        undoManager.setActionName(actionName)
        undoManager.registerUndo(withTarget: self) { store in
            store.setAnnotations(items, present: false, actionName: actionName)
        }
    }

    private func setAnnotations(_ items: [AnnotationPlacement], present: Bool, actionName: String) {
        for item in items {
            if present {
                item.page.addAnnotation(item.annotation)
            } else {
                item.page.removeAnnotation(item.annotation)
            }
        }
        pdfView?.setNeedsDisplay(pdfView?.bounds ?? .zero)
        scheduleCurrentPDFSave()

        if let undoManager = pdfView?.undoManager {
            undoManager.setActionName(actionName)
            undoManager.registerUndo(withTarget: self) { store in
                store.setAnnotations(items, present: !present, actionName: actionName)
            }
        }
    }

    func annotationDidChange() {
        scheduleCurrentPDFSave()
    }

    func copyQuote() {
        let quoteText = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !quoteText.isEmpty else {
            errorMessage = "Select text in the PDF first."
            return
        }

        let pageIndex = selectedPageIndex() ?? currentPageIndex
        let citation = citationText(forPageIndex: pageIndex)

        let output = "\(quoteText)\n\n— \(citation)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(output, forType: .string)
    }

    private func citationText(forPageIndex pageIndex: Int) -> String {
        let chapter = chapterTitle(for: pageIndex)
        if let chapter, !chapter.isEmpty {
            return "\(documentTitle), \(chapter), p. \(pageIndex + 1)"
        }
        return "\(documentTitle), p. \(pageIndex + 1)"
    }

    func copySelectionLink() {
        let quoteText = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !quoteText.isEmpty else {
            errorMessage = "Select text in the PDF first."
            return
        }

        guard let url = readerLinkURL(for: quoteText) else {
            errorMessage = "The selected text link could not be created."
            return
        }

        let pageIndex = selectedPageIndex() ?? currentPageIndex
        let label = "\(documentTitle), p. \(pageIndex + 1)"
        let output = "[\(label)](\(url.absoluteString))"

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(output, forType: .string)
    }

    func openReaderURL(_ url: URL) {
        guard
            ["simplepdf", "thereader"].contains(url.scheme?.lowercased() ?? ""),
            url.host == "open",
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else {
            return
        }

        let queryItems = components.queryItems ?? []
        func value(for name: String) -> String? {
            queryItems.first(where: { $0.name == name })?.value
        }

        guard let path = value(for: "path"), !path.isEmpty else {
            errorMessage = "The Simple PDF link is missing a PDF path."
            return
        }

        let pageNumber = Int(value(for: "page") ?? "") ?? 1
        let pageIndex = max(0, pageNumber - 1)
        pendingReaderLinkTarget = ReaderLinkTarget(
            pageIndex: pageIndex,
            quote: value(for: "quote")?.nilIfEmpty
        )
        loadPDF(at: URL(fileURLWithPath: path), targetPageIndex: pageIndex)
    }

    func applyPendingReaderLinkTarget(in pdfView: PDFView) {
        guard
            let target = pendingReaderLinkTarget,
            let document,
            pdfView.document === document
        else {
            return
        }

        pendingReaderLinkTarget = nil

        guard let page = document.page(at: target.pageIndex) else {
            return
        }

        pdfView.go(to: page)
        currentPageIndex = target.pageIndex
        updateCurrentOutlineSelection(for: target.pageIndex)

        if
            let quote = target.quote,
            let selection = selection(matching: quote, onPageIndex: target.pageIndex)
        {
            pdfView.setCurrentSelection(selection, animate: true)
            pdfView.go(to: selection)
        }

        persistDocumentState(from: pdfView)
    }

    func zoomIn() {
        guard let pdfView else { return }
        pdfView.autoScales = false
        pdfView.zoomIn(nil)
        updateZoomText(from: pdfView)
    }

    func zoomOut() {
        guard let pdfView else { return }
        pdfView.autoScales = false
        pdfView.zoomOut(nil)
        updateZoomText(from: pdfView)
    }

    func fitPage() {
        guard let pdfView else { return }
        pdfView.autoScales = true
        updateZoomText(from: pdfView)
    }

    func updateZoomText(from pdfView: PDFView? = nil) {
        guard let pdfView = pdfView ?? self.pdfView else {
            zoomPercentText = zoomText(for: currentViewState)
            return
        }

        if pdfView.autoScales {
            zoomPercentText = "Fit"
        } else {
            zoomPercentText = "\(Int((pdfView.scaleFactor * 100).rounded()))%"
        }

        if pdfView.document === document, !isRestoringPDFView {
            persistDocumentState(from: pdfView)
        }
    }

    func beginRestoringPDFView() {
        isRestoringPDFView = true
    }

    func finishRestoringPDFView(from pdfView: PDFView) {
        isRestoringPDFView = false
        persistDocumentState(from: pdfView)
    }

    func saveCurrentViewState() {
        isRestoringPDFView = false

        if let pdfView {
            updateCurrentPage(from: pdfView)
            persistDocumentState(from: pdfView)
        } else {
            persistDocumentState()
        }

        flushPendingPDFSave()
        UserDefaults.standard.synchronize()
    }

    func revealPDFInFinder() {
        guard let documentURL else {
            errorMessage = "Open a PDF first."
            return
        }

        NSWorkspace.shared.activateFileViewerSelecting([documentURL])
    }

    // MARK: - MCP data access
    //
    // These are invoked on the main actor via ReaderMCPBridge and return only
    // Sendable value types, so the actor-isolated MCP server never touches the
    // live PDFKit/AppKit objects off the main thread.

    func mcpPageInfo() -> MCPPageInfo? {
        mcpPageInfo(forPageIndex: currentPageIndex)
    }

    func mcpPageInfo(forPageNumber pageNumber: Int) -> MCPPageInfo? {
        mcpPageInfo(forPageIndex: pageNumber - 1)
    }

    /// Page infos for an inclusive 1-based range, capped at 50 pages.
    func mcpPages(from: Int, to: Int, includeText: Bool) -> [MCPPageInfo] {
        guard let document else { return [] }

        let lower = max(1, min(from, to))
        let upper = min(document.pageCount, max(from, to))
        guard lower <= upper else { return [] }
        let capped = min(upper, lower + 49)

        var pages: [MCPPageInfo] = []
        for pageNumber in lower...capped {
            guard var info = mcpPageInfo(forPageNumber: pageNumber) else { continue }
            if !includeText {
                info = MCPPageInfo(
                    documentTitle: info.documentTitle,
                    documentPath: info.documentPath,
                    page: info.page,
                    pageCount: info.pageCount,
                    chapter: info.chapter,
                    text: nil
                )
            }
            pages.append(info)
        }
        return pages
    }

    private func mcpPageInfo(forPageIndex requestedIndex: Int) -> MCPPageInfo? {
        guard let document else { return nil }

        let pageIndex = max(0, min(requestedIndex, max(document.pageCount - 1, 0)))
        return MCPPageInfo(
            documentTitle: documentTitle,
            documentPath: documentURL?.path,
            page: pageIndex + 1,
            pageCount: document.pageCount,
            chapter: chapterTitle(for: pageIndex),
            text: document.page(at: pageIndex)?.string
        )
    }

    func mcpHighlights(limit: Int?) -> [MCPHighlight] {
        guard let document else { return [] }

        var highlights: [MCPHighlight] = []
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }

            for annotation in page.annotations where annotation.type == "Highlight" {
                let bounds = annotation.bounds
                let text = page.selection(for: bounds)?.string?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                highlights.append(
                    MCPHighlight(
                        id: highlightID(pageIndex: pageIndex, bounds: bounds),
                        text: text,
                        note: annotation.contents?.nilIfEmpty,
                        page: pageIndex + 1,
                        color: annotation.color.readerHexString,
                        deepLink: readerLinkURL(forQuote: text, pageIndex: pageIndex)?.absoluteString,
                        modifiedAt: annotation.modificationDate
                    )
                )
            }
        }

        highlights.sort { ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast) }

        if let limit, limit > 0, highlights.count > limit {
            return Array(highlights.prefix(limit))
        }
        return highlights
    }

    func mcpRecentSelections(limit: Int) -> [SelectionEntry] {
        Array(selectionHistory.prefix(max(0, limit)))
    }

    func mcpCurrentOrLatestSelection() -> SelectionEntry? {
        let live = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !live.isEmpty else {
            return selectionHistory.first
        }

        let pageIndex = selectedPageIndex() ?? currentPageIndex
        return SelectionEntry(
            id: "live",
            text: live,
            pageIndex: pageIndex,
            citation: citationText(forPageIndex: pageIndex),
            deepLink: readerLinkURL(forQuote: live, pageIndex: pageIndex)?.absoluteString,
            capturedAt: Date()
        )
    }

    func mcpSearch(query: String, limit: Int) -> [MCPSearchHit] {
        guard
            let document,
            !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return []
        }

        let selections = document.findString(query, withOptions: [.caseInsensitive, .diacriticInsensitive])
        var hits: [MCPSearchHit] = []

        for selection in selections {
            guard let page = selection.pages.first else { continue }
            let pageIndex = document.index(for: page)
            guard pageIndex != NSNotFound else { continue }

            hits.append(
                MCPSearchHit(
                    page: pageIndex + 1,
                    snippet: searchSnippet(for: selection, on: page),
                    deepLink: readerLinkURL(forQuote: selection.string ?? query, pageIndex: pageIndex)?.absoluteString
                )
            )

            if hits.count >= max(1, limit) { break }
        }

        return hits
    }

    @discardableResult
    func mcpOpen(pageNumber: Int, path: String?, quote: String?) -> Bool {
        guard let targetPath = path ?? documentURL?.path else { return false }

        var components = URLComponents()
        components.scheme = "simplepdf"
        components.host = "open"
        var items = [
            URLQueryItem(name: "path", value: targetPath),
            URLQueryItem(name: "page", value: String(max(1, pageNumber)))
        ]
        if let quote, !quote.isEmpty {
            items.append(URLQueryItem(name: "quote", value: String(quote.prefix(240))))
        }
        components.queryItems = items

        guard let url = components.url else { return false }
        openReaderURL(url)
        NSApplication.shared.activate(ignoringOtherApps: true)
        return true
    }

    private func highlightID(pageIndex: Int, bounds: CGRect) -> String {
        let raw = [
            pageIndex,
            Int(bounds.origin.x.rounded()),
            Int(bounds.origin.y.rounded()),
            Int(bounds.size.width.rounded()),
            Int(bounds.size.height.rounded())
        ].map(String.init).joined(separator: ":")

        let digest = SHA256.hash(data: Data(raw.utf8))
        return digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    private func searchSnippet(for selection: PDFSelection, on page: PDFPage) -> String {
        let matched = selection.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let pageText = page.string, !matched.isEmpty, let range = pageText.range(of: matched) else {
            return matched
        }

        let lower = pageText.index(range.lowerBound, offsetBy: -60, limitedBy: pageText.startIndex) ?? pageText.startIndex
        let upper = pageText.index(range.upperBound, offsetBy: 60, limitedBy: pageText.endIndex) ?? pageText.endIndex
        return pageText[lower..<upper]
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Comments

    @discardableResult
    func addComment(
        anchor: CommentAnchor,
        body: String,
        author: CommentAuthor,
        agentName: String? = nil
    ) -> CommentThread? {
        guard let documentURL else { return nil }

        let now = Date()
        var messages: [CommentMessage] = []
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            messages.append(
                CommentMessage(id: UUID().uuidString, author: author, agentName: agentName, body: trimmed, createdAt: now)
            )
        }

        let thread = CommentThread(
            id: UUID().uuidString,
            documentPath: documentURL.path,
            anchor: anchor,
            status: .open,
            createdAt: now,
            updatedAt: now,
            messages: messages
        )

        commentThreads.insert(thread, at: 0)
        persistComments()
        return thread
    }

    @discardableResult
    func replyToComment(id: String, body: String, author: CommentAuthor, agentName: String? = nil) -> CommentThread? {
        guard let index = commentThreads.firstIndex(where: { $0.id == id }) else { return nil }

        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return commentThreads[index] }

        commentThreads[index].messages.append(
            CommentMessage(id: UUID().uuidString, author: author, agentName: agentName, body: trimmed, createdAt: Date())
        )
        commentThreads[index].updatedAt = Date()
        persistComments()

        if author == .agent, id != activeCommentThreadID {
            unreadCommentThreadIDs.insert(id)
            updateCommentBadge()
            if !NSApplication.shared.isActive {
                NSApplication.shared.requestUserAttention(.informationalRequest)
            }
        }

        return commentThreads[index]
    }

    @discardableResult
    func setCommentStatus(id: String, status: CommentStatus) -> CommentThread? {
        guard let index = commentThreads.firstIndex(where: { $0.id == id }) else { return nil }

        commentThreads[index].status = status
        commentThreads[index].updatedAt = Date()
        persistComments()
        return commentThreads[index]
    }

    var activeCommentThread: CommentThread? {
        commentThreads.first { $0.id == activeCommentThreadID }
    }

    func openComment(id: String) {
        activeCommentThreadID = id
        if unreadCommentThreadIDs.remove(id) != nil {
            updateCommentBadge()
        }
    }

    func closeActiveComment() { activeCommentThreadID = nil }

    private func updateCommentBadge() {
        NSApplication.shared.dockTile.badgeLabel = unreadCommentThreadIDs.isEmpty
            ? nil
            : String(unreadCommentThreadIDs.count)
    }

    /// Creates a comment anchored to the current text selection and opens its thread.
    @discardableResult
    func startTextComment() -> String? {
        guard
            let pdfView,
            let document,
            let selection = pdfView.currentSelection,
            let page = selection.pages.first
        else {
            return nil
        }

        let pageIndex = document.index(for: page)
        guard pageIndex != NSNotFound else { return nil }

        let quote = selection.string?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty

        var union = CGRect.null
        for line in selection.selectionsByLine() where line.pages.contains(where: { $0 === page }) {
            union = union.union(line.bounds(for: page))
        }
        let bounds: CommentRect? = (union.isNull || union.isEmpty)
            ? nil
            : CommentRect(x: Double(union.minX), y: Double(union.minY), width: Double(union.width), height: Double(union.height))

        let anchor = CommentAnchor(kind: .text, page: pageIndex + 1, quote: quote, bounds: bounds, imagePNGBase64: nil)
        let thread = addComment(anchor: anchor, body: "", author: .human)
        activeCommentThreadID = thread?.id
        return thread?.id
    }

    /// Creates a region-anchored comment (with a snapshot PNG) and opens its thread.
    @discardableResult
    func startRegionComment(pageIndex: Int, bounds: CommentRect, imagePNGBase64: String?) -> String? {
        guard document != nil else { return nil }
        let anchor = CommentAnchor(kind: .region, page: pageIndex + 1, quote: nil, bounds: bounds, imagePNGBase64: imagePNGBase64)
        let thread = addComment(anchor: anchor, body: "", author: .human)
        activeCommentThreadID = thread?.id
        return thread?.id
    }

    @discardableResult
    func addHumanReply(threadID: String, body: String) -> CommentThread? {
        replyToComment(id: threadID, body: body, author: .human)
    }

    /// Builds a text anchor for the agent's `add_comment` (page + optional quote;
    /// bounds are unknown until the app locates the quote).
    func textAnchor(page: Int?, quote: String?) -> CommentAnchor {
        let resolvedPage = page ?? (currentPageIndex + 1)
        let trimmedQuote = quote?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        return CommentAnchor(kind: .text, page: max(1, resolvedPage), quote: trimmedQuote, bounds: nil, imagePNGBase64: nil)
    }

    private func persistComments() {
        guard let documentURL else { return }
        commentStore.saveThreads(commentThreads, forDocumentAt: documentURL)
    }

    // MARK: - Sidebar data

    func sidebarHighlights() -> [MCPHighlight] {
        mcpHighlights(limit: nil)
    }

    func sidebarNotes() -> [NoteItem] {
        guard let document else { return [] }

        var notes: [NoteItem] = []
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }

            for annotation in page.annotations where annotation.type == "Text" {
                let text = annotation.contents?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                notes.append(
                    NoteItem(
                        id: highlightID(pageIndex: pageIndex, bounds: annotation.bounds),
                        text: text,
                        page: pageIndex + 1,
                        deepLink: readerLinkURL(forQuote: text, pageIndex: pageIndex)?.absoluteString
                    )
                )
            }
        }
        return notes
    }

    func goToPage(number pageNumber: Int) {
        goToPage(at: pageNumber - 1)
    }

    private func restoreLastPDF() {
        guard let url = stateStore.loadLastPDFURL() else { return }
        loadPDF(at: url)
    }

    private func goToPage(at pageIndex: Int) {
        guard
            let document,
            let pdfView,
            let page = document.page(at: max(0, min(pageIndex, max(document.pageCount - 1, 0))))
        else {
            return
        }

        pdfView.go(to: page)
        currentPageIndex = document.index(for: page)
        updateCurrentOutlineSelection(for: currentPageIndex)
        persistDocumentState(from: pdfView)
    }

    private func startLifecycleObservers() {
        lifecycleObservers.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.saveCurrentViewState()
            }
        )

        lifecycleObservers.append(
            NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.saveCurrentViewState()
            }
        )
    }

    private func refreshRecentPDFs() {
        recentPDFs = stateStore.recentPDFs()
    }

    private func bookmarkData(for url: URL) -> Data? {
        try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    private func refreshedBookmarkData(for url: URL) -> Data? {
        if let bookmarkData = bookmarkData(for: url) {
            return bookmarkData
        }

            return stateStore.storedBookmarkData(for: url)
    }

    private func fileAccess(for url: URL, bookmarkData: Data?) -> SecurityScopedFileAccess {
        let fallbackURL = url.standardizedFileURL
        let storedBookmarkData = bookmarkData ?? stateStore.storedBookmarkData(for: fallbackURL)

        guard let storedBookmarkData else {
            return SecurityScopedFileAccess(url: fallbackURL, didStartAccessing: false)
        }

        do {
            var isStale = false
            let resolvedURL = try URL(
                resolvingBookmarkData: storedBookmarkData,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ).standardizedFileURL

            let didStartAccessing = resolvedURL.startAccessingSecurityScopedResource()

            if isStale, let refreshedBookmarkData = self.bookmarkData(for: resolvedURL) {
                stateStore.saveBookmarkData(refreshedBookmarkData, for: resolvedURL)
            }

            return SecurityScopedFileAccess(url: resolvedURL, didStartAccessing: didStartAccessing)
        } catch {
            return SecurityScopedFileAccess(url: fallbackURL, didStartAccessing: false)
        }
    }

    private func stopActiveFileAccess() {
        activeFileAccess?.stop()
        activeFileAccess = nil
    }

    private func persistDocumentState(from pdfView: PDFView? = nil) {
        guard let documentURL else { return }

        var state = currentViewState
        state.currentPageIndex = currentPageIndex

        if let pdfView, pdfView.document === document {
            state.autoScales = pdfView.autoScales
            state.scaleFactor = pdfView.scaleFactor
        }

        state.updatedAt = Date()
        currentViewState = state
        stateStore.saveState(state, for: documentURL)
    }

    private func scheduleCurrentPDFSave() {
        guard let document, let documentURL else { return }

        annotationsRevision &+= 1
        hasUnsavedPDFChanges = true
        pendingPDFSaveWorkItem?.cancel()

        let saveURL = documentURL
        let workItem = DispatchWorkItem { [weak self, weak document] in
            guard let self, let document else { return }
            let didSave = document.write(to: saveURL)

            DispatchQueue.main.async {
                self.hasUnsavedPDFChanges = !didSave

                if !didSave {
                    self.errorMessage = "The PDF annotations could not be saved to the original file. Check that the file is writable."
                }
            }
        }

        pendingPDFSaveWorkItem = workItem
        pdfSaveQueue.asyncAfter(deadline: .now() + 0.5, execute: workItem)
    }

    private func flushPendingPDFSave() {
        pendingPDFSaveWorkItem?.cancel()
        pendingPDFSaveWorkItem = nil

        guard hasUnsavedPDFChanges, let document, let documentURL else {
            return
        }

        if document.write(to: documentURL) {
            hasUnsavedPDFChanges = false
        } else {
            errorMessage = "The PDF annotations could not be saved to the original file. Check that the file is writable."
        }
    }

    private func normalizeAnnotations(in document: PDFDocument) -> Bool {
        var changedAnnotations = false

        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }

            for annotation in page.annotations {
                if annotation.type == "Highlight", annotation.contents?.isEmpty == false {
                    annotation.contents = nil
                    annotation.modificationDate = Date()
                    changedAnnotations = true
                }

                if annotation.type == "Text" {
                    if annotation.iconType != .note {
                        annotation.iconType = .note
                        annotation.modificationDate = Date()
                        changedAnnotations = true
                    }

                    if !annotation.shouldDisplay {
                        annotation.shouldDisplay = true
                        annotation.modificationDate = Date()
                        changedAnnotations = true
                    }
                }
            }
        }

        return changedAnnotations
    }

    private func notePlacement(in pdfView: PDFView, document: PDFDocument) -> (page: PDFPage, bounds: CGRect)? {
        if let selection = pdfView.currentSelection {
            for lineSelection in selection.selectionsByLine() {
                guard let page = lineSelection.pages.first else { continue }
                let selectionBounds = lineSelection.bounds(for: page)
                guard !selectionBounds.isNull, !selectionBounds.isEmpty else { continue }

                return (
                    page,
                    noteBounds(
                        near: CGPoint(x: selectionBounds.maxX + 8, y: selectionBounds.midY),
                        on: page,
                        in: pdfView
                    )
                )
            }
        }

        let viewCenter = CGPoint(x: pdfView.bounds.midX, y: pdfView.bounds.midY)
        let page = pdfView.page(for: viewCenter, nearest: true)
            ?? pdfView.currentPage
            ?? document.page(at: 0)

        guard let page else {
            return nil
        }

        let pagePoint = pdfView.convert(viewCenter, to: page)
        return (page, noteBounds(near: pagePoint, on: page, in: pdfView))
    }

    private func noteBounds(near point: CGPoint, on page: PDFPage, in pdfView: PDFView) -> CGRect {
        let pageBounds = page.bounds(for: pdfView.displayBox)
        let size: CGFloat = 24
        let x = min(max(point.x, pageBounds.minX + 4), pageBounds.maxX - size - 4)
        let y = min(max(point.y - size / 2, pageBounds.minY + 4), pageBounds.maxY - size - 4)
        return CGRect(x: x, y: y, width: size, height: size)
    }

    private func selectedPageIndex() -> Int? {
        guard
            let document,
            let page = pdfView?.currentSelection?.pages.first
        else {
            return nil
        }

        let index = document.index(for: page)
        return index == NSNotFound ? nil : index
    }

    private func visiblePage(in pdfView: PDFView) -> PDFPage? {
        let visiblePoint = CGPoint(x: pdfView.bounds.midX, y: pdfView.bounds.midY)
        return pdfView.page(for: visiblePoint, nearest: true) ?? pdfView.currentPage
    }

    private func outlineItems(in document: PDFDocument) -> [PDFOutlineItem] {
        guard let outlineRoot = document.outlineRoot else {
            return []
        }

        return outlineItems(in: outlineRoot, document: document, level: 0, path: [])
    }

    private func outlineItems(
        in outline: PDFOutline,
        document: PDFDocument,
        level: Int,
        path: [Int]
    ) -> [PDFOutlineItem] {
        var items: [PDFOutlineItem] = []

        for childIndex in 0..<outline.numberOfChildren {
            guard let child = outline.child(at: childIndex) else { continue }

            let childPath = path + [childIndex]
            let title = child.label?.trimmingCharacters(in: .whitespacesAndNewlines)
            let pageIndex: Int?
            if let page = child.destination?.page {
                let index = document.index(for: page)
                pageIndex = index == NSNotFound ? nil : index
            } else {
                pageIndex = nil
            }

            let children = outlineItems(in: child, document: document, level: level + 1, path: childPath)

            if let title, !title.isEmpty {
                items.append(
                    PDFOutlineItem(
                        id: childPath.map(String.init).joined(separator: "."),
                        title: title,
                        pageIndex: pageIndex,
                        level: level,
                        children: children
                    )
                )
            } else {
                items.append(contentsOf: children)
            }
        }

        return items
    }

    private func updateCurrentOutlineSelection(for pageIndex: Int) {
        currentOutlineItemID = flattenedOutlineItems(in: outlineItems)
            .filter { $0.pageIndex != nil }
            .last { ($0.pageIndex ?? 0) <= pageIndex }?
            .id
    }

    private func flattenedOutlineItems(in items: [PDFOutlineItem]) -> [PDFOutlineItem] {
        items.flatMap { item in
            [item] + flattenedOutlineItems(in: item.children)
        }
    }

    private func readerLinkURL(for quoteText: String) -> URL? {
        readerLinkURL(forQuote: quoteText, pageIndex: selectedPageIndex() ?? currentPageIndex)
    }

    private func readerLinkURL(forQuote quoteText: String, pageIndex: Int) -> URL? {
        guard let documentURL else { return nil }

        var components = URLComponents()
        components.scheme = "simplepdf"
        components.host = "open"
        components.queryItems = [
            URLQueryItem(name: "path", value: documentURL.standardizedFileURL.path),
            URLQueryItem(name: "page", value: String(pageIndex + 1)),
            URLQueryItem(name: "quote", value: String(searchPhrase(from: quoteText).prefix(240)))
        ]

        return components.url
    }

    private func selection(matching quote: String, onPageIndex pageIndex: Int) -> PDFSelection? {
        guard let document else { return nil }

        for phrase in searchPhrases(from: quote) {
            let selections = document.findString(
                phrase,
                withOptions: [.caseInsensitive, .diacriticInsensitive]
            )

            if let selection = selections.first(where: { selection in
                selection.pages.contains { page in
                    document.index(for: page) == pageIndex
                }
            }) {
                return selection
            }
        }

        return nil
    }

    private func searchPhrases(from text: String) -> [String] {
        let normalized = searchPhrase(from: text)
        let words = normalized.split(separator: " ").map(String.init)
        var phrases = [normalized]

        if words.count > 12 {
            phrases.append(words.prefix(12).joined(separator: " "))
        }

        if words.count > 7 {
            phrases.append(words.prefix(7).joined(separator: " "))
        }

        return phrases
            .map { String($0.prefix(240)).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func searchPhrase(from text: String) -> String {
        text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func chapterTitle(for pageIndex: Int) -> String? {
        if let outlineTitle = outlineChapterTitle(for: pageIndex) {
            return outlineTitle
        }

        return printedChapterTitle(near: pageIndex)
    }

    private func outlineChapterTitle(for pageIndex: Int) -> String? {
        guard let document, let outlineRoot = document.outlineRoot else {
            return nil
        }

        let entries = outlineEntries(in: outlineRoot, document: document)
            .sorted { lhs, rhs in
                if lhs.pageIndex == rhs.pageIndex {
                    return lhs.depth > rhs.depth
                }
                return lhs.pageIndex < rhs.pageIndex
            }

        return entries.last(where: { $0.pageIndex <= pageIndex })?.title
    }

    private func printedChapterTitle(near pageIndex: Int) -> String? {
        guard let document else { return nil }

        let lowerBound = max(0, pageIndex - 20)
        for candidatePageIndex in stride(from: pageIndex, through: lowerBound, by: -1) {
            guard
                let text = document.page(at: candidatePageIndex)?.string,
                let title = printedChapterTitle(in: text)
            else {
                continue
            }

            return title
        }

        return nil
    }

    private func printedChapterTitle(in text: String) -> String? {
        let pattern = #"(?i)\b(Chapter\s+\d+\s*[:.-]\s*[^|\r\n]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }

        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)
        guard
            let match = regex.firstMatch(in: text, range: range),
            match.numberOfRanges > 1
        else {
            return nil
        }

        return nsText
            .substring(with: match.range(at: 1))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func outlineEntries(
        in outline: PDFOutline,
        document: PDFDocument,
        depth: Int = 0
    ) -> [(pageIndex: Int, title: String, depth: Int)] {
        var entries: [(pageIndex: Int, title: String, depth: Int)] = []

        for childIndex in 0..<outline.numberOfChildren {
            guard let child = outline.child(at: childIndex) else { continue }

            if
                let page = child.destination?.page,
                let title = child.label?.trimmingCharacters(in: .whitespacesAndNewlines),
                !title.isEmpty
            {
                let pageIndex = document.index(for: page)
                if pageIndex != NSNotFound {
                    entries.append((pageIndex, title, depth))
                }
            }

            entries.append(contentsOf: outlineEntries(in: child, document: document, depth: depth + 1))
        }

        return entries
    }

    private func title(for url: URL, document: PDFDocument) -> String {
        if
            let title = document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String,
            !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return title.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return url.deletingPathExtension().lastPathComponent
    }

    private func zoomText(for state: PDFDocumentViewState) -> String {
        state.autoScales ? "Fit" : "\(Int((state.scaleFactor * 100).rounded()))%"
    }
}

private struct ReaderLinkTarget {
    let pageIndex: Int
    let quote: String?
}

private struct SecurityScopedFileAccess {
    let url: URL
    let didStartAccessing: Bool

    func stop() {
        if didStartAccessing {
            url.stopAccessingSecurityScopedResource()
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

private extension NSColor {
    var readerHexString: String? {
        guard let rgb = usingColorSpace(.sRGB) else { return nil }
        let r = Int((rgb.redComponent * 255).rounded())
        let g = Int((rgb.greenComponent * 255).rounded())
        let b = Int((rgb.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
