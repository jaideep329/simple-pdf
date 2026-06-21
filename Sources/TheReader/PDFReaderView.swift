import AppKit
import PDFKit
import SwiftUI

struct PDFReaderView: NSViewRepresentable {
    @ObservedObject var store: ReaderStore

    func makeCoordinator() -> Coordinator {
        Coordinator(store: store)
    }

    func makeNSView(context: Context) -> PDFContainerView {
        let container = PDFContainerView()
        let pdfView = container.pdfView

        pdfView.store = store
        pdfView.autoScales = true
        pdfView.backgroundColor = .windowBackgroundColor
        pdfView.displayDirection = .vertical
        pdfView.displayMode = .singlePageContinuous
        pdfView.displaysPageBreaks = true
        pdfView.minScaleFactor = 0.25
        pdfView.maxScaleFactor = 5.0

        store.pdfView = pdfView
        context.coordinator.observe(pdfView)
        context.coordinator.install(store.document, in: pdfView)

        return container
    }

    func updateNSView(_ container: PDFContainerView, context: Context) {
        let pdfView = container.pdfView

        if store.pdfView !== pdfView {
            store.pdfView = pdfView
        }
        pdfView.store = store

        context.coordinator.install(store.document, in: pdfView)
    }

    static func dismantleNSView(_ nsView: PDFContainerView, coordinator: Coordinator) {
        coordinator.store?.updateCurrentPage(from: nsView.pdfView)
        coordinator.stopObserving()
        nsView.pdfView.closeStickyNote()
        nsView.pdfView.hideSelectionPopover()

        if coordinator.store?.pdfView === nsView.pdfView {
            coordinator.store?.pdfView = nil
        }
    }

    final class Coordinator: NSObject {
        weak var store: ReaderStore?
        private weak var observedPDFView: ReaderPDFView?
        private weak var observedScrollContentView: NSClipView?
        private weak var installedDocument: PDFDocument?

        init(store: ReaderStore) {
            self.store = store
        }

        func observe(_ pdfView: ReaderPDFView) {
            observedPDFView = pdfView
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(selectionChanged(_:)),
                name: Notification.Name.PDFViewSelectionChanged,
                object: pdfView
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(scaleChanged(_:)),
                name: Notification.Name.PDFViewScaleChanged,
                object: pdfView
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(pageChanged(_:)),
                name: Notification.Name.PDFViewPageChanged,
                object: pdfView
            )
        }

