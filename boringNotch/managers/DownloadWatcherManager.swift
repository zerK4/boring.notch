//
//  DownloadWatcherManager.swift
//  boringNotch
//
//  Lightweight Downloads folder watcher for browser download progress/completion.
//

import AppKit
import Combine
import Darwin
import Defaults
import Foundation

struct DownloadWatcherSnapshot: Equatable {
    enum State: Equatable {
        case none
        case inProgress
        case completed
        case failed
    }

    let fileName: String
    let fileURL: URL?
    let browserName: String
    let browserBundleID: String?
    let bytes: Int64
    let state: State
    let updatedAt: Date

    var isVisible: Bool { state != .none }

    var title: String {
        switch state {
        case .none: return "No downloads"
        case .inProgress: return "Downloading"
        case .completed: return "Download complete"
        case .failed: return "Download failed"
        }
    }

    var subtitle: String {
        if fileName.isEmpty { return browserName }
        if bytes > 0 { return "\(formattedBytes) · \(fileName)" }
        return fileName
    }

    var formattedBytes: String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static let empty = DownloadWatcherSnapshot(
        fileName: "",
        fileURL: nil,
        browserName: "Browser",
        browserBundleID: nil,
        bytes: 0,
        state: .none,
        updatedAt: Date()
    )
}

@MainActor
final class DownloadWatcherManager: ObservableObject {
    static let shared = DownloadWatcherManager()

    @Published private(set) var snapshot: DownloadWatcherSnapshot = .empty
    @Published private(set) var lastError: String?

    private var timer: Timer?
    private var clearTask: Task<Void, Never>?
    private var settingsCancellables: Set<AnyCancellable> = []
    private var seenCompletedFiles: Set<String> = []
    private var partialObservations: [String: PartialObservation] = [:]

    private let partialExtensions = ["download", "crdownload", "part", "opdownload", "tmp"]
    private let failedPartialAge: TimeInterval = 12

    private init() {
        Defaults.publisher(.downloadWatcherEnabled)
            .sink { [weak self] change in
                Task { @MainActor in
                    change.newValue ? self?.start() : self?.stop()
                }
            }
            .store(in: &settingsCancellables)

        if Defaults[.downloadWatcherEnabled] {
            start()
        }
    }

