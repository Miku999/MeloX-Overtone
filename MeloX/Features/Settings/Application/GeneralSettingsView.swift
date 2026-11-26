import SwiftUI

struct GeneralSettingsView: View {
    @Environment(AppSettings.self) private var settings

    @State private var classicIcon = UIApplication.shared.alternateIconName == "AppIconClassic"
    @State private var changingIcon = false
    @State private var iconError: String?

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section {
                Picker(
                    "ui.settings.language.picker",
                    selection: Binding(
                        get: { settings.appLanguage },
                        set: settings.setAppLanguage
                    )
                ) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.title)
                            .tag(language)
                    }
                }
            } header: {
                Text("ui.settings.language.section")
            } footer: {
                Text("ui.settings.language.footer")
            }

            Section {
                Picker(
                    "ui.settings.general.theme.picker",
                    selection: $settings.appearance
                ) {
                    ForEach(AppAppearance.allCases) { appearance in
                        Label(
                            appearance.title,
                            systemImage: appearance.systemImage
                        )
                        .tag(appearance)
                    }
                }

                Picker("ui.settings.appearance.accent", selection: $settings.accent) {
                    Text("ui.settings.appearance.classic").tag(AppAccent.classic)
                    Text(verbatim: "iOS27.3+").tag(AppAccent.blue)
                }

                Picker("ui.settings.appearance.app_icon", selection: Binding(
                    get: { classicIcon }, set: changeIcon
                )) {
                    Text("ui.settings.appearance.classic").tag(true)
                    Text(verbatim: "iOS 27.3+").tag(false)
                }
                .disabled(changingIcon || !UIApplication.shared.supportsAlternateIcons)
            } header: {
                Text("ui.settings.general.appearance.section")
            } footer: {
                Text("ui.settings.general.appearance.footer")
            }

            Section {
                Toggle(
                    "ui.settings.general.clipboard_recognition",
                    isOn: $settings.recognizesClipboardLinksOnLaunch
                )
            } header: {
                Text("ui.settings.general.clipboard.section")
            } footer: {
                Text(
                    "ui.settings.general.clipboard.footer"
                )
            }

            Section("ui.navigation.search") {
                Toggle("ui.settings.general.search_suggestions", isOn: $settings.searchSuggestionsEnabled)
            }

            Section {
                Toggle(
                    "ui.settings.general.cache_page_content",
                    isOn: $settings.automaticallyCachesPageContent
                )
            } footer: {
                Text("ui.settings.general.cache_page_content.footer")
            }
        }
        .navigationTitle("ui.settings.catalog.general.title")
        .navigationBarTitleDisplayMode(.inline)
        .alert("ui.settings.appearance.icon_error", isPresented: Binding(
            get: { iconError != nil }, set: { if !$0 { iconError = nil } }
        )) {
            Button("ui.common.ok", role: .cancel) {}
        } message: { Text(iconError ?? "") }
    }

    private func changeIcon(_ classic: Bool) {
        guard !changingIcon, classic != classicIcon else { return }
        changingIcon = true
        Task {
            defer {
                classicIcon = UIApplication.shared.alternateIconName == "AppIconClassic"
                changingIcon = false
            }
            do {
                try await UIApplication.shared.setAlternateIconName(classic ? "AppIconClassic" : nil)
            } catch {
                iconError = error.localizedDescription
            }
        }
    }
}