        func install(_ document: PDFDocument?, in pdfView: ReaderPDFView) {
            guard installedDocument !== document else {
                configureScrollers(for: pdfView)
                return
            }

            installedDocument = document
            pdfView.closeStickyNote()
            store?.beginRestoringPDFView()

            DispatchQueue.main.async { [weak self, weak pdfView, document] in
                guard let self, let pdfView else { return }

                pdfView.document = document
                let viewState = self.store?.currentPDFViewState() ?? .initial
                pdfView.autoScales = viewState.autoScales

                let pageIndex = max(0, self.store?.currentPageIndex ?? 0)
                if let page = document?.page(at: pageIndex) ?? document?.page(at: 0) {
                    pdfView.go(to: page)
                }

                pdfView.layoutDocumentView()
                if viewState.autoScales {
                    self.refitIfNeeded(pdfView)
                } else {
                    pdfView.scaleFactor = min(
                        max(viewState.scaleFactor, pdfView.minScaleFactor),
                        pdfView.maxScaleFactor
                    )
                }
                if let page = document?.page(at: pageIndex) ?? document?.page(at: 0) {
                    pdfView.go(to: page)
                }
                pdfView.setNeedsDisplay(pdfView.bounds)
                self.configureScrollers(for: pdfView)
                self.store?.updateZoomText(from: pdfView)

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self, weak pdfView] in
                    guard let self, let pdfView else { return }
                    self.refitIfNeeded(pdfView)
                    pdfView.layoutDocumentView()
                    if let page = document?.page(at: pageIndex) ?? document?.page(at: 0) {
                        pdfView.go(to: page)
                    }
                    pdfView.documentView?.setNeedsDisplay(pdfView.documentView?.bounds ?? .zero)
                    pdfView.setNeedsDisplay(pdfView.bounds)
                    pdfView.layoutStickyNoteEditor()
                    self.store?.applyPendingReaderLinkTarget(in: pdfView)
                    self.store?.finishRestoringPDFView(from: pdfView)
                    self.store?.updateZoomText(from: pdfView)
                }
            }
        }

        func stopObserving() {
            if let observedPDFView {
                store?.updateCurrentPage(from: observedPDFView)
            }

            if let observedPDFView {
                NotificationCenter.default.removeObserver(
                    self,
                    name: Notification.Name.PDFViewSelectionChanged,
                    object: observedPDFView
                )
                NotificationCenter.default.removeObserver(
                    self,
                    name: Notification.Name.PDFViewScaleChanged,
                    object: observedPDFView
                )
                NotificationCenter.default.removeObserver(
                    self,
                    name: Notification.Name.PDFViewPageChanged,
                    object: observedPDFView
                )
            }

            if let observedScrollContentView {
                NotificationCenter.default.removeObserver(
                    self,
                    name: NSView.boundsDidChangeNotification,
                    object: observedScrollContentView
                )
            }
        }

        private func configureScrollers(for pdfView: ReaderPDFView) {
            DispatchQueue.main.async { [weak self, weak pdfView] in
                guard let self, let pdfView else { return }
                let scrollView = pdfView.documentView?.enclosingScrollView
                scrollView?.hasVerticalScroller = true
                scrollView?.hasHorizontalScroller = true
                scrollView?.autohidesScrollers = false

                if self.observedScrollContentView !== scrollView?.contentView {
                    if let observedScrollContentView = self.observedScrollContentView {
                        NotificationCenter.default.removeObserver(
                            self,
                            name: NSView.boundsDidChangeNotification,
                            object: observedScrollContentView
                        )
                    }

                    self.observedScrollContentView = scrollView?.contentView
                    scrollView?.contentView.postsBoundsChangedNotifications = true
                    if let contentView = scrollView?.contentView {
                        NotificationCenter.default.addObserver(
                            self,
                            selector: #selector(self.scrollBoundsChanged(_:)),
                            name: NSView.boundsDidChangeNotification,
                            object: contentView
                        )
                    }
                }
            }
        }

        private func refitIfNeeded(_ pdfView: PDFView) {
            guard
                pdfView.document != nil,
                pdfView.bounds.width > 0,
                pdfView.bounds.height > 0
            else {
                return
            }

            if pdfView.autoScales {
                let scale = pdfView.scaleFactorForSizeToFit
                if abs(pdfView.scaleFactor - scale) > 0.001 {
                    pdfView.scaleFactor = scale
                }
            }
        }

        @objc private func selectionChanged(_ notification: Notification) {
            guard let pdfView = notification.object as? ReaderPDFView else { return }
            store?.updateSelection(from: pdfView.currentSelection)
            pdfView.refreshSelectionPopover()
        }

        @objc private func scaleChanged(_ notification: Notification) {
            guard let pdfView = notification.object as? ReaderPDFView else { return }
            store?.updateZoomText(from: pdfView)
            pdfView.layoutStickyNoteEditor()
            pdfView.layoutSelectionPopover()
        }

        @objc private func pageChanged(_ notification: Notification) {
            guard let pdfView = notification.object as? ReaderPDFView else { return }
            store?.updateCurrentPage(from: pdfView)
            pdfView.layoutStickyNoteEditor()
            pdfView.layoutSelectionPopover()
        }

        @objc private func scrollBoundsChanged(_ notification: Notification) {
            guard let observedPDFView else { return }
            store?.updateCurrentPage(from: observedPDFView)
            observedPDFView.layoutStickyNoteEditor()
            observedPDFView.layoutSelectionPopover()
        }
    }
}

