//
//  ContentView.swift
//  MJDrop
//
//  Created by MARC SANTA on 3/22/26.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var audioManager = AudioPlayerManager()
    @State private var presetManager = PresetManager()
    @State private var showingFilePicker = false
    @State private var showingPresetFolderPicker = false
    @State private var showingPresetList = false
    @State private var presetSearchText = ""
    @State private var shaderErrorMessage: String?
    @State private var showingShaderError = false
    @State private var shaderTestManager = ShaderTestManager()
    @State private var showingShaderTest = false
    @AppStorage("showShaderErrors") private var showShaderErrors = false
    @State private var isRendererPaused = false

    var body: some View {
        VStack(spacing: 0) {
            // Milkdrop visualizer
            MetalVisualizerView(audioManager: audioManager, presetManager: presetManager, isRendererPaused: $isRendererPaused) { errorMessage in
                guard showShaderErrors else { return }
                shaderErrorMessage = errorMessage
                showingShaderError = true
                presetManager.stopAutoCycle()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Transport bar
            VStack(spacing: 12) {
                // Progress bar
                if audioManager.duration > 0 {
                    ProgressView(value: audioManager.currentTime, total: audioManager.duration)
                        .tint(.cyan)
                }

                HStack(spacing: 12) {
                    // File name
                    Text(audioManager.fileName ?? "No file loaded")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    // Preset info — click to open preset list
                    HStack(spacing: 4) {
                        Text("\(presetManager.currentIndex + 1)/\(presetManager.presetCount)")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Text(presetManager.currentName)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.cyan)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: 200, alignment: .trailing)
                    }
                    .onTapGesture {
                        presetSearchText = ""
                        showingPresetList.toggle()
                    }
                    .help("Click to browse presets")
                    .popover(isPresented: $showingPresetList, arrowEdge: .bottom) {
                        PresetListView(
                            presetManager: presetManager,
                            searchText: $presetSearchText,
                            isPresented: $showingPresetList
                        )
                    }
                    .contextMenu {
                        Button("Copy Preset Name") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(presetManager.currentName, forType: .string)
                        }
                    }

                    // Time display
                    if audioManager.duration > 0 {
                        Text("\(formatTime(audioManager.currentTime)) / \(formatTime(audioManager.duration))")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }

                    // Preset controls
                    Button(action: { presetManager.previousPreset(); isRendererPaused = false }) {
                        Image(systemName: "chevron.left")
                    }
                    .buttonStyle(.borderless)
                    .help("Previous preset")

                    Toggle(isOn: $presetManager.shuffleEnabled) {
                        Image(systemName: "shuffle")
                            .foregroundStyle(presetManager.shuffleEnabled ? .cyan : .secondary)
                    }
                    .toggleStyle(.button)
                    .buttonStyle(.borderless)
                    .help(presetManager.shuffleEnabled ? "Shuffle on — random preset every 10s" : "Shuffle off — sequential order")

                    Button(action: { presetManager.nextPreset(); isRendererPaused = false }) {
                        Image(systemName: "chevron.right")
                    }
                    .buttonStyle(.borderless)
                    .help("Next preset")

                    Divider().frame(height: 16)

                    // Load preset folder
                    Button(action: { showingPresetFolderPicker = true }) {
                        Image(systemName: "folder.badge.gearshape")
                    }
                    .buttonStyle(.borderless)
                    .help("Load preset folder (.milk files)")
                    .fileImporter(
                        isPresented: $showingPresetFolderPicker,
                        allowedContentTypes: [UTType.folder],
                        allowsMultipleSelection: false
                    ) { result in
                        if case .success(let urls) = result, let url = urls.first {
                            presetManager.loadDirectory(url: url)
                        }
                    }

                    // Test all shaders
                    Button(action: {
                        showingShaderTest = true
                        presetManager.stopAutoCycle()
                        shaderTestManager.runTests(presets: presetManager.presets)
                    }) {
                        Image(systemName: "testtube.2")
                    }
                    .buttonStyle(.borderless)
                    .disabled(presetManager.isLoadingDirectory || shaderTestManager.isRunning)
                    .help("Test all shader compilation (\(presetManager.presetCount) presets)")

                    Divider().frame(height: 16)

                    // Show shader errors toggle
                    Toggle(isOn: $showShaderErrors) {
                        Text("Shader Errors")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .toggleStyle(.checkbox)
                    .help("Show shader compilation errors")

                    Divider().frame(height: 16)

                    // Audio controls
                    Button(action: { showingFilePicker = true }) {
                        Image(systemName: "folder.fill")
                    }
                    .buttonStyle(.borderless)
                    .help("Open MP3 file")
                    .fileImporter(
                        isPresented: $showingFilePicker,
                        allowedContentTypes: [UTType.mp3, UTType.audio],
                        allowsMultipleSelection: false
                    ) { result in
                        if case .success(let urls) = result, let url = urls.first {
                            audioManager.loadFile(url: url)
                        }
                    }

                    // Pause renderer + music
                    Button(action: {
                        isRendererPaused.toggle()
                        if isRendererPaused {
                            if audioManager.isPlaying { audioManager.pause() }
                        } else {
                            if audioManager.fileName != nil { audioManager.togglePlayback() }
                        }
                    }) {
                        Image(systemName: isRendererPaused ? "play.fill" : "pause.fill")
                            .font(.title3)
                    }
                    .buttonStyle(.borderless)
                    .help(isRendererPaused ? "Resume" : "Pause")

                    Button(action: { audioManager.togglePlayback() }) {
                        Image(systemName: audioManager.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.title3)
                    }
                    .buttonStyle(.borderless)
                    .disabled(audioManager.fileName == nil)
                    .help(audioManager.isPlaying ? "Pause music" : "Play music")

                    Button(action: { audioManager.stop() }) {
                        Image(systemName: "stop.circle.fill")
                            .font(.title3)
                    }
                    .buttonStyle(.borderless)
                    .disabled(audioManager.fileName == nil)
                    .help("Stop")
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial)
        }
        .background(Color.black)
        .onAppear {
            presetManager.restoreSavedDirectory()
            presetManager.startAutoCycle()
            audioManager.restoreSavedFile()
        }
        .sheet(isPresented: $showingShaderError) {
            ShaderErrorView(errorMessage: shaderErrorMessage ?? "Unknown error") {
                showingShaderError = false
                presetManager.startAutoCycle()
            }
        }
        .sheet(isPresented: $showingShaderTest) {
            ShaderTestReportView(testManager: shaderTestManager) {
                showingShaderTest = false
                presetManager.startAutoCycle()
            }
        }
    }

    private func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

