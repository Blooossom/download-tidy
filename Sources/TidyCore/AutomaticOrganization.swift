import Foundation

public struct AutomaticRule: Codable, Equatable, Sendable {
    public let kind: FileKind
    public var enabled: Bool
    public var folderName: String

    public static var defaults: [Self] {
        FileKind.allCases.filter(\.canOrganize).map { Self(kind: $0, enabled: true, folderName: $0.rawValue) }
    }
}

/// Rules belong to the selected root, so changing folders never reuses another folder's choices.
public struct AutomaticRuleStore: Codable, Sendable {
    private var folders: [String: [AutomaticRule]] = [:]
    public init() {}
    public static func load(from url: URL) throws -> Self {
        guard Organizer.exists(url) else { return Self() }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }
    public func rules(for root: URL) -> [AutomaticRule] {
        folders[root.standardizedFileURL.path] ?? AutomaticRule.defaults
    }
    public mutating func save(_ rules: [AutomaticRule], for root: URL, to url: URL) throws {
        try AutomaticOrganization.validate(rules, root: root)
        var updated = self
        updated.folders[root.standardizedFileURL.path] = rules
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(updated).write(to: url, options: .atomic)
        self = updated
    }
}

public enum AutomaticOrganization {
    public static func validate(_ rules: [AutomaticRule], root: URL) throws {
        let kinds = rules.map(\.kind)
        guard kinds.count == AutomaticRule.defaults.count,
              Set(kinds) == Set(AutomaticRule.defaults.map(\.kind)) else {
            throw TidyError.message("자동정리 설정을 읽을 수 없어요. 분류별 설정을 다시 확인해 주세요.")
        }
        for rule in rules where rule.enabled {
            do { _ = try Organizer.destinationFolder(named: rule.folderName, root: root) }
            catch { throw TidyError.message("\(rule.kind.rawValue): \(error.localizedDescription)") }
        }
    }
    public static func plans(for entries: [FileEntry], root: URL, rules: [AutomaticRule]) throws -> [MovePlan] {
        try validate(rules, root: root)
        let destinations = try Dictionary(uniqueKeysWithValues: rules.filter(\.enabled).map {
            ($0.kind, try Organizer.destinationFolder(named: $0.folderName, root: root))
        })
        return Organizer.makePlans(for: entries.filter { $0.canOrganize && destinations[$0.kind] != nil }, root: root) {
            destinations[$0.kind]!
        }
    }
}
