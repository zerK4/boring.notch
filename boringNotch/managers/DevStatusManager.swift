//
//  DevStatusManager.swift
//  boringNotch
//
//  Watches the configured projects root and surfaces the most recently touched Git repository.
//

import Combine
import CoreServices
import Defaults
import Foundation

@MainActor
final class DevStatusManager: ObservableObject {
    static let shared = DevStatusManager()

    @Published private(set) var activeStatus: DevRepositoryStatus?
    @Published private(set) var repositories: [DevRepositoryCandidate] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastError: String?

    private var stream: FSEventStreamRef?
    private var refreshTask: Task<Void, Never>?
    private var settingsCancellables: Set<AnyCancellable> = []

    private init() {
        Defaults.publisher(.devModeEnabled)
            .sink { [weak self] change in
                Task { @MainActor in
                    change.newValue ? self?.start() : self?.stop()
                }
            }
            .store(in: &settingsCancellables)

        Defaults.publisher(.devProjectsRoot)
            .sink { [weak self] _ in
                Task { @MainActor in
                    guard Defaults[.devModeEnabled] else { return }
                    self?.restartWatcher()
                }
            }
            .store(in: &settingsCancellables)

        if Defaults[.devModeEnabled] {
            start()
        }
    }

    deinit {
        stream.map { FSEventStreamStop($0); FSEventStreamInvalidate($0); FSEventStreamRelease($0) }
        refreshTask?.cancel()
    }

    func start() {
        restartWatcher()
    }

    func stop() {
        refreshTask?.cancel()
        refreshTask = nil
        stopWatcher()
        isRefreshing = false
    }

    func refreshNow() {
        scheduleRefresh(after: 0)
    }

    private func restartWatcher() {
        stopWatcher()
        startWatcher()
        scheduleRefresh(after: 0)
    }

    private func startWatcher() {
        let root = configuredRootURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            lastError = "Projects folder not found: \(root.path)"
            return
        }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, clientInfo, _, _, _, _ in
            guard let clientInfo else { return }
            let manager = Unmanaged<DevStatusManager>.fromOpaque(clientInfo).takeUnretainedValue()
            Task { @MainActor in
                manager.scheduleRefresh(after: 1.5)
            }
        }

        stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [root.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            2.0,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents)
        )

        if let stream {
            FSEventStreamScheduleWithRunLoop(stream, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            FSEventStreamStart(stream)
        }
    }

    private func stopWatcher() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private func scheduleRefresh(after delay: TimeInterval) {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            if delay > 0 {
                try? await Task.sleep(for: .seconds(delay))
            }
            await self.refresh()
        }
    }

    private func refresh() async {
        guard Defaults[.devModeEnabled] else { return }
        let root = configuredRootURL
        isRefreshing = true
        lastError = nil

        let result = await Task.detached(priority: .utility) { () -> Result<(repositories: [DevRepositoryCandidate], status: DevRepositoryStatus?), Error> in
            let repoURLs = DevRepositoryScanner.discoverRepositories(in: root)
            let candidates = repoURLs.map { DevRepositoryScanner.candidate(for: $0) }
            guard let active = DevRepositorySelector.mostRecentlyModified(candidates) else {
                return .success((candidates, nil))
            }

            let metadata = DevGitMetadataReader.metadata(for: active.path)
            let branch = Self.gitOutput(["branch", "--show-current"], in: active.path).nilIfBlank
                ?? Self.gitOutput(["rev-parse", "--abbrev-ref", "HEAD"], in: active.path).nilIfBlank
                ?? metadata.branch
                ?? "detached"
            let dirty = Self.gitOutput(["status", "--porcelain"], in: active.path)
                .split(whereSeparator: \.isNewline)
                .count
            let hash = Self.gitOutput(["log", "-1", "--format=%h"], in: active.path).nilIfBlank
                ?? metadata.shortHash
                ?? "—"
            let status = DevRepositoryStatus(
                candidate: DevRepositoryCandidate(
                    path: active.path,
                    name: active.name,
                    latestSourceModification: active.latestSourceModification,
                    dirtyCount: dirty
                ),
                branch: branch,
                dirtyCount: dirty,
                lastCommitShortHash: hash,
                updatedAt: Date()
            )
            return .success((candidates, status))
        }.value

        switch result {
        case .success(let payload):
            repositories = payload.repositories
            activeStatus = payload.status
        case .failure(let error):
            lastError = error.localizedDescription
        }

        isRefreshing = false
    }

    private var configuredRootURL: URL {
        let raw = Defaults[.devProjectsRoot].trimmingCharacters(in: .whitespacesAndNewlines)
        let expanded = (raw as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded, isDirectory: true)
    }

    nonisolated private static func gitOutput(_ arguments: [String], in repository: URL) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", repository.path] + arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return "" }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        } catch {
            return ""
        }
    }
}

private extension String {
    var nilIfBlank: String? {
        isEmpty ? nil : self
    }
}
