import Foundation
import Darwin
import PDFKit

public enum FileKind: String, CaseIterable, Codable, Sendable {
    case document = "문서", image = "이미지", video = "동영상", audio = "오디오"
    case archive = "압축파일", installer = "설치파일", other = "기타", folder = "폴더"
    public var symbol: String {
        switch self {
        case .document: return "doc.text"
        case .image: return "photo"
        case .video: return "film"
        case .audio: return "waveform"
        case .archive: return "archivebox"
        case .installer: return "shippingbox"
        case .other: return "doc"
        case .folder: return "folder"
        }
    }
    public var canOrganize: Bool { self != .other && self != .folder }
    public static func classify(_ url: URL) -> Self {
        let ext = url.pathExtension.lowercased()
        if ["pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "txt", "md", "csv", "tsv", "rtf", "hwp", "hwpx", "pages", "numbers", "key", "odt"].contains(ext) { return .document }
        if ["png", "jpg", "jpeg", "webp", "gif", "heic", "heif", "svg", "tif", "tiff", "bmp", "avif", "psd"].contains(ext) { return .image }
        if ["mp4", "mov", "mkv", "webm", "avi", "m4v"].contains(ext) { return .video }
        if ["mp3", "m4a", "wav", "flac", "aac", "ogg", "aiff"].contains(ext) { return .audio }
        if ["zip", "7z", "rar", "tar", "gz", "bz2", "xz", "tgz"].contains(ext) { return .archive }
        if ["dmg", "pkg", "exe", "msi"].contains(ext) { return .installer }
        return .other
    }
    public static func isTemporary(_ url: URL) -> Bool {
        ["download", "crdownload", "part", "partial", "tmp", "temp"].contains(url.pathExtension.lowercased()) || url.lastPathComponent.hasPrefix("~$")
    }
}

public struct Fingerprint: Codable, Equatable, Sendable {
    public let device: Int32
    public let inode: UInt64
    public let size: Int64
    public let modifiedSeconds: Int64
    public let modifiedNanos: Int64
    public let birthSeconds: Int64
    public let birthNanos: Int64
    public static func read(_ url: URL, requireRegular: Bool = true) throws -> Self {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw TidyError.message("파일을 읽을 수 없습니다: \(url.lastPathComponent)") }
        guard (info.st_mode & S_IFMT) != S_IFLNK else { throw TidyError.message("심볼릭 링크는 제외합니다.") }
        if requireRegular && (info.st_mode & S_IFMT) != S_IFREG { throw TidyError.message("일반 파일만 정리할 수 있습니다.") }
        if info.st_flags & UInt32(UF_IMMUTABLE | SF_IMMUTABLE | UF_APPEND | SF_APPEND) != 0 { throw TidyError.message("잠긴 파일입니다.") }
        return Self(device: info.st_dev, inode: info.st_ino, size: info.st_size,
                    modifiedSeconds: Int64(info.st_mtimespec.tv_sec), modifiedNanos: Int64(info.st_mtimespec.tv_nsec),
                    birthSeconds: Int64(info.st_birthtimespec.tv_sec), birthNanos: Int64(info.st_birthtimespec.tv_nsec))
    }
    public var modified: Date { Date(timeIntervalSince1970: Double(modifiedSeconds) + Double(modifiedNanos) / 1_000_000_000) }
}

public enum TidyError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
}

public struct FileEntry: Identifiable, Sendable {
    public var id: String { url.path }
    public let url: URL
    public let kind: FileKind
    public let size: Int64
    public let added: Date
    public let modified: Date
    public let fingerprint: Fingerprint?
    public let organized: Bool
    public let exclusion: String?
    public var name: String { url.lastPathComponent }
    public var canMove: Bool { kind != .folder && !organized && exclusion == nil && fingerprint != nil }
    public var canOrganize: Bool { kind.canOrganize && canMove }
}

public enum Catalog {
    public static func scan(_ root: URL, organizedFolders: Set<String> = []) throws -> [FileEntry] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isAliasFileKey, .isPackageKey, .fileSizeKey, .addedToDirectoryDateKey, .creationDateKey, .contentModificationDateKey]
        let children = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        var result: [FileEntry] = []
        func append(_ url: URL, organized: Bool) {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isSymbolicLink != true, values.isAliasFile != true else { return }
            let isFolder = values.isDirectory == true
            let kind: FileKind = isFolder ? .folder : .classify(url)
            let fingerprint = isFolder ? nil : try? Fingerprint.read(url)
            let modified = values.contentModificationDate ?? .distantPast
            var exclusion: String?
            if FileKind.isTemporary(url) { exclusion = "다운로드 중 또는 임시 파일" }
            else if !isFolder && fingerprint == nil { exclusion = "잠김 또는 접근 제한" }
            else if !isFolder && Date().timeIntervalSince(modified) < 3 { exclusion = "최근 변경됨 · 잠시 후 새로고침" }
            result.append(FileEntry(url: url, kind: kind, size: Int64(values.fileSize ?? 0),
                                    added: values.addedToDirectoryDate ?? values.creationDate ?? modified,
                                    modified: modified, fingerprint: fingerprint, organized: organized, exclusion: exclusion))
        }
        for url in children {
            append(url, organized: false)
            if (organizedFolders.contains(url.lastPathComponent) || FileKind.allCases.contains(where: { $0.canOrganize && $0.rawValue == url.lastPathComponent })),
               let values = try? url.resourceValues(forKeys: Set(keys)), values.isDirectory == true,
               values.isSymbolicLink != true, values.isAliasFile != true, values.isPackage != true,
               let nested = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) {
                for item in nested { append(item, organized: true) }
            }
        }
        return result.sorted { $0.added > $1.added }
    }
}

// Content stays in memory. Large documents are deliberately bounded to keep browsing responsive.
public actor ContentIndex {
    private var cache: [String: (Fingerprint, String)] = [:]
    public init() {}
    public func search(_ query: String, in entries: [FileEntry]) -> Set<String> {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        var matches = Set<String>()
        let valid = Set(entries.map(\.id))
        cache = cache.filter { valid.contains($0.key) }
        for entry in entries {
            if Task.isCancelled { break }
            if entry.name.localizedStandardContains(needle) { continue }
            guard let fingerprint = entry.fingerprint, entry.exclusion == nil else { continue }
            let content: String
            if let cached = cache[entry.id], cached.0 == fingerprint { content = cached.1 }
            else {
                content = Self.extract(entry)
                cache[entry.id] = (fingerprint, content)
            }
            if content.localizedStandardContains(needle) { matches.insert(entry.id) }
        }
        return matches
    }
    static func extract(_ entry: FileEntry) -> String {
        let ext = entry.url.pathExtension.lowercased()
        if ext == "pdf", entry.size <= 20 * 1024 * 1024, let pdf = PDFDocument(url: entry.url) {
            var text = ""
            for page in 0..<min(pdf.pageCount, 80) {
                if Task.isCancelled || text.count > 500_000 { break }
                text += pdf.page(at: page)?.string ?? ""
                text += "\n"
            }
            return text
        }
        if ["txt", "md", "csv", "tsv", "log"].contains(ext), entry.size <= 1024 * 1024 {
            return (try? String(contentsOf: entry.url, encoding: .utf8)) ?? ""
        }
        return ""
    }
}
