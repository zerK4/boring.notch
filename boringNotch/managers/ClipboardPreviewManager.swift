//
//  ClipboardPreviewManager.swift
//  boringNotch
//
//  Lightweight clipboard classifier + pasteboard watcher for useful copy previews.
//

import AppKit
import Defaults
import Foundation
import SwiftUI

struct ClipboardPreview: Equatable, Identifiable {
    enum Kind: Equatable {
        case url
        case filePath
        case json
        case branch
    }

    let id = UUID()
    let kind: Kind
    let title: String
    let subtitle: String
    let icon: String
    let copiedText: String
    let createdAt: Date
}

enum ClipboardPreviewClassifier {
    static func classify(_ raw: String) -> ClipboardPreview? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 4_000 else { return nil }

        if let urlPreview = classifyURL(text) { return urlPreview }
        if let pathPreview = classifyFilePath(text) { return pathPreview }
        if let jsonPreview = classifyJSON(text) { return jsonPreview }
        if let branchPreview = classifyBranch(text) { return branchPreview }
        return nil
    }

    private static func classifyURL(_ text: String) -> ClipboardPreview? {
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else { return nil }
        let host = url.host(percentEncoded: false) ?? "URL"
        let title = host.contains("github.com") ? "GitHub URL copied" : "URL copied"
        return ClipboardPreview(kind: .url, title: title, subtitle: host, icon: "link", copiedText: text, createdAt: Date())
    }

    private static func classifyFilePath(_ text: String) -> ClipboardPreview? {
        guard text.hasPrefix("/") || text.hasPrefix("~/") else { return nil }
        let expanded = (text as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
        let last = url.lastPathComponent.isEmpty ? expanded : url.lastPathComponent
        return ClipboardPreview(kind: .filePath, title: "File path copied", subtitle: last, icon: "doc.on.clipboard", copiedText: text, createdAt: Date())
    }

    private static func classifyJSON(_ text: String) -> ClipboardPreview? {
        guard let first = text.first, ["{", "["].contains(first) else { return nil }
        guard let data = text.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data)) != nil else { return nil }
        return ClipboardPreview(kind: .json, title: "JSON copied", subtitle: "Valid JSON", icon: "curlybraces", copiedText: text, createdAt: Date())
    }

    private static func classifyBranch(_ text: String) -> ClipboardPreview? {
        guard text.count <= 96, text.contains("/"), !text.contains(" "), !text.contains("://") else { return nil }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._/-")
        guard text.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        let branchPrefixes = ["feature/", "fix/", "bugfix/", "hotfix/", "release/", "chore/", "dev/", "task/"]
        guard branchPrefixes.contains(where: { text.lowercased().hasPrefix($0) }) else { return nil }
        return ClipboardPreview(kind: .branch, title: "Branch copied", subtitle: text, icon: "point.3.connected.trianglepath.dotted", copiedText: text, createdAt: Date())
    }
}

@MainActor
final class ClipboardPreviewManager: ObservableObject {
    static let shared = ClipboardPreviewManager()

    @Published private(set) var currentPreview: ClipboardPreview?

    private let pasteboard = NSPasteboard.general
    private var lastChangeCount: Int
    private var lastText: String = ""
    private var timer: Timer?
    private var clearTask: Task<Void, Never>?

    private init() {
        lastChangeCount = pasteboard.changeCount
        if Defaults[.clipboardPreviewEnabled] {
            start()
        }
    }

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkPasteboard()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        clearTask?.cancel()
        clearTask = nil
        currentPreview = nil
    }

    private func checkPasteboard() {
        guard Defaults[.clipboardPreviewEnabled] else {
            stop()
            return
        }

        if timer == nil { start() }
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount

        guard let text = pasteboard.string(forType: .string), text != lastText else { return }
        lastText = text

        guard let preview = ClipboardPreviewClassifier.classify(text) else { return }
        withAnimation(.smooth(duration: 0.2)) {
            currentPreview = preview
        }

        clearTask?.cancel()
        clearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(.smooth(duration: 0.2)) {
                    self?.currentPreview = nil
                }
            }
        }
    }
}