final class PDFContainerView: NSView {
    let pdfView = ReaderPDFView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    override func layout() {
        super.layout()
        pdfView.layoutDocumentView()

        if pdfView.autoScales, pdfView.document != nil, bounds.width > 0, bounds.height > 0 {
            let scale = pdfView.scaleFactorForSizeToFit
            if abs(pdfView.scaleFactor - scale) > 0.001 {
                pdfView.scaleFactor = scale
            }
        }

        pdfView.layoutStickyNoteEditor()
    }

    private func setup() {
        wantsLayer = true
        pdfView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pdfView)

        NSLayoutConstraint.activate([
            pdfView.leadingAnchor.constraint(equalTo: leadingAnchor),
            pdfView.trailingAnchor.constraint(equalTo: trailingAnchor),
            pdfView.topAnchor.constraint(equalTo: topAnchor),
            pdfView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }
}

final class ReaderPDFView: PDFView, StickyNotePresenting {
    weak var store: ReaderStore?

    private weak var activeAnnotation: PDFAnnotation?
    private weak var activePage: PDFPage?
    private var stickyEditor: StickyNoteEditorView?
    private weak var draggedAnnotation: PDFAnnotation?
    private weak var draggedPage: PDFPage?
    private var draggedAnnotationOffset: CGPoint = .zero
    private var didDragAnnotation = false
    private var selectionPopover: SelectionPopoverView?
    private var pendingPopoverShow: DispatchWorkItem?
    private var regionStart: CGPoint?
    private var regionMarquee: NSView?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        backgroundColor = .windowBackgroundColor
        setNeedsDisplay(bounds)
    }

