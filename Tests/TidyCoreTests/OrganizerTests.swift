import Testing
import Foundation
@testable import TidyCore

@Suite(.serialized)
final class OrganizerTests {
    private var cleanup: [URL] = []
    deinit { for url in cleanup { try? FileManager.default.removeItem(at: url) } }
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("download-tidy-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        cleanup.append(root)
        return root
    }
    @discardableResult
    private func file(_ root: URL, _ name: String, _ content: String = "sample") throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data(content.utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -10)], ofItemAtPath: url.path)
        return url
    }
    private func organizer(_ root: URL) throws -> Organizer { try Organizer(journalURL: root.appendingPathComponent(".state/history.json")) }

    @Test func testClassificationAndReadOnlyScan() throws {
        let root = try fixture()
        for name in ["photo.JPG", "report.hwpx", "archive.zip", "setup.dmg", "clip.mp4", "music.flac", "unknown.xyz", "partial.zip.crdownload", "~$locked.xlsx", ".hidden.txt"] { try file(root, name) }
        let nested = root.appendingPathComponent("existing")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try file(nested, "inside.pdf")
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link.pdf"), withDestinationURL: root.appendingPathComponent("photo.JPG"))
        let entries = try Catalog.scan(root)
        let plans = Organizer.plans(for: entries, root: root)
        expectEqual(plans.count, 6)
        expectEqual(entries.first { $0.name == "report.hwpx" }?.kind, .document)
        expectFalse(entries.contains { $0.name == "inside.pdf" || $0.name == "link.pdf" || $0.name == ".hidden.txt" })
        expectFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("문서").path))
        expectTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("photo.JPG").path))
    }
    @Test func testMovePersistAndUndoWithoutOverwrite() async throws {
        let root = try fixture()
        let original = try file(root, "report.txt", "important original")
        let directory = root.appendingPathComponent("문서")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let occupied = try file(directory, "report.txt", "existing file")
        let plans = Organizer.plans(for: try Catalog.scan(root), root: root)
        expectEqual(plans.count, 1)
        expectEqual(plans[0].destination.lastPathComponent, "report (1).txt")
        let store = try organizer(root)
        let batch = try await store.execute(plans)
        expectEqual(batch.records[0].state, .moved)
        expectEqual(try String(contentsOf: occupied, encoding: .utf8), "existing file")
        expectFalse(FileManager.default.fileExists(atPath: original.path))
        let organized = try Catalog.scan(root).first { $0.url.standardizedFileURL.path == plans[0].destination.standardizedFileURL.path }
        expectEqual(organized?.organized, true)
        expectEqual(organized?.canOrganize, false)
        let reopened = try organizer(root)
        let persisted = await reopened.history()
        expectEqual(persisted.count, 1)
        let undo = try await reopened.undo(batchID: batch.id)
        expectEqual(undo.records[0].state, .undone)
        expectEqual(try String(contentsOf: original, encoding: .utf8), "important original")
        let twice = try await reopened.undo(batchID: batch.id)
        expectEqual(twice.records[0].state, .undone)
    }
    @Test func testStaleSourceAndLateCollisionAreSkipped() async throws {
        let root = try fixture()
        try file(root, "one.txt"); try file(root, "two.txt"); try file(root, "three.txt")
        let plans = Organizer.plans(for: try Catalog.scan(root), root: root)
        try file(root, "one.txt", "changed after review")
        let folder = root.appendingPathComponent("문서")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try file(folder, "two.txt", "late collision")
        let result = try await organizer(root).execute(plans)
        expectEqual(result.records.filter { $0.state == .moved }.count, 1)
        expectEqual(result.records.filter { $0.state == .failed }.count, 2)
        expectEqual(try String(contentsOf: folder.appendingPathComponent("two.txt"), encoding: .utf8), "late collision")
        expectTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("one.txt").path))
    }
    @Test func testUndoProtectsChangedFilesAndOccupiedOriginals() async throws {
        let root = try fixture()
        try file(root, "one.txt"); try file(root, "two.txt")
        let plans = Organizer.plans(for: try Catalog.scan(root), root: root)
        let store = try organizer(root)
        let moved = try await store.execute(plans)
        try file(root, "one.txt", "new original")
        try file(root.appendingPathComponent("문서"), "two.txt", "edited after move")
        let undone = try await store.undo(batchID: moved.id)
        expectTrue(undone.records.allSatisfy { $0.state == .moved && $0.note != nil })
        expectEqual(try String(contentsOf: root.appendingPathComponent("one.txt"), encoding: .utf8), "new original")
        expectEqual(try String(contentsOf: root.appendingPathComponent("문서/two.txt"), encoding: .utf8), "edited after move")
    }
    @Test func testSymlinkDestinationCannotEscapeRoot() async throws {
        let root = try fixture(); let outside = try fixture()
        try file(root, "one.txt")
        let plans = Organizer.plans(for: try Catalog.scan(root), root: root)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("문서"), withDestinationURL: outside)
        let result = try await organizer(root).execute(plans)
        expectEqual(result.records[0].state, .failed)
        expectTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }
    @Test func testJournalFailurePreventsMoving() async throws {
        let root = try fixture()
        let source = try file(root, "one.txt")
        let block = try file(root, "not-a-directory")
        let store = try Organizer(journalURL: block.appendingPathComponent("history.json"))
        do { _ = try await store.execute(Organizer.plans(for: try Catalog.scan(root), root: root)); fail("Must fail before moving") } catch {}
        expectTrue(FileManager.default.fileExists(atPath: source.path))
    }
    @Test func testCorruptJournalIsPreserved() throws {
        let root = try fixture()
        let journal = try file(root, "history.json", "broken-data")
        expectThrows(try Organizer(journalURL: journal))
        expectEqual(try String(contentsOf: journal, encoding: .utf8), "broken-data")
    }
    @Test func testInterruptedMoveAndUndoRecovery() async throws {
        let root = try fixture()
        try file(root, "one.txt")
        let plan = Organizer.plans(for: try Catalog.scan(root), root: root)[0]
        try FileManager.default.createDirectory(at: plan.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: plan.source, to: plan.destination)
        let journal = root.appendingPathComponent("history.json")
        let interrupted = MoveBatch(id: UUID(), date: Date(), records: [MoveRecord(plan: plan, state: .pending)])
        try JSONEncoder().encode([interrupted]).write(to: journal)
        let store = try Organizer(journalURL: journal)
        try await store.recover()
        let recovered = await store.history()
        expectEqual(recovered[0].records[0].state, .moved)
        try FileManager.default.moveItem(at: plan.destination, to: plan.source)
        let undoing = MoveBatch(id: interrupted.id, date: Date(), records: [MoveRecord(plan: plan, state: .undoing)])
        try JSONEncoder().encode([undoing]).write(to: journal)
        let restarted = try Organizer(journalURL: journal)
        try await restarted.recover()
        let restored = await restarted.history()
        expectEqual(restored[0].records[0].state, .undone)
    }
    @Test func testContentSearchAndKoreanNormalization() async throws {
        let root = try fixture()
        let decomposed = "견적서.txt".decomposedStringWithCanonicalMapping
        try file(root, decomposed, "프로젝트 예산은 삼백만원입니다.")
        let entries = try Catalog.scan(root)
        expectTrue(entries[0].name.localizedStandardContains("견적서"))
        let index = ContentIndex()
        let result = await index.search("삼백만원", in: entries)
        expectEqual(result, Set(entries.map(\.id)))
        try file(root, decomposed, "내용을 수정했습니다.")
        let changed = await index.search("삼백만원", in: try Catalog.scan(root))
        expectTrue(changed.isEmpty)
    }
    @Test func testDownloadAndRecentFileNotPlanned() throws {
        let root = try fixture()
        try file(root, "file.pdf.part")
        let recent = root.appendingPathComponent("recent.txt")
        try Data("still downloading".utf8).write(to: recent)
        let entries = try Catalog.scan(root)
        expectTrue(Organizer.plans(for: entries, root: root).isEmpty)
    }
}

private func expectEqual<T: Equatable>(_ a: T, _ b: T, sourceLocation: SourceLocation = #_sourceLocation) { #expect(a == b, sourceLocation: sourceLocation) }
private func expectTrue(_ value: Bool, sourceLocation: SourceLocation = #_sourceLocation) { #expect(value, sourceLocation: sourceLocation) }
private func expectFalse(_ value: Bool, sourceLocation: SourceLocation = #_sourceLocation) { #expect(!value, sourceLocation: sourceLocation) }
private func fail(_ message: String, sourceLocation: SourceLocation = #_sourceLocation) { Issue.record(Comment(rawValue: message), sourceLocation: sourceLocation) }
private func expectThrows<T>(_ expression: @autoclosure () throws -> T, sourceLocation: SourceLocation = #_sourceLocation) {
    do { _ = try expression(); Issue.record("Expected an error", sourceLocation: sourceLocation) } catch {}
}
