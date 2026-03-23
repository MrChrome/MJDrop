//
//  PresetManager.swift
//  MJDrop
//
//  Manages preset loading, cycling, and shuffling.
//  Loads .milk files from a directory and provides navigation.
//

import Foundation
import Observation

private let kPresetDirectoryBookmark = "presetDirectoryBookmark"

@MainActor
@Observable
final class PresetManager {
    private(set) var presets: [PresetParameters] = HardcodedPresets.all
    private(set) var currentIndex: Int = 0
    private(set) var presetDirectory: URL?
    private(set) var isLoadingDirectory: Bool = false

    private var cycleTimer: Timer?

    var currentPreset: PresetParameters {
        guard !presets.isEmpty else { return PresetParameters() }
        return presets[currentIndex % presets.count]
    }

    var currentName: String {
        currentPreset.name
    }

    var presetCount: Int {
        presets.count
    }

    // MARK: - Auto-Cycle

    func startAutoCycle(interval: TimeInterval = 10) {
        stopAutoCycle()
        cycleTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.randomPreset()
            }
        }
    }

    func stopAutoCycle() {
        cycleTimer?.invalidate()
        cycleTimer = nil
    }

    // MARK: - Navigation

    func nextPreset() {
        guard !presets.isEmpty else { return }
        currentIndex = (currentIndex + 1) % presets.count
    }

    func previousPreset() {
        guard !presets.isEmpty else { return }
        currentIndex = (currentIndex - 1 + presets.count) % presets.count
    }

    func randomPreset() {
        guard presets.count > 1 else { return }
        var newIndex = currentIndex
        while newIndex == currentIndex {
            newIndex = Int.random(in: 0..<presets.count)
        }
        currentIndex = newIndex
    }

    func selectPreset(at index: Int) {
        guard index >= 0, index < presets.count else { return }
        currentIndex = index
    }

    // MARK: - Directory Loading

    /// Load all .milk presets from a directory.
    func loadDirectory(url: URL) {
        presetDirectory = url
        isLoadingDirectory = true

        // Save a security-scoped bookmark for next launch
        saveDirectoryBookmark(url: url)

        // Start security-scoped access so the background thread can read files
        let accessing = url.startAccessingSecurityScopedResource()

        // Do file I/O on a background thread
        let dirURL = url
        Task { [weak self] in
            let parsed = await Task.detached {
                parsePresetsInDirectory(dirURL)
            }.value

            // Release security scope now that parsing is done
            if accessing {
                dirURL.stopAccessingSecurityScopedResource()
            }

            guard let self else { return }
            if parsed.isEmpty {
                self.presets = HardcodedPresets.all
            } else {
                self.presets = parsed
            }
            self.currentIndex = 0
            self.isLoadingDirectory = false
        }
    }

    // MARK: - Persistence

    /// Restore last preset directory from saved bookmark.
    func restoreSavedDirectory() {
        guard let bookmarkData = UserDefaults.standard.data(forKey: kPresetDirectoryBookmark) else { return }
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmarkData,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return }

        if isStale {
            // Re-save the bookmark if it's stale but still resolvable
            saveDirectoryBookmark(url: url)
        }

        loadDirectory(url: url)
    }

    private func saveDirectoryBookmark(url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let bookmarkData = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else { return }
        UserDefaults.standard.set(bookmarkData, forKey: kPresetDirectoryBookmark)
    }
}

/// Parse all .milk files in a directory (runs off main actor).
nonisolated private func parsePresetsInDirectory(_ url: URL) -> [PresetParameters] {
    let fm = FileManager.default
    guard let enumerator = fm.enumerator(
        at: url,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
    ) else { return [] }

    var results: [PresetParameters] = []

    for case let fileURL as URL in enumerator {
        guard fileURL.pathExtension.lowercased() == "milk" else { continue }
        if let preset = MilkFileParser.parse(url: fileURL) {
            results.append(preset)
        }
    }

    results.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

    return results
}