    override func mouseDown(with event: NSEvent) {
        hideSelectionPopover()
        let viewPoint = convert(event.locationInWindow, from: nil)

        if store?.isRegionCommentMode == true {
            beginRegionDrag(at: viewPoint)
            return
        }

        if let hit = noteAnnotation(at: viewPoint) {
            closeStickyNote()
            draggedAnnotation = hit.annotation
            draggedPage = hit.page
            let pagePoint = convert(viewPoint, to: hit.page)
            draggedAnnotationOffset = CGPoint(
                x: pagePoint.x - hit.annotation.bounds.origin.x,
                y: pagePoint.y - hit.annotation.bounds.origin.y
            )
            didDragAnnotation = false
            return
        }

        if stickyEditor != nil {
            closeStickyNote()
        }

        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        if regionStart != nil {
            updateRegionDrag(to: convert(event.locationInWindow, from: nil))
            return
        }

        guard
            let draggedAnnotation,
            let draggedPage
        else {
            super.mouseDragged(with: event)
            return
        }

        let viewPoint = convert(event.locationInWindow, from: nil)
        if let targetPage = moveNoteAnnotation(
            draggedAnnotation,
            from: draggedPage,
            to: viewPoint,
            preserving: draggedAnnotationOffset
        ) {
            self.draggedPage = targetPage
            didDragAnnotation = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        if regionStart != nil {
            endRegionDrag()
            return
        }

        if let draggedAnnotation, let draggedPage {
            if didDragAnnotation {
                store?.annotationDidChange()
            } else {
                openStickyNote(draggedAnnotation, on: draggedPage)
            }

            self.draggedAnnotation = nil
            self.draggedPage = nil
            draggedAnnotationOffset = .zero
            didDragAnnotation = false
            return
        }

        super.mouseUp(with: event)
    }

    func openStickyNote(_ annotation: PDFAnnotation, on page: PDFPage) {
        closeStickyNote()

        activeAnnotation = annotation
        activePage = page

        let editor = StickyNoteEditorView(
            annotation: annotation,
            pdfView: self,
            store: store
        )
        stickyEditor = editor
        addSubview(editor)
        layoutStickyNoteEditor()
        editor.focus()
    }

    func closeStickyNote() {
        stickyEditor?.commit()
        stickyEditor?.removeFromSuperview()
        stickyEditor = nil
        activeAnnotation = nil
        activePage = nil
    }

    func layoutStickyNoteEditor() {
        guard
            let stickyEditor,
            let activeAnnotation,
            let activePage
        else {
            return
        }

        let iconRect = convert(activeAnnotation.bounds, from: activePage)
        let size = stickyEditor.preferredSize
        var x = iconRect.maxX + 10
        var y = iconRect.midY - size.height / 2

        if x + size.width > bounds.maxX - 20 {
            x = iconRect.minX - size.width - 10
        }

        x = min(max(20, x), max(20, bounds.maxX - size.width - 20))
        y = min(max(20, y), max(20, bounds.maxY - size.height - 20))

        stickyEditor.frame = NSRect(origin: CGPoint(x: x, y: y), size: size)
    }

    // MARK: - Selection popover

    func refreshSelectionPopover() {
        guard selectionAnchorRect(for: currentSelection) != nil else {
            hideSelectionPopover()
            return
        }

        if selectionPopover != nil {
            layoutSelectionPopover()
            return
        }

        pendingPopoverShow?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.showSelectionPopover()
        }
        pendingPopoverShow = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: workItem)
    }

    func layoutSelectionPopover() {
        guard
            let selectionPopover,
            let anchor = selectionAnchorRect(for: currentSelection)
        else {
            return
        }

        let size = selectionPopover.preferredSize
        let gap: CGFloat = 8
        var x = anchor.maxX - size.width / 2
        var y = anchor.minY - gap - size.height
        if y < 8 {
            y = anchor.maxY + gap
        }
        x = min(max(8, x), max(8, bounds.maxX - size.width - 8))
        y = min(max(8, y), max(8, bounds.maxY - size.height - 8))
        selectionPopover.frame = NSRect(origin: CGPoint(x: x, y: y), size: size)
    }

    func hideSelectionPopover() {
        pendingPopoverShow?.cancel()
        pendingPopoverShow = nil
        selectionPopover?.removeFromSuperview()
        selectionPopover = nil
    }

    func clearSelectionAndPopover() {
        currentSelection = nil
        hideSelectionPopover()
    }

    override func cancelOperation(_ sender: Any?) {
        if store?.isRegionCommentMode == true || regionStart != nil {
            cancelRegionDrag()
        } else if selectionPopover != nil {
            hideSelectionPopover()
        } else {
            super.cancelOperation(sender)
        }
    }

    // MARK: - Region comment drag

    private func beginRegionDrag(at point: CGPoint) {
        regionStart = point
        let marquee = NSView(frame: NSRect(origin: point, size: .zero))
        marquee.wantsLayer = true
        marquee.layer?.borderColor = NSColor.controlAccentColor.cgColor
        marquee.layer?.borderWidth = 1.5
        marquee.layer?.cornerRadius = 3
        marquee.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.15).cgColor
        addSubview(marquee)
        regionMarquee = marquee
    }

    private func updateRegionDrag(to point: CGPoint) {
        guard let start = regionStart else { return }
        regionMarquee?.frame = NSRect(
            x: min(point.x, start.x),
            y: min(point.y, start.y),
            width: abs(point.x - start.x),
            height: abs(point.y - start.y)
        )
    }

    private func cancelRegionDrag() {
        regionMarquee?.removeFromSuperview()
        regionMarquee = nil
        regionStart = nil
        store?.isRegionCommentMode = false
    }

    private func endRegionDrag() {
        let marquee = regionMarquee
        regionMarquee = nil
        regionStart = nil
        store?.isRegionCommentMode = false

        guard let marquee else { return }
        let viewRect = marquee.frame
        marquee.removeFromSuperview() // remove before snapshot so it is not captured

        guard
            viewRect.width > 8, viewRect.height > 8,
            let document, let store,
            let page = page(for: CGPoint(x: viewRect.midX, y: viewRect.midY), nearest: true)
        else {
            return
        }

        let pageIndex = document.index(for: page)
        guard pageIndex != NSNotFound else { return }

        let pageRect = convert(viewRect, to: page)
        let bounds = CommentRect(
            x: Double(pageRect.minX),
            y: Double(pageRect.minY),
            width: Double(pageRect.width),
            height: Double(pageRect.height)
        )
        store.startRegionComment(
            pageIndex: pageIndex,
            bounds: bounds,
            imagePNGBase64: snapshotPNGBase64(viewRect: viewRect)
        )
    }

    private func snapshotPNGBase64(viewRect: NSRect) -> String? {
        guard let rep = bitmapImageRepForCachingDisplay(in: viewRect) else { return nil }
        cacheDisplay(in: viewRect, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return nil }
        return data.base64EncodedString()
    }

    private func showSelectionPopover() {
        guard
            store != nil,
            selectionAnchorRect(for: currentSelection) != nil
        else {
            return
        }

        if selectionPopover == nil {
            let popover = SelectionPopoverView(pdfView: self, store: store)
            selectionPopover = popover
            addSubview(popover)
        }
        layoutSelectionPopover()
    }

    private func selectionAnchorRect(for selection: PDFSelection?) -> CGRect? {
        guard let selection else { return nil }

        let text = selection.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else { return nil }

        let target = selection.selectionsByLine().last ?? selection
        guard let page = target.pages.last else { return nil }

        let bounds = target.bounds(for: page)
        guard !bounds.isNull, !bounds.isEmpty else { return nil }

        return convert(bounds, from: page)
    }

    func moveStickyNote(from editor: StickyNoteEditorView) {
        guard
            editor === stickyEditor,
            let annotation = activeAnnotation,
            let oldPage = activePage
        else {
            return
        }

        let iconPoint = CGPoint(x: editor.frame.minX - 18, y: editor.frame.midY)
        if let targetPage = moveNoteAnnotation(
            annotation,
            from: oldPage,
            to: iconPoint,
            preserving: CGPoint(x: annotation.bounds.width / 2, y: annotation.bounds.height / 2)
        ) {
            activePage = targetPage
            store?.annotationDidChange()
        }
    }

    private func moveNoteAnnotation(
        _ annotation: PDFAnnotation,
        from oldPage: PDFPage,
        to viewPoint: CGPoint,
        preserving offset: CGPoint
    ) -> PDFPage? {
        guard let targetPage = page(for: viewPoint, nearest: true) else {
            return nil
        }

        let pagePoint = convert(viewPoint, to: targetPage)
        let pageBounds = targetPage.bounds(for: displayBox)
        let size = annotation.bounds.size
        let x = min(max(pagePoint.x - offset.x, pageBounds.minX + 4), pageBounds.maxX - size.width - 4)
        let y = min(max(pagePoint.y - offset.y, pageBounds.minY + 4), pageBounds.maxY - size.height - 4)

        if targetPage !== oldPage {
            oldPage.removeAnnotation(annotation)
            targetPage.addAnnotation(annotation)
        }

        annotation.bounds = CGRect(origin: CGPoint(x: x, y: y), size: size)
        annotation.modificationDate = Date()
        setNeedsDisplay(bounds)

        return targetPage
    }

    private func noteAnnotation(at viewPoint: CGPoint) -> (annotation: PDFAnnotation, page: PDFPage)? {
        guard let page = page(for: viewPoint, nearest: false) else {
            return nil
        }

        let pagePoint = convert(viewPoint, to: page)

        if let annotation = page.annotation(at: pagePoint), annotation.type == "Text" {
            return (annotation, page)
        }

        let hitPadding: CGFloat = 8
        if let annotation = page.annotations.first(where: { annotation in
            annotation.type == "Text" && annotation.bounds.insetBy(dx: -hitPadding, dy: -hitPadding).contains(pagePoint)
        }) {
            return (annotation, page)
        }

        return nil
    }
}

