import SwiftUI

struct NowPlayingLyricsLanguageButton: View {
    @Environment(AppSettings.self) private var settings

    let hasTranslations: Bool
    let hasRomanizations: Bool
    var usesMenuLabel = false

    var body: some View {
        if usesMenuLabel {
            annotationMenu
        } else {
            Button {
                if hasTranslations {
                    settings.lyricsTranslationEnabled.toggle()
                } else {
                    settings.lyricsRomanizationEnabled.toggle()
                }
            } label: {
                Image(systemName: "translate")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(.white.opacity(isQuickToggleOn ? 0.24 : 0.1), in: .circle)
                    .frame(width: 44, height: 44)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(hasTranslations ? Text("ui.lyrics.show_translation") : Text("ui.settings.lyrics.content.show_romanization"))
            .accessibilityValue(isQuickToggleOn ? Text("ui.common.on") : Text("ui.common.off"))
        }
    }

    private var isQuickToggleOn: Bool {
        hasTranslations ? settings.lyricsTranslationEnabled : settings.lyricsRomanizationEnabled
    }

    private var annotationMenu: some View {
        @Bindable var settings = settings

        return Menu {
            if hasRomanizations {
                Toggle(
                    "ui.settings.lyrics.content.show_romanization",
                    isOn: $settings.lyricsRomanizationEnabled
                )

                if supportsEditableAnnotationRange,
                   settings.lyricsRomanizationEnabled {
                    Picker(
                        "ui.settings.lyrics.content.romanization_display_range",
                        selection:
                            $settings.lyricsRomanizationDisplayMode
                    ) {
                        ForEach(
                            LyricsTranslationDisplayMode.allCases
                        ) { mode in
                            Text(mode.title)
                                .tag(mode)
                        }
                    }
                }
            }

            if hasTranslations {
                Toggle(
                    "ui.lyrics.show_translation",
                    isOn: $settings.lyricsTranslationEnabled
                )

                if supportsEditableAnnotationRange,
                   settings.lyricsTranslationEnabled {
                    Picker(
                        "ui.settings.lyrics.content.translation_display_range",
                        selection:
                            $settings.lyricsTranslationDisplayMode
                    ) {
                        ForEach(
                            LyricsTranslationDisplayMode.allCases
                        ) { mode in
                            Text(mode.title)
                                .tag(mode)
                        }
                    }
                }
            }

        } label: {
            Label("ui.settings.lyrics.content.section.translation_pronunciation", systemImage: "translate")
        }
        .buttonStyle(.plain)
        .accessibilityLabel("ui.settings.lyrics.content.section.translation_pronunciation")
        .accessibilityValue(accessibilityValue)
        .accessibilityHint(accessibilityHint)
    }

    private var usesAppleMusic26Presentation: Bool {
        settings.lyricsStyle == .appleMusic
            && settings.appleMusicLyrics.usesAppleMusic26Motion
    }

    private var supportsEditableAnnotationRange: Bool {
        settings.lyricsStyle == .appleMusic
            && !usesAppleMusic26Presentation
    }

    private var accessibilityValue: String {
        var enabledAnnotations: [String] = []
        if hasRomanizations && settings.lyricsRomanizationEnabled {
            enabledAnnotations.append(L10n.string("ui.lyrics.romanization"))
        }
        if hasTranslations && settings.lyricsTranslationEnabled {
            enabledAnnotations.append(L10n.string("ui.lyrics.translation"))
        }
        guard !enabledAnnotations.isEmpty else {
            return L10n.string("ui.lyrics.annotations_hidden")
        }

        if usesAppleMusic26Presentation {
            return enabledAnnotations.joined(separator: L10n.string("ui.common.list_separator"))
        }
        guard supportsEditableAnnotationRange else {
            return enabledAnnotations.joined(separator: L10n.string("ui.common.list_separator"))
        }
        let scopes: [String] = [
            hasRomanizations && settings.lyricsRomanizationEnabled
                ? L10n.format(
                    "ui.lyrics.romanization_scope",
                    settings.lyricsRomanizationDisplayMode.title
                )
                : nil,
            hasTranslations && settings.lyricsTranslationEnabled
                ? L10n.format(
                    "ui.lyrics.translation_scope",
                    settings.lyricsTranslationDisplayMode.title
                )
                : nil,
        ].compactMap { $0 }
        return scopes.joined(separator: L10n.string("ui.common.list_separator"))
    }

    private var accessibilityHint: String {
        if usesAppleMusic26Presentation {
            return L10n.string("ui.lyrics.annotation_hint")
        }
        if supportsEditableAnnotationRange {
            return L10n.string("ui.lyrics.annotation_range_hint")
        }
        return L10n.string("ui.lyrics.annotation_hint")
    }
}
