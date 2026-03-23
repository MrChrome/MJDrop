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

    var body: some View {
        VStack(spacing: 0) {
            // Milkdrop visualizer
            MetalVisualizerView(audioManager: audioManager, presetManager: presetManager)
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
                    Button(action: { presetManager.previousPreset() }) {
                        Image(systemName: "chevron.left")
                    }
                    .buttonStyle(.borderless)
                    .help("Previous preset")

                    Button(action: { presetManager.randomPreset() }) {
                        Image(systemName: "shuffle")
                    }
                    .buttonStyle(.borderless)
                    .help("Random preset")

                    Button(action: { presetManager.nextPreset() }) {
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

                    Button(action: { audioManager.togglePlayback() }) {
                        Image(systemName: audioManager.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.title3)
                    }
                    .buttonStyle(.borderless)
                    .disabled(audioManager.fileName == nil)
                    .help(audioManager.isPlaying ? "Pause" : "Play")

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
    }

    private func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
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

#Preview {
    ContentView()
}