    func start() {
        guard timer == nil else {
            refreshNow()
            return
        }
        refreshNow()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshNow() }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        clearTask?.cancel()
        clearTask = nil
        snapshot = .empty
    }

    func refreshNow() {
        guard Defaults[.downloadWatcherEnabled] else { return }
        guard let payload = readableDownloadsContents() else {
            lastError = "Cannot read Downloads folder"
            return
        }
        lastError = nil
        let files = payload.files

        let partials = files
            .filter { partialExtensions.contains($0.pathExtension.lowercased()) }
            .compactMap { DownloadCandidate(url: $0) }
            .sorted { $0.modifiedAt > $1.modifiedAt }

        if let active = partials.first {
            clearTask?.cancel()
            clearTask = nil
            let state: DownloadWatcherSnapshot.State = isLikelyFailedPartial(active) ? .failed : .inProgress
            snapshot = active.snapshot(state: state)
            rememberLikelyCompletedFiles(near: files)
            return
        }

        if Defaults[.downloadWatcherShowCompletedToast], let completed = recentlyCompletedFile(from: files) {
            snapshot = completed.snapshot(state: .completed)
            seenCompletedFiles.insert(completed.url.path)
            scheduleClearCompletedToast()
        } else if snapshot.state == .inProgress {
            snapshot = .empty
        }
    }

    func revealCurrentDownload() {
        guard let url = snapshot.fileURL else { return }
        let target = resolvedDownloadURL(from: url)
        if FileManager.default.fileExists(atPath: target.path) {
            NSWorkspace.shared.activateFileViewerSelecting([target])
        } else if FileManager.default.fileExists(atPath: target.deletingLastPathComponent().path) {
            NSWorkspace.shared.open(target.deletingLastPathComponent())
        }
    }

    private func scheduleClearCompletedToast() {
        clearTask?.cancel()
        clearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Defaults[.downloadWatcherCompletedToastDuration]))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                if self?.snapshot.state == .completed {
                    self?.snapshot = .empty
                }
            }
        }
    }

    private func rememberLikelyCompletedFiles(near files: [URL]) {
        let now = Date()
        for url in files {
            guard !partialExtensions.contains(url.pathExtension.lowercased()) else { continue }
            guard let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { continue }
            if now.timeIntervalSince(modified) < 2 {
                seenCompletedFiles.insert(url.path)
            }
        }
    }

    private func isLikelyFailedPartial(_ candidate: DownloadCandidate) -> Bool {
        let key = candidate.url.path
        let now = Date()
        let previous = partialObservations[key]
        let unchangedSince: Date

        if let previous, previous.bytes == candidate.bytes {
            unchangedSince = previous.unchangedSince
        } else {
            unchangedSince = now
        }

        partialObservations[key] = PartialObservation(bytes: candidate.bytes, unchangedSince: unchangedSince, seenAt: now)
        partialObservations = partialObservations.filter { now.timeIntervalSince($0.value.seenAt) < 120 }

        let filesystemIdleAge = now.timeIntervalSince(candidate.modifiedAt)
        let unchangedAge = now.timeIntervalSince(unchangedSince)
        return filesystemIdleAge >= failedPartialAge * 2 || (filesystemIdleAge >= failedPartialAge && unchangedAge >= failedPartialAge)
    }

    private func recentlyCompletedFile(from files: [URL]) -> DownloadCandidate? {
        let now = Date()
        return files
            .filter { !partialExtensions.contains($0.pathExtension.lowercased()) }
            .compactMap { DownloadCandidate(url: $0) }
            .filter { candidate in
                !seenCompletedFiles.contains(candidate.url.path)
                    && now.timeIntervalSince(candidate.modifiedAt) <= max(2, Defaults[.downloadWatcherCompletedToastDuration] + 2)
                    && !candidate.url.lastPathComponent.hasPrefix(".")
            }
            .sorted { $0.modifiedAt > $1.modifiedAt }
            .first
    }

    private func readableDownloadsContents() -> (url: URL, files: [URL])? {
        for url in downloadsCandidateURLs() {
            if let files = try? FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) {
                return (url, files)
            }
        }
        return nil
    }

    private func downloadsCandidateURLs() -> [URL] {
        var candidates: [URL] = []

        if let sandboxAware = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first {
            candidates.append(sandboxAware)
        }

        if let passwd = getpwuid(getuid()), let homePointer = passwd.pointee.pw_dir {
            let realHome = String(cString: homePointer)
            candidates.append(URL(fileURLWithPath: realHome).appendingPathComponent("Downloads", isDirectory: true))
        }

        candidates.append(URL(fileURLWithPath: "/Users/\(NSUserName())/Downloads", isDirectory: true))

        var seen = Set<String>()
        return candidates.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    private func resolvedDownloadURL(from url: URL) -> URL {
        let ext = url.pathExtension.lowercased()
        guard partialExtensions.contains(ext) else { return url }
        let stripped = url.deletingPathExtension()
        return stripped.lastPathComponent.isEmpty ? url : stripped
    }
}

private struct PartialObservation {
    let bytes: Int64
    let unchangedSince: Date
    let seenAt: Date
}

private struct DownloadCandidate {
    let url: URL
    let modifiedAt: Date
    let bytes: Int64

    init?(url: URL) {
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]) else { return nil }
        guard values.isRegularFile != false else { return nil }
        self.url = url
        self.modifiedAt = values.contentModificationDate ?? .distantPast
        self.bytes = Int64(values.fileSize ?? 0)
    }

    func snapshot(state: DownloadWatcherSnapshot.State) -> DownloadWatcherSnapshot {
        let browser = Self.browser(for: url)
        return DownloadWatcherSnapshot(
            fileName: displayName(for: url),
            fileURL: url,
            browserName: browser.name,
            browserBundleID: browser.bundleID,
            bytes: bytes,
            state: state,
            updatedAt: Date()
        )
    }

    private func displayName(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        let partials = ["download", "crdownload", "part", "opdownload", "tmp"]
        if partials.contains(ext) {
            let stripped = url.deletingPathExtension().lastPathComponent
            return stripped.isEmpty ? url.lastPathComponent : stripped
        }
        return url.lastPathComponent
    }

    private static func browser(for url: URL) -> (name: String, bundleID: String?) {
        switch url.pathExtension.lowercased() {
        case "download": return ("Safari", "com.apple.Safari")
        case "crdownload": return ("Chrome", "com.google.Chrome")
        case "opdownload": return ("Opera", "com.operasoftware.Opera")
        case "part": return ("Firefox", "org.mozilla.firefox")
        default: return ("Downloads", nil)
        }
    }
}
