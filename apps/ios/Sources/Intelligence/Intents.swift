// Shortcuts/Siri entry point. The heavy lifting for "where are my
// keys" from outside the app is done by Spotlight indexing (see
// SpotlightIndex) — every saved thing is searchable from the iPhone's
// own search, and tapping a result deep-links into locate mode. This
// intent adds the verb form: "Search Theseus" from Siri or a Shortcut.
import AppIntents

struct SearchStuffIntent: AppIntent {
    static var title: LocalizedStringResource = "Search my stuff"
    static var description = IntentDescription(
        "Opens Theseus to search everything you own.")
    static var openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        .result()
    }
}

struct TheseusShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SearchStuffIntent(),
            phrases: [
                "Search \(.applicationName)",
                "Find my stuff in \(.applicationName)",
            ],
            shortTitle: "Search my stuff",
            systemImageName: "location.magnifyingglass")
    }
}