// MARK: - Shader Error View

struct ShaderErrorView: View {
    let errorMessage: String
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                    .font(.title2)
                Text("Shader Compilation Error")
                    .font(.headline)
                Spacer()
                Button("Dismiss") {
                    onDismiss()
                }
                .keyboardShortcut(.cancelAction)
            }

            Divider()

            ScrollView {
                Text(errorMessage)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Spacer()
                Button("Copy to Clipboard") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(errorMessage, forType: .string)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .frame(width: 600, height: 400)
    }
}

// MARK: - Preset List View

struct PresetListView: View {
    let presetManager: PresetManager
    @Binding var searchText: String
    @Binding var isPresented: Bool

    private var filteredPresets: [(index: Int, preset: PresetParameters)] {
        let all = presetManager.presets.enumerated().map { (index: $0.offset, preset: $0.element) }
        if searchText.isEmpty { return all }
        let query = searchText.lowercased()
        return all.filter { $0.preset.name.lowercased().contains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Search field
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search presets…", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(8)

            Divider()

            // Preset list
            ScrollViewReader { proxy in
                List(filteredPresets, id: \.index) { item in
                    Button(action: {
                        presetManager.selectPreset(at: item.index)
                        isPresented = false
                    }) {
                        HStack {
                            Text(item.preset.name)
                                .font(.system(.caption, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer()
                            if item.index == presetManager.currentIndex {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.cyan)
                                    .font(.caption2)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .id(item.index)
                }
                .listStyle(.plain)
                .onAppear {
                    proxy.scrollTo(presetManager.currentIndex, anchor: .center)
                }
            }
        }
        .frame(width: 400, height: 350)
    }
}

// MARK: - Shader Test Report View

struct ShaderTestReportView: View {
    let testManager: ShaderTestManager
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "testtube.2")
                    .foregroundStyle(.cyan)
                    .font(.title2)
                Text("Shader Compilation Test")
                    .font(.headline)
                Spacer()
                if !testManager.isRunning {
                    Button("Dismiss") {
                        onDismiss()
                    }
                    .keyboardShortcut(.cancelAction)
                }
            }

            Divider()

            // Progress section
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: testManager.progress)
                    .tint(testManager.isRunning ? .cyan : (testManager.failedCount == 0 ? .green : .orange))

                HStack {
                    if testManager.isRunning {
                        Text("Testing: \(testManager.currentPresetName)")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer()
                    Text("\(testManager.completed) / \(testManager.total)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            // Summary
            if !testManager.isRunning && testManager.completed > 0 {
                HStack(spacing: 16) {
                    Label("\(testManager.passedCount) passed", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.system(.body, design: .monospaced))
                    Label("\(testManager.failedCount) failed", systemImage: "xmark.circle.fill")
                        .foregroundStyle(testManager.failedCount > 0 ? .red : .secondary)
                        .font(.system(.body, design: .monospaced))

                    let skippedCount = testManager.results.filter({ $0.warpResult == .skipped && $0.compResult == .skipped }).count
                    if skippedCount > 0 {
                        Label("\(skippedCount) skipped (v1)", systemImage: "minus.circle.fill")
                            .foregroundStyle(.secondary)
                            .font(.system(.body, design: .monospaced))
                    }
                }
                .padding(.vertical, 4)
            }

            // Failed presets list
            if !testManager.failedResults.isEmpty {
                Text("Failed Presets:")
                    .font(.system(.caption, design: .monospaced).bold())

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(testManager.failedResults) { result in
                            HStack(spacing: 6) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.red)
                                    .font(.caption2)
                                Text(result.presetName)
                                    .font(.system(.caption, design: .monospaced))
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Spacer()
                                if result.warpResult == .failed {
                                    Text("warp")
                                        .font(.system(.caption2, design: .monospaced))
                                        .foregroundStyle(.red)
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 1)
                                        .background(.red.opacity(0.15), in: RoundedRectangle(cornerRadius: 3))
                                }
                                if result.compResult == .failed {
                                    Text("comp")
                                        .font(.system(.caption2, design: .monospaced))
                                        .foregroundStyle(.red)
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 1)
                                        .background(.red.opacity(0.15), in: RoundedRectangle(cornerRadius: 3))
                                }
                            }
                        }
                    }
                }
            }

            // Copy report button
            if !testManager.isRunning && testManager.completed > 0 {
                HStack {
                    Spacer()
                    Button("Copy Report") {
                        let report = buildReport()
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(report, forType: .string)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding()
        .frame(width: 600, height: 450)
    }

    private func buildReport() -> String {
        var lines: [String] = []
        lines.append("Shader Compilation Test Report")
        lines.append("==============================")
        lines.append("Total: \(testManager.total)")
        lines.append("Passed: \(testManager.passedCount)")
        lines.append("Failed: \(testManager.failedCount)")
        let skipped = testManager.results.filter { $0.warpResult == .skipped && $0.compResult == .skipped }.count
        lines.append("Skipped (v1): \(skipped)")
        lines.append("")

        if !testManager.failedResults.isEmpty {
            lines.append("Failed Presets:")
            lines.append("---------------")
            for result in testManager.failedResults {
                var tags: [String] = []
                if result.warpResult == .failed { tags.append("warp") }
                if result.compResult == .failed { tags.append("comp") }
                lines.append("  \(result.presetName) [\(tags.joined(separator: ", "))]")
            }
        }

        return lines.joined(separator: "\n")
    }
}

#Preview {
    ContentView()
}
