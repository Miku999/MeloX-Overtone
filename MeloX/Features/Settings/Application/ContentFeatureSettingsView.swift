import SwiftUI

struct ContentFeatureSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(PlayerStore.self) private var player

    var body: some View {
        Form {
            Section {
                Toggle(isOn: alwaysMixBinding) {
                    Label {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("ui.settings.background_mix.always.title")
                            Text("ui.settings.background_mix.always.subtitle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "speaker.wave.2")
                    }
                }
            } header: {
                Text("ui.settings.background_mix.title")
            }
        }
        .navigationTitle("ui.settings.background_mix.title")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var alwaysMixBinding: Binding<Bool> {
        Binding(
            get: { settings.alwaysMixesWithOtherApps },
            set: { isEnabled in
                settings.alwaysMixesWithOtherApps = isEnabled
                player.applyBackgroundAudioMixPolicy()
            }
        )
    }
}
