import CryptoKit
import Foundation

// MARK: - Model

enum CommentAnchorKind: String, Codable, Sendable {
    case text
    case region
}

enum CommentStatus: String, Codable, Sendable {
    case open
    case resolved
}

enum CommentAuthor: String, Codable, Sendable {
    case human
    case agent
}

struct CommentRect: Codable, Sendable, Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
}

struct CommentAnchor: Codable, Sendable, Equatable {
    var kind: CommentAnchorKind
    var page: Int                 // 1-based
    var quote: String?
    var bounds: CommentRect?      // PDF page coordinates (text bbox or region rect)
    var imagePNGBase64: String?   // region snapshot, for multimodal agents
}

struct CommentMessage: Codable, Sendable, Identifiable, Equatable {
    var id: String
    var author: CommentAuthor
    var agentName: String?
    var body: String
    var createdAt: Date
}

struct CommentThread: Codable, Sendable, Identifiable, Equatable {
    var id: String
    var documentPath: String
    var anchor: CommentAnchor
    var status: CommentStatus
    var createdAt: Date
    var updatedAt: Date
    var messages: [CommentMessage]
    /// Experimental agent-CLI feature: engine key (`AgentEngineKind.rawValue`)
    /// → resumable CLI session id. Optional so pre-existing sidecar files decode.
    var agentSessions: [String: String]? = nil
    /// Experimental agent-CLI feature: engine key of the sticky "answer with"
    /// selection — new human replies auto-trigger this engine. Optional so
    /// pre-existing sidecar files decode.
    var autoAnswerEngine: String? = nil
}

// MARK: - Sidecar store

/// Persists comment threads in a sidecar JSON file per document, keyed by the
/// document's path SHA (same scheme as `PDFDocumentStateStore.documentKey`), so
/// the PDF itself is never mutated. File:
/// ~/Library/Application Support/SimplePDF/comments/<key>.json
struct CommentStore {
    private let fileManager: FileManager
    private let directory: URL?

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let base = try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = base?
            .appendingPathComponent("SimplePDF", isDirectory: true)
            .appendingPathComponent("comments", isDirectory: true)
        if let directory {
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        self.directory = directory
    }

    func loadThreads(forDocumentAt url: URL) -> [CommentThread] {
        guard
            let fileURL = fileURL(for: url),
            let data = try? Data(contentsOf: fileURL),
            let threads = try? JSONDecoder.commentDecoder.decode([CommentThread].self, from: data)
        else {
            return []
        }
        return threads
    }

    func saveThreads(_ threads: [CommentThread], forDocumentAt url: URL) {
        guard let fileURL = fileURL(for: url) else { return }
        guard let data = try? JSONEncoder.commentEncoder.encode(threads) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private func fileURL(for url: URL) -> URL? {
        directory?.appendingPathComponent("\(key(for: url)).json")
    }

    private func key(for url: URL) -> String {
        let path = url.standardizedFileURL.path
        let digest = SHA256.hash(data: Data(path.utf8))
        return digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}

private extension JSONEncoder {
    static var commentEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var commentDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
