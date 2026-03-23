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

                    // Preset info
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
                            .contextMenu {
                                Button("Copy Preset Name") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(presetManager.currentName, forType: .string)
                                }
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

#Preview {
    ContentView()
}
