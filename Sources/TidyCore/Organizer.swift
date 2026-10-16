import Foundation
import Darwin

public struct MovePlan: Identifiable, Codable, Sendable {
    public let id: UUID
    public let source: URL
    public let destination: URL
    public let fingerprint: Fingerprint
    public let root: URL
    public init(source: URL, destination: URL, fingerprint: Fingerprint, root: URL) {
        self.id = UUID(); self.source = source; self.destination = destination
        self.fingerprint = fingerprint; self.root = root
    }
}
public enum MoveState: String, Codable, Sendable {
    case pending, moved, failed, undoing, undone
    public var label: String {
        switch self {
        case .pending: return "확인 필요"
        case .moved: return "정리 완료"
        case .failed: return "이동 안 됨"
        case .undoing: return "복원 확인 필요"
        case .undone: return "되돌림"
        }
    }
}
public struct MoveRecord: Identifiable, Codable, Sendable {
    public var id: UUID { plan.id }
    public let plan: MovePlan
    public var state: MoveState
    public var note: String?
}
public struct MoveBatch: Identifiable, Codable, Sendable {
    public let id: UUID
    public let date: Date
    public var records: [MoveRecord]
}

public actor Organizer {
    private let journalURL: URL
    private var batches: [MoveBatch]
    private var busy = false
    public init(journalURL: URL) throws {
        self.journalURL = journalURL
        if FileManager.default.fileExists(atPath: journalURL.path) {
            do { batches = try JSONDecoder().decode([MoveBatch].self, from: Data(contentsOf: journalURL)) }
            catch { throw TidyError.message("정리 기록을 읽을 수 없어 이동 기능을 잠갔습니다. 기록 파일을 보존하고 확인해 주세요.\n\(journalURL.path)") }
        } else { batches = [] }
    }
    public func history() -> [MoveBatch] { batches.reversed() }
    private func save() throws {
        try FileManager.default.createDirectory(at: journalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(batches).write(to: journalURL, options: .atomic)
    }
    public func recover() throws {
        guard !busy else { return }
        var changed = false
        for b in batches.indices {
            for r in batches[b].records.indices {
                let item = batches[b].records[r]
                guard item.state == .pending || item.state == .undoing else { continue }
                let source = try? Fingerprint.read(item.plan.source)
                let destination = try? Fingerprint.read(item.plan.destination)
                if destination == item.plan.fingerprint && source == nil && !Self.exists(item.plan.source) {
                    batches[b].records[r].state = .moved
                    batches[b].records[r].note = "중단된 작업의 이동 결과를 확인했습니다."
                } else if source == item.plan.fingerprint && destination == nil && !Self.exists(item.plan.destination) {
                    batches[b].records[r].state = item.state == .undoing ? .undone : .failed
                    batches[b].records[r].note = "원래 위치에 파일이 있습니다."
                } else { batches[b].records[r].note = "중단된 작업입니다. 파일 위치 또는 내용이 달라 자동 복구하지 않았습니다." }
                changed = true
            }
        }
        if changed { try save() }
    }
    public static func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }
    public static func plans(for entries: [FileEntry], root: URL) -> [MovePlan] {
        makePlans(for: entries, root: root, folder: nil)
    }
    public static func plans(for entries: [FileEntry], root: URL, folderName: String) throws -> [MovePlan] {
        let folder = try destinationFolder(named: folderName, root: root)
        return makePlans(for: entries, root: root, folder: folder)
    }
    /// A destination is always one real directory directly inside the selected root.
    /// Resolving and validating it never creates it.
    public static func destinationFolder(named rawName: String, root: URL) throws -> URL {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
        guard !name.isEmpty else { throw TidyError.message("폴더 이름을 입력해 주세요.") }
        guard !name.hasPrefix("."), !name.contains("/"), !name.contains(":"), !name.contains("\\"),
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              name.utf8.count <= 255 else {
            throw TidyError.message("폴더 이름은 점으로 시작할 수 없고, / · : · \\ 또는 줄바꿈을 넣을 수 없어요. 255바이트 이내로 입력해 주세요.")
        }
        let folder = root.appendingPathComponent(name, isDirectory: true)
        guard !["app", "bundle", "framework", "pkg"].contains(folder.pathExtension.lowercased()) else {
            throw TidyError.message("앱이나 패키지 이름 대신 일반 폴더 이름을 사용해 주세요.")
        }
        try checkDirectory(root)
        if exists(folder) {
            try checkDirectory(folder)
            let values = try folder.resourceValues(forKeys: [.isPackageKey, .isAliasFileKey])
            guard values.isPackage != true, values.isAliasFile != true else { throw TidyError.message("앱·패키지·별칭 안에는 정리할 수 없어요.") }
        }
        return folder
    }
    public static func managedFolderNames(in history: [MoveBatch], root: URL) -> Set<String> {
        Set(history.flatMap(\.records).filter { record in
            record.state != .failed && record.plan.root.standardizedFileURL.path == root.standardizedFileURL.path &&
            record.plan.destination.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL.path == root.standardizedFileURL.path
        }.map { $0.plan.destination.deletingLastPathComponent().lastPathComponent })
    }
    private static func makePlans(for entries: [FileEntry], root: URL, folder customFolder: URL?) -> [MovePlan] {
        makePlans(for: entries.filter { customFolder == nil ? $0.canOrganize : $0.canMove }, root: root) {
            customFolder ?? root.appendingPathComponent($0.kind.rawValue, isDirectory: true)
        }
    }
    static func makePlans(for entries: [FileEntry], root: URL, destinationFolder: (FileEntry) -> URL) -> [MovePlan] {
        var reserved = Set<String>()
        return entries.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }.compactMap { entry in
            guard let fingerprint = entry.fingerprint else { return nil }
            let folder = destinationFolder(entry)
            var destination = folder.appendingPathComponent(entry.name)
            var n = 1
            while exists(destination) || reserved.contains(destination.path) {
                let ext = entry.url.pathExtension
                let stem = entry.url.deletingPathExtension().lastPathComponent
                destination = folder.appendingPathComponent("\(stem) (\(n))" + (ext.isEmpty ? "" : ".\(ext)"))
                n += 1
            }
            reserved.insert(destination.path)
            return MovePlan(source: entry.url, destination: destination, fingerprint: fingerprint, root: root)
        }
    }
    private func validate(_ plan: MovePlan) throws {
        let root = plan.root
        guard plan.source.deletingLastPathComponent().standardizedFileURL.path == root.standardizedFileURL.path,
              plan.destination.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL.path == root.standardizedFileURL.path,
              !FileKind.isTemporary(plan.source) else { throw TidyError.message("허용된 정리 경로가 아닙니다.") }
        let directory = plan.destination.deletingLastPathComponent()
        let checkedFolder = try Self.destinationFolder(named: directory.lastPathComponent, root: root)
        // The parent was checked above. Compare names here: Foundation may normalize
        // /private/tmp differently depending on whether the child exists yet.
        guard checkedFolder.lastPathComponent == directory.lastPathComponent else { throw TidyError.message("폴더 경로를 다시 확인해 주세요.") }
        guard try Fingerprint.read(plan.source) == plan.fingerprint else { throw TidyError.message("미리보기 이후 파일이 변경되었습니다. 다시 확인해 주세요.") }
        guard Date().timeIntervalSince(plan.fingerprint.modified) >= 3 else { throw TidyError.message("최근 변경 중인 파일입니다. 잠시 후 다시 시도하세요.") }
        guard !Self.exists(plan.destination) else { throw TidyError.message("이동할 위치에 같은 이름의 파일이 생겼습니다. 다시 미리보기해 주세요.") }
    }
    private static func checkDirectory(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              url.standardizedFileURL.path == url.resolvingSymlinksInPath().standardizedFileURL.path else {
            throw TidyError.message("폴더에 접근할 수 없거나 링크로 연결된 폴더입니다.")
        }
    }
    private static func moveExclusively(_ source: URL, _ destination: URL) throws {
        let result = source.withUnsafeFileSystemRepresentation { src in
            destination.withUnsafeFileSystemRepresentation { dst in renamex_np(src!, dst!, UInt32(RENAME_EXCL)) }
        }
        if result != 0 { throw TidyError.message("이동하지 못했습니다: \(String(cString: strerror(errno)))") }
    }
    public func execute(_ plans: [MovePlan]) async throws -> MoveBatch {
        guard !busy, !plans.isEmpty else { throw TidyError.message("다른 작업이 진행 중이거나 선택한 파일이 없습니다.") }
        busy = true; defer { busy = false }
        // Verify that the same files remain unchanged across an observation interval.
        var initialErrors: [UUID: String] = [:]
        for plan in plans { do { try validate(plan) } catch { initialErrors[plan.id] = error.localizedDescription } }
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let batch = MoveBatch(id: UUID(), date: Date(), records: plans.map { MoveRecord(plan: $0, state: .pending) })
        batches.append(batch)
        let b = batches.count - 1
        do { try save() } catch { batches.removeLast(); throw error }
        for r in batches[b].records.indices {
            let plan = batches[b].records[r].plan
            do {
                if Task.isCancelled { throw TidyError.message("사용자가 남은 작업을 중단했습니다.") }
                if let error = initialErrors[plan.id] { throw TidyError.message(error) }
                try validate(plan)
                let folder = plan.destination.deletingLastPathComponent()
                if !Self.exists(folder) { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false) }
                try Self.checkDirectory(folder)
                try Self.moveExclusively(plan.source, plan.destination)
                batches[b].records[r].state = .moved
            } catch {
                batches[b].records[r].state = .failed
                batches[b].records[r].note = error.localizedDescription
            }
            // Stop immediately if the journal becomes unwritable. Pending records recover on next launch.
            try save()
        }
        return batches[b]
    }
    public func undo(batchID: UUID) throws -> MoveBatch {
        guard !busy else { throw TidyError.message("다른 작업이 진행 중입니다.") }
        busy = true; defer { busy = false }
        guard let b = batches.firstIndex(where: { $0.id == batchID }) else { throw TidyError.message("정리 기록을 찾을 수 없습니다.") }
        for r in batches[b].records.indices where batches[b].records[r].state == .moved {
            let plan = batches[b].records[r].plan
            do {
                try Self.checkDirectory(plan.root)
                try Self.checkDirectory(plan.destination.deletingLastPathComponent())
                guard !Self.exists(plan.source) else { throw TidyError.message("원래 위치에 같은 이름의 파일이 있어 되돌리지 않았습니다.") }
                guard try Fingerprint.read(plan.destination) == plan.fingerprint else { throw TidyError.message("정리 후 파일이 변경되어 되돌리지 않았습니다.") }
            } catch {
                batches[b].records[r].note = error.localizedDescription
                try save()
                continue
            }
            batches[b].records[r].state = .undoing
            try save()
            do {
                try Self.moveExclusively(plan.destination, plan.source)
                batches[b].records[r].state = .undone
                batches[b].records[r].note = nil
            } catch {
                batches[b].records[r].state = .moved
                batches[b].records[r].note = error.localizedDescription
            }
            try save()
        }
        return batches[b]
    }
}
