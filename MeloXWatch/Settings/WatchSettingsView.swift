import SwiftUI

struct WatchSettingsView: View {
    @AppStorage(AppLanguage.storageKey)
    private var appLanguage: AppLanguage = .system

    var body: some View {
        List {
            Section("ui.settings.language.section") {
                Picker(
                    "ui.settings.language.picker",
                    selection: Binding(
                        get: { appLanguage },
                        set: { language in
                            L10n.activate(language)
                            appLanguage = language
                        }
                    )
                ) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.title)
                            .tag(language)
                    }
                }
            }

            Section("ui.watch.settings.player") {
                NavigationLink {
                    WatchAudioSettingsView()
                } label: {
                    Label("ui.watch.settings.audio", systemImage: "speaker.wave.2")
                }

                NavigationLink {
                    WatchPlaybackBehaviorSettingsView()
                } label: {
                    Label("ui.watch.settings.playback_behavior", systemImage: "repeat")
                }

                NavigationLink {
                    WatchPlayerAppearanceSettingsView()
                } label: {
                    Label("ui.watch.settings.player_appearance", systemImage: "rectangle.inset.filled")
                }
            }

            Section("ui.common.lyrics") {
                NavigationLink {
                    WatchLyricsSettingsView()
                } label: {
                    Label("ui.watch.settings.lyrics", systemImage: "quote.bubble")
                }
            }

            NavigationLink {
                List {
                    ProjectAttribution()
                }
                .navigationTitle("ui.app.name")
            } label: {
                Label("ui.settings.catalog.about.title", systemImage: "info.circle")
            }
        }
        .navigationTitle("ui.watch.settings.title")
    }
}
