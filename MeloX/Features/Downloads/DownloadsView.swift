import SwiftUI

struct DownloadsView: View {
    @Environment(DownloadStore.self) private var downloads
    @Environment(PlayerStore.self) private var player
    @Environment(AppSettings.self) private var settings

    @State private var showsClearConfirmation = false

    var body: some View {
        @Bindable var settings = settings

        List {
            Section {
                Toggle(
                    "ui.downloads.automatic_cache",
                    isOn: $settings.automaticallyCachesFrequentlyPlayedSongs
                )

                if settings.automaticallyCachesFrequentlyPlayedSongs {
                    Picker(
                        "ui.downloads.trigger_count",
                        selection: $settings.automaticCachePlaybackThreshold
                    ) {
                        ForEach(AppSettings.automaticCachePlaybackThresholdOptions, id: \.self) { count in
                            Text(L10n.format("ui.common.times", count)).tag(count)
                        }
                    }

                    Picker("ui.downloads.automatic_cache_quality", selection: $settings.automaticCacheQuality) {
                        ForEach(MusicQuality.allCases) { quality in
                            Text(quality.title).tag(quality)
                        }
                    }
                }
            } header: {
                Text("ui.downloads.section.automatic_cache")
            } footer: {
                Text("ui.downloads.automatic_cache.footer")
            }

            if !activeDownloads.isEmpty {
                Section("ui.downloads.active") {
                    ForEach(activeDownloads) { download in
                        VStack(alignment: .leading, spacing: 8) {
                            TrackRowView(song: download.song, showsArtwork: true)

                            if let fractionCompleted = download.fractionCompleted {
                                ProgressView(value: fractionCompleted)
                                    .progressViewStyle(.linear)
                                    .accessibilityValue(
                                        fractionCompleted.formatted(
                                            .percent
                                                .precision(.fractionLength(0))
                                                .locale(L10n.locale)
                                        )
                                    )
                            }

                            HStack {
                                Text(download.quality.title)
                                Spacer()
                                Text(progressText(for: download))
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        .songSwipeActions(download.song, removal: .download)
                    }
                }
            }

            if !downloads.downloads.isEmpty {
                Section {
                    SongListPlaybackActions { shuffled in
                        let songs = downloads.downloadedSongs
                        Task { await player.playAll(shuffled ? songs.shuffled() : songs) }
                    }

                    ForEach(downloads.downloads) { download in
                        TrackRowView(song: download.song, showsArtwork: true,
                                     secondaryMetadata: "\(download.quality.title) · \(L10n.byteCount(download.byteCount))") {
                            Task { await player.play(download.song, in: downloads.downloadedSongs) }
                        }
                        .listRowInsets(.init(top: 4, leading: 20, bottom: 4, trailing: 16))
                        .songSwipeActions(download.song, removal: .download)
                    }
                } header: {
                    Text("ui.downloads.downloaded")
                } footer: {
                    Text(storageSummary)
                }
            }

            if downloads.downloads.isEmpty && activeDownloads.isEmpty {
                Section {
                    ContentUnavailableView(
                        "ui.downloads.empty",
                        systemImage: "arrow.down.circle",
                        description: Text("ui.downloads.empty.message")
                    )
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                }
            }
        }
        .listStyle(.plain)
        .listSectionSpacing(.compact)
        .navigationTitle("ui.downloads.title")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("ui.downloads.delete_all", systemImage: "trash", role: .destructive) {
                        showsClearConfirmation = true
                    }
                } label: { Label("ui.common.more", systemImage: "ellipsis") }
                .tint(.primary)
                .disabled(downloads.downloads.isEmpty && activeDownloads.isEmpty)
            }
        }
        .confirmationDialog(
            "ui.downloads.delete_all.confirmation",
            isPresented: $showsClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("ui.downloads.delete_all", role: .destructive) {
                downloads.removeAll()
            }
        } message: {
            Text("ui.downloads.delete_all.message")
        }
    }

    private var activeDownloads: [ActiveSongDownload] {
        downloads.activeDownloads.values.sorted {
            $0.song.name.localizedCompare($1.song.name) == .orderedAscending
        }
    }

    private func progressText(for download: ActiveSongDownload) -> String {
        let received = download.receivedByteCount.formatted(
            .byteCount(style: .file).locale(L10n.locale)
        )
        guard let expected = download.expectedByteCount else {
            return received
        }
        let total = expected.formatted(
            .byteCount(style: .file).locale(L10n.locale)
        )
        let percentage = download.fractionCompleted?.formatted(
            .percent
                .precision(.fractionLength(0))
                .locale(L10n.locale)
        ) ?? ""
        return "\(received) / \(total)  \(percentage)"
    }

    private var storageSummary: String {
        L10n.format(
            "ui.downloads.summary",
            downloads.downloads.count,
            L10n.byteCount(downloads.totalByteCount)
        )
    }
}
