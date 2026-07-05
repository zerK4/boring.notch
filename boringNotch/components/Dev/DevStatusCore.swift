//
//  DevStatusCore.swift
//  boringNotch
//
//  Local-first repository discovery and selection helpers for Dev Mode.
//

import Foundation

struct DevRepositoryCandidate: Equatable, Identifiable {
    var id: String { path.path }
    let path: URL
    let name: String
    let latestSourceModification: Date
    let dirtyCount: Int
}

struct DevRepositoryStatus: Equatable {
    let candidate: DevRepositoryCandidate
    let branch: String
    let dirtyCount: Int
    let lastCommitShortHash: String
    let updatedAt: Date

    var displayName: String { candidate.name }
    var hasChanges: Bool { dirtyCount > 0 }
}

enum DevRepositorySelector {
    static func mostRecentlyModified(_ repositories: [DevRepositoryCandidate]) -> DevRepositoryCandidate? {
        repositories.max { lhs, rhs in
            if lhs.latestSourceModification == rhs.latestSourceModification {
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedDescending
            }
            return lhs.latestSourceModification < rhs.latestSourceModification
        }
    }
}

struct DevGitMetadata: Equatable {
    let branch: String?
    let shortHash: String?
}

enum DevGitMetadataReader {
    static func metadata(for repository: URL) -> DevGitMetadata {
        let gitPath = resolvedGitPath(for: repository)
        guard let gitPath else { return DevGitMetadata(branch: nil, shortHash: nil) }

        let headURL = gitPath.appendingPathComponent("HEAD")
        guard let head = try? String(contentsOf: headURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !head.isEmpty else {
            return DevGitMetadata(branch: nil, shortHash: nil)
        }

        if head.hasPrefix("ref: ") {
            let ref = String(head.dropFirst(5))
            let branch = ref.replacingOccurrences(of: "refs/heads/", with: "")
            let hash = readHash(for: ref, gitPath: gitPath)
            return DevGitMetadata(branch: branch.nilIfBlank, shortHash: hash?.shortHash)
        }

        return DevGitMetadata(branch: "detached", shortHash: head.shortHash)
    }

    private static func resolvedGitPath(for repository: URL) -> URL? {
        let dotGit = repository.appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) {
            if isDirectory.boolValue { return dotGit }

            if let content = try? String(contentsOf: dotGit, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
               content.hasPrefix("gitdir: ") {
                let rawPath = String(content.dropFirst(8))
                if rawPath.hasPrefix("/") {
                    return URL(fileURLWithPath: rawPath)
                }
                return repository.appendingPathComponent(rawPath).standardizedFileURL
            }
        }
        return nil
    }

    private static func readHash(for ref: String, gitPath: URL) -> String? {
        let looseRefURL = gitPath.appendingPathComponent(ref)
        if let hash = try? String(contentsOf: looseRefURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !hash.isEmpty {
            return hash
        }

        let packedRefsURL = gitPath.appendingPathComponent("packed-refs")
        guard let packedRefs = try? String(contentsOf: packedRefsURL, encoding: .utf8) else { return nil }
        for line in packedRefs.split(whereSeparator: \.isNewline) {
            guard !line.hasPrefix("#"), !line.hasPrefix("^") else { continue }
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            if parts.count == 2, parts[1] == ref {
                return parts[0]
            }
        }
        return nil
    }
}

enum DevRepositoryScanner {
    static let ignoredDirectoryNames: Set<String> = [
        ".git", ".build", ".cache", ".dart_tool", ".gradle", ".next", ".nuxt", ".parcel-cache",
        ".serverless", ".svelte-kit", ".swiftpm", ".turbo", ".venv", "Build", "DerivedData",
        "Pods", "build", "coverage", "dist", "node_modules", "target", "vendor", "venv"
    ]

    static let sourceExtensions: Set<String> = [
        "c", "cc", "cpp", "css", "go", "h", "hpp", "html", "java", "js", "json", "jsx", "kt",
        "md", "m", "mm", "php", "plist", "py", "rb", "rs", "scss", "sh", "swift", "ts", "tsx",
        "vue", "xib", "xml", "yaml", "yml"
    ]

    static func shouldIgnoreDirectory(named name: String) -> Bool {
        ignoredDirectoryNames.contains(name)
    }

    static func discoverRepositories(in root: URL, maxDepth: Int = 8, maxRepositories: Int = 120) -> [URL] {
        let root = root.standardizedFileURL
        var repositories: [URL] = []

        if FileManager.default.fileExists(atPath: root.appendingPathComponent(".git", isDirectory: true).path) {
            repositories.append(root)
        }

        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isHiddenKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        for case let url as URL in enumerator {
            if repositories.count >= maxRepositories { break }
            let name = url.lastPathComponent
            let depth = pathDepth(from: root, to: url)
            if depth > maxDepth {
                enumerator.skipDescendants()
                continue
            }

            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isHiddenKey])
            guard values?.isDirectory == true else { continue }

            if shouldIgnoreDirectory(named: name) {
                enumerator.skipDescendants()
                continue
            }

            let gitDirectory = url.appendingPathComponent(".git", isDirectory: true)
            if FileManager.default.fileExists(atPath: gitDirectory.path) {
                repositories.append(url)
                enumerator.skipDescendants()
            }
        }

        return repositories.sorted { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }
    }

    static func candidate(for repository: URL, inspectedFileLimit: Int = 1_500) -> DevRepositoryCandidate {
        DevRepositoryCandidate(
            path: repository.standardizedFileURL,
            name: repository.lastPathComponent,
            latestSourceModification: latestSourceModification(in: repository, inspectedFileLimit: inspectedFileLimit),
            dirtyCount: 0
        )
    }

    static func latestSourceModification(in repository: URL, inspectedFileLimit: Int = 1_500) -> Date {
        var latest = (try? repository.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        var inspected = 0

        guard let enumerator = FileManager.default.enumerator(
            at: repository,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return latest }

        for case let url as URL in enumerator {
            if inspected >= inspectedFileLimit { break }
            let name = url.lastPathComponent
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])

            if values?.isDirectory == true {
                if shouldIgnoreDirectory(named: name) {
                    enumerator.skipDescendants()
                }
                continue
            }

            let ext = url.pathExtension.lowercased()
            guard ext.isEmpty || sourceExtensions.contains(ext) else { continue }
            inspected += 1
            if let modified = values?.contentModificationDate, modified > latest {
                latest = modified
            }
        }

        return latest
    }

    private static func pathDepth(from root: URL, to url: URL) -> Int {
        let rootComponents = root.standardizedFileURL.pathComponents
        let urlComponents = url.standardizedFileURL.pathComponents
        return max(0, urlComponents.count - rootComponents.count)
    }
}

private extension String {
    var nilIfBlank: String? {
        isEmpty ? nil : self
    }

    var shortHash: String {
        String(prefix(7))
    }
}