final class StickyNoteEditorView: NSView, NSTextViewDelegate {
    let preferredSize = NSSize(width: 260, height: 172)

    private weak var annotation: PDFAnnotation?
    private weak var pdfView: ReaderPDFView?
    private weak var store: ReaderStore?

    private let titleBar = NSView()
    private let textView = NSTextView()
    private var dragStartLocation: CGPoint?
    private var dragStartOrigin: CGPoint?

    init(
        annotation: PDFAnnotation,
        pdfView: ReaderPDFView,
        store: ReaderStore?
    ) {
        self.annotation = annotation
        self.pdfView = pdfView
        self.store = store
        super.init(frame: NSRect(origin: .zero, size: preferredSize))
        setup()
        textView.string = annotation.contents ?? ""
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hitView = super.hitTest(point)

        if titleBar.frame.contains(point), !(hitView is NSButton) {
            return self
        }

        return hitView
    }

    func focus() {
        window?.makeFirstResponder(textView)
    }

    func commit() {
        guard let annotation else { return }
        annotation.contents = textView.string
        annotation.modificationDate = Date()
        store?.annotationDidChange()
    }

    override func mouseDown(with event: NSEvent) {
        let localPoint = convert(event.locationInWindow, from: nil)
        if titleBar.frame.contains(localPoint) {
            dragStartLocation = event.locationInWindow
            dragStartOrigin = frame.origin
        } else {
            super.mouseDown(with: event)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard
            let dragStartLocation,
            let dragStartOrigin
        else {
            super.mouseDragged(with: event)
            return
        }

        let dx = event.locationInWindow.x - dragStartLocation.x
        let dy = event.locationInWindow.y - dragStartLocation.y
        frame.origin = CGPoint(x: dragStartOrigin.x + dx, y: dragStartOrigin.y + dy)
        pdfView?.moveStickyNote(from: self)
    }

    override func mouseUp(with event: NSEvent) {
        dragStartLocation = nil
        dragStartOrigin = nil
        commit()
        super.mouseUp(with: event)
    }

    func textDidChange(_ notification: Notification) {
        commit()
    }

    private func setup() {
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        shadow = {
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
            shadow.shadowOffset = NSSize(width: 0, height: -2)
            shadow.shadowBlurRadius = 10
            return shadow
        }()

        titleBar.translatesAutoresizingMaskIntoConstraints = false
        titleBar.wantsLayer = true
        addSubview(titleBar)

        let titleLabel = NSTextField(labelWithString: "Note")
        titleLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleBar.addSubview(titleLabel)

        let closeButton = NSButton(
            image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Note") ?? NSImage(),
            target: self,
            action: #selector(close)
        )
        closeButton.bezelStyle = .inline
        closeButton.isBordered = false
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        titleBar.addSubview(closeButton)

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        addSubview(scrollView)

        textView.delegate = self
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(width: preferredSize.width, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        scrollView.documentView = textView

        applyTheme()

        NSLayoutConstraint.activate([
            titleBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            titleBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            titleBar.topAnchor.constraint(equalTo: topAnchor),
            titleBar.heightAnchor.constraint(equalToConstant: 28),

            titleLabel.leadingAnchor.constraint(equalTo: titleBar.leadingAnchor, constant: 10),
            titleLabel.centerYAnchor.constraint(equalTo: titleBar.centerYAnchor),

            closeButton.trailingAnchor.constraint(equalTo: titleBar.trailingAnchor, constant: -6),
            closeButton.centerYAnchor.constraint(equalTo: titleBar.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 20),
            closeButton.heightAnchor.constraint(equalToConstant: 20),

            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: titleBar.bottomAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    @objc private func close() {
        commit()
        pdfView?.closeStickyNote()
    }

    private func applyTheme() {
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.96).cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
        titleBar.layer?.backgroundColor = NSColor.systemYellow.withAlphaComponent(0.92).cgColor
    }
}

final class SelectionPopoverView: NSView {
    private let hostingView: NSHostingView<SelectionPopoverContent>

    var preferredSize: NSSize {
        let size = hostingView.fittingSize
        return NSSize(width: max(size.width, 40), height: max(size.height, 30))
    }

    init(pdfView: ReaderPDFView, store: ReaderStore?) {
        let content = SelectionPopoverContent(
            onHighlight: { [weak pdfView] in
                store?.highlightSelection()
                pdfView?.clearSelectionAndPopover()
            },
            onCopyQuote: { store?.copyQuote() },
            onCopyLink: { store?.copySelectionLink() },
            onComment: { [weak pdfView] in
                store?.startTextComment()
                pdfView?.hideSelectionPopover()
            },
            onDismiss: { [weak pdfView] in
                pdfView?.hideSelectionPopover()
            }
        )

        hostingView = NSHostingView(rootView: content)
        super.init(frame: NSRect(origin: .zero, size: hostingView.fittingSize))

        hostingView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }
}

struct SelectionPopoverContent: View {
    let onHighlight: () -> Void
    let onCopyQuote: () -> Void
    let onCopyLink: () -> Void
    let onComment: () -> Void
    let onDismiss: () -> Void

    @State private var didCopy = false
    @State private var hovered: String?

    private struct Action: Identifiable {
        let id: String
        let symbol: String
        let title: String
        let perform: () -> Void
    }

    private var actions: [Action] {
        [
            Action(id: "highlight", symbol: "highlighter", title: "Highlight") { onHighlight() },
            Action(id: "quote", symbol: "quote.opening", title: "Copy Quote") {
                onCopyQuote()
                confirmCopy()
            },
            Action(id: "link", symbol: "link", title: "Copy Link") {
                onCopyLink()
                confirmCopy()
            },
            Action(id: "comment", symbol: "text.bubble", title: "Comment") { onComment() },
        ]
    }

    var body: some View {
        Group {
            if didCopy {
                Label("Copied", systemImage: "checkmark")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 18)
                    .frame(height: 36)
            } else {
                HStack(spacing: 2) {
                    ForEach(actions) { action in
                        Button(action: action.perform) {
                            Image(systemName: action.symbol)
                                .font(.system(size: 15, weight: .medium))
                                .frame(width: 42, height: 34)
                                .contentShape(Capsule(style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .background {
                            if hovered == action.id {
                                hoverHighlight.transition(.opacity)
                            }
                        }
                        .linkPointer()
                        .onHover { inside in
                            if inside {
                                hovered = action.id
                            } else if hovered == action.id {
                                hovered = nil
                            }
                        }
                        .help(action.title)
                    }
                }
                .padding(5)
                .animation(.easeOut(duration: 0.14), value: hovered)
            }
        }
        .fixedSize()
        .popoverGlass()
    }

    @ViewBuilder
    private var hoverHighlight: some View {
        let shape = Capsule(style: .continuous)
        if #available(macOS 26.0, *) {
            Color.clear.glassEffect(.regular, in: shape)
        } else {
            shape.fill(.secondary.opacity(0.3))
        }
    }

    private func confirmCopy() {
        didCopy = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            onDismiss()
        }
    }
}

private extension View {
    @ViewBuilder
    func popoverGlass() -> some View {
        let shape = Capsule(style: .continuous)
        if #available(macOS 26.0, *) {
            glassEffect(.regular, in: shape)
        } else {
            background(.regularMaterial, in: shape)
                .overlay(shape.strokeBorder(.separator))
        }
    }

    @ViewBuilder
    func linkPointer() -> some View {
        if #available(macOS 15.0, *) {
            pointerStyle(.link)
        } else {
            self
        }
    }
}
