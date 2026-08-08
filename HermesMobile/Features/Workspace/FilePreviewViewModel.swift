import Foundation
import UniformTypeIdentifiers

@Observable
final class FilePreviewViewModel {
    private let session: SessionSummary
    private let path: String
    private let apiClient: APIClient

    private(set) var preview: FilePreviewContent?
    private(set) var isLoading = false
    private(set) var isExporting = false
    private(set) var errorMessage: String?
    private(set) var exportErrorMessage: String?
    private(set) var lastError: Error?
    private var exportData: Data?

    /// A text fetch the file tree started on press-down; consumed by the first `load()`.
    private var prefetchedFile: Task<FileResponse, Error>?

    init(
        session: SessionSummary,
        server: URL,
        path: String,
        apiClient: APIClient? = nil,
        prefetchedFile: Task<FileResponse, Error>? = nil
    ) {
        self.session = session
        self.path = path
        self.apiClient = apiClient ?? APIClient(baseURL: server)
        self.prefetchedFile = prefetchedFile
    }

    /// True for paths that load through `/api/file` as text rather than as image or raw bytes.
    static func loadsTextPreview(forPath path: String) -> Bool {
        let pathExtension = pathExtension(of: path)
        return !rasterImageExtensions.contains(pathExtension) && !unsupportedBinaryExtensions.contains(pathExtension)
    }

    var canExportFile: Bool {
        session.sessionId?.isEmpty == false && !path.isEmpty
    }

    var canSaveImageToPhotos: Bool {
        canExportFile && isRasterImagePath
    }

    @MainActor
    func load() async {
        guard let sessionID = session.sessionId else {
            errorMessage = String(localized: "Session ID is missing.")
            return
        }

        guard !path.isEmpty else {
            errorMessage = String(localized: "File path is missing.")
            return
        }

        isLoading = true
        errorMessage = nil
        exportErrorMessage = nil
        lastError = nil

        do {
            if isRasterImagePath {
                let data = try await apiClient.rawFileData(sessionID: sessionID, path: path)
                exportData = data
                if let previewData = ImagePreviewDownsampler.previewData(
                    from: data,
                    maxPixelSize: ImagePreviewDownsampler.filePreviewMaxPixelSize
                ) {
                    preview = .image(.init(data: previewData, originalByteCount: data.count))
                } else {
                    preview = .unavailable(String(localized: "Could not decode this image."))
                }
            } else if isKnownUnsupportedBinaryPath {
                preview = .unavailable(String(localized: "Preview is not available for this file type."))
            } else {
                let prefetched = prefetchedFile
                prefetchedFile = nil
                let file: FileResponse
                if let prefetched, let result = try? await prefetched.value {
                    file = result
                } else {
                    file = try await apiClient.file(sessionID: sessionID, path: path)
                }
                exportData = Data((file.content ?? "").utf8)
                preview = .text(file)
            }
        } catch {
            lastError = error
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    @MainActor
    func exportPayload() async throws -> FileExportPayload {
        guard let sessionID = session.sessionId else {
            throw FileExportError.missingSessionID
        }

        guard !path.isEmpty else {
            throw FileExportError.missingPath
        }

        if let exportData {
            return payload(with: exportData)
        }

        isExporting = true
        exportErrorMessage = nil
        lastError = nil
        defer {
            isExporting = false
        }

        do {
            let data = try await apiClient.rawFileData(sessionID: sessionID, path: path)
            exportData = data
            return payload(with: data)
        } catch {
            lastError = error
            exportErrorMessage = error.localizedDescription
            throw error
        }
    }

    private static let rasterImageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "ico", "bmp"]

    private static let unsupportedBinaryExtensions: Set<String> = [
        "7z", "a", "aiff", "avi", "bin", "bz2", "class", "db", "dmg", "doc",
        "dylib", "exe", "flac", "gz", "jar", "m4a", "mov", "mp3",
        "mp4", "o", "pdf", "pkg", "ppt", "pyc", "rar", "sqlite",
        "svg", "tar", "tgz", "wav", "xls", "xz", "zip"
    ]

    private static func pathExtension(of path: String) -> String {
        URL(fileURLWithPath: path).pathExtension.lowercased()
    }

    private var pathExtension: String {
        Self.pathExtension(of: path)
    }

    private var isRasterImagePath: Bool {
        Self.rasterImageExtensions.contains(pathExtension)
    }

    /// Formats the app refuses to ask the server about at all.
    ///
    /// `docx` / `xlsx` / `pptx` are deliberately absent: the server extracts
    /// text from exactly those three (`CLAIMED_OFFICE_EXTENSIONS`,
    /// `api/office_documents.py` @ 399cd7ab), so blocking them here showed
    /// "not available" for files it could have read (#29). Their legacy binary
    /// counterparts `doc` / `xls` / `ppt` stay on the list — upstream claims
    /// only the OOXML ones. When the server lacks the Python libraries it
    /// answers with its own install hint, which is a more useful thing to show
    /// than a flat refusal.
    private var isKnownUnsupportedBinaryPath: Bool {
        Self.unsupportedBinaryExtensions.contains(pathExtension)
    }

    private func payload(with data: Data) -> FileExportPayload {
        FileExportPayload(
            data: data,
            filename: exportFilename,
            contentType: UTType(filenameExtension: pathExtension) ?? .data,
            isImage: isRasterImagePath,
            isVideo: isVideoPath
        )
    }

    private var isVideoPath: Bool {
        ["m4v", "mov", "mp4"].contains(pathExtension)
    }

    private var exportFilename: String {
        let lastPathComponent = URL(fileURLWithPath: path).lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        return lastPathComponent.isEmpty ? String(localized: "Hermes File") : lastPathComponent
    }
}

enum FilePreviewContent {
    case text(FileResponse)
    case image(ImageFilePreview)
    case audio(Data)
    case unavailable(String)
}

struct ImageFilePreview {
    let data: Data
    let originalByteCount: Int
}

struct FileExportPayload {
    let data: Data
    let filename: String
    let contentType: UTType
    let isImage: Bool
    let isVideo: Bool
}

enum FileExportError: LocalizedError {
    case missingSessionID
    case missingPath

    var errorDescription: String? {
        switch self {
        case .missingSessionID:
            String(localized: "Session ID is missing.")
        case .missingPath:
            String(localized: "File path is missing.")
        }
    }
}
