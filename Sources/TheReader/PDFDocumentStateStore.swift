import CryptoKit
import Foundation

struct RecentPDF: Identifiable, Equatable {
    let id: String
    let title: String
    let url: URL
    let lastOpenedAt: Date
}

struct PDFOutlineItem: Identifiable, Hashable {
    let id: String
    let title: String
    let pageIndex: Int?
    let level: Int
    let children: [PDFOutlineItem]

    var outlineChildren: [PDFOutlineItem]? {
        children.isEmpty ? nil : children
    }
}

struct PDFDocumentViewState: Codable, Equatable {
    var currentPageIndex: Int
    var autoScales: Bool
    var scaleFactor: CGFloat
    var updatedAt: Date

    static let initial = PDFDocumentViewState(
        currentPageIndex: 0,
        autoScales: true,
        scaleFactor: 1.0,
        updatedAt: Date()
    )
}

struct PDFDocumentStateStore {
    private let defaults: UserDefaults
    private let fileManager: FileManager
    private let maxRecentPDFs = 12

    init(defaults: UserDefaults = .standard, fileManager: FileManager = .default) {
        self.defaults = defaults
        self.fileManager = fileManager
        Self.migrateLegacyDefaultsIfNeeded(to: defaults)
    }

    func recentPDFs() -> [RecentPDF] {
        storedRecentPDFs().compactMap { storedPDF in
            let url = URL(fileURLWithPath: storedPDF.path)
            guard fileManager.fileExists(atPath: url.path) else { return nil }

            return RecentPDF(
                id: documentKey(for: url),
                title: storedPDF.title,
                url: url,
                lastOpenedAt: storedPDF.lastOpenedAt
            )
        }
    }

    func recordOpened(_ url: URL, title: String, bookmarkData: Data? = nil) {
        let standardizedURL = url.standardizedFileURL
        var storedPDFs = storedRecentPDFs().filter { storedPDF in
            storedPDF.path != standardizedURL.path
        }

        storedPDFs.insert(
            StoredRecentPDF(
                title: title,
                path: standardizedURL.path,
                lastOpenedAt: Date(),
                bookmarkData: bookmarkData ?? storedBookmarkData(for: standardizedURL)
            ),
            at: 0
        )

        storedPDFs = Array(storedPDFs.prefix(maxRecentPDFs))
        saveStoredRecentPDFs(storedPDFs)
        defaults.set(standardizedURL.path, forKey: DefaultsKey.lastPDFPath)
    }

    func loadLastPDFURL() -> URL? {
        if
            let path = defaults.string(forKey: DefaultsKey.lastPDFPath),
            fileManager.fileExists(atPath: path)
        {
            return URL(fileURLWithPath: path)
        }

        if let recentURL = recentPDFs().first?.url {
            return recentURL
        }

        return nil
    }

    func storedBookmarkData(for url: URL) -> Data? {
        let standardizedURL = url.standardizedFileURL
        return storedRecentPDFs().first { storedPDF in
            storedPDF.path == standardizedURL.path
        }?.bookmarkData
    }

    func saveBookmarkData(_ bookmarkData: Data, for url: URL) {
        let standardizedURL = url.standardizedFileURL
        var storedPDFs = storedRecentPDFs()
        guard let index = storedPDFs.firstIndex(where: { $0.path == standardizedURL.path }) else {
            return
        }

        storedPDFs[index] = StoredRecentPDF(
            title: storedPDFs[index].title,
            path: storedPDFs[index].path,
            lastOpenedAt: storedPDFs[index].lastOpenedAt,
            bookmarkData: bookmarkData
        )
        saveStoredRecentPDFs(storedPDFs)
    }

    func loadState(for url: URL) -> PDFDocumentViewState {
        guard
            let data = defaults.data(forKey: stateDefaultsKey(for: url)),
            let state = try? JSONDecoder.readerDecoder.decode(PDFDocumentViewState.self, from: data)
        else {
            return .initial
        }

        return state
    }

    func saveState(_ state: PDFDocumentViewState, for url: URL) {
        guard let data = try? JSONEncoder.readerEncoder.encode(state) else { return }
        defaults.set(data, forKey: stateDefaultsKey(for: url))
    }

    private func storedRecentPDFs() -> [StoredRecentPDF] {
        guard
            let data = defaults.data(forKey: DefaultsKey.recentPDFs),
            let storedPDFs = try? JSONDecoder.readerDecoder.decode([StoredRecentPDF].self, from: data)
        else {
            return []
        }

        return storedPDFs
    }

    private func saveStoredRecentPDFs(_ storedPDFs: [StoredRecentPDF]) {
        guard let data = try? JSONEncoder.readerEncoder.encode(storedPDFs) else { return }
        defaults.set(data, forKey: DefaultsKey.recentPDFs)
    }

    private func stateDefaultsKey(for url: URL) -> String {
        "\(DefaultsKey.viewStatePrefix).\(documentKey(for: url))"
    }

    private func documentKey(for url: URL) -> String {
        let path = url.standardizedFileURL.path
        let digest = SHA256.hash(data: Data(path.utf8))
        return digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    private static func migrateLegacyDefaultsIfNeeded(to defaults: UserDefaults) {
        guard !defaults.bool(forKey: DefaultsKey.legacyMigrationComplete) else {
            return
        }

        defer {
            defaults.set(true, forKey: DefaultsKey.legacyMigrationComplete)
        }

        guard let legacyDefaults = UserDefaults(suiteName: DefaultsKey.legacySuiteName) else {
            return
        }

        for key in [DefaultsKey.recentPDFs, DefaultsKey.lastPDFPath] where defaults.object(forKey: key) == nil {
            if let value = legacyDefaults.object(forKey: key) {
                defaults.set(value, forKey: key)
            }
        }

        for key in legacyDefaults.dictionaryRepresentation().keys where key.hasPrefix("\(DefaultsKey.viewStatePrefix).") {
            guard defaults.object(forKey: key) == nil, let value = legacyDefaults.object(forKey: key) else {
                continue
            }

            defaults.set(value, forKey: key)
        }
    }
}

private struct StoredRecentPDF: Codable {
    let title: String
    let path: String
    let lastOpenedAt: Date
    var bookmarkData: Data?
}

private enum DefaultsKey {
    static let legacySuiteName = "dev.local.TheReader"
    static let legacyMigrationComplete = "legacyTheReaderDefaultsMigrated.v1"
    static let recentPDFs = "recentPDFs.v1"
    static let lastPDFPath = "lastPDFPath.v1"
    static let viewStatePrefix = "viewState.v1"
}

private extension JSONEncoder {
    static var readerEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var readerDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
