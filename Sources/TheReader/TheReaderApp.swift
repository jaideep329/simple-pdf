import SwiftUI

@main
struct SimplePDFApp: App {
    @StateObject private var store = ReaderStore()

    var body: some Scene {
        WindowGroup {
            ReaderDocumentView()
                .environmentObject(store)
                .frame(minWidth: 1120, minHeight: 720)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open PDF...") {
                    store.openPDF()
                }
                .keyboardShortcut("o", modifiers: [.command])

                Menu("Open Recent") {
                    if store.recentPDFs.isEmpty {
                        Text("No Recent PDFs")
                    } else {
                        ForEach(store.recentPDFs) { recentPDF in
                            Button(recentPDF.title) {
                                store.openRecentPDF(recentPDF)
                            }
                        }
                    }
                }

                Divider()

                Button("Show PDF in Finder") {
                    store.revealPDFInFinder()
                }
                .disabled(store.document == nil)
            }

            CommandMenu("PDF") {
                Button("Copy Quote") {
                    store.copyQuote()
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(!store.hasSelection)

                Button("Copy Link to Selection") {
                    store.copySelectionLink()
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .disabled(!store.hasSelection)

                Button("Highlight Selection") {
                    store.highlightSelection()
                }
                .keyboardShortcut("h", modifiers: [.command, .shift])
                .disabled(!store.hasSelection)

                Button("Add PDF Note") {
                    store.addPDFNote()
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(store.document == nil)

                Divider()

                Button("Zoom In") {
                    store.zoomIn()
                }
                .keyboardShortcut("+", modifiers: [.command])
                .disabled(store.document == nil)

                Button("Zoom Out") {
                    store.zoomOut()
                }
                .keyboardShortcut("-", modifiers: [.command])
                .disabled(store.document == nil)

                Button("Fit Page") {
                    store.fitPage()
                }
                .keyboardShortcut("0", modifiers: [.command, .shift])
                .disabled(store.document == nil)
            }
        }
    }
}
