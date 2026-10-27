import Foundation

/// The one preferences accessor (MULTI_ASSISTANT_PLAN v5 §3.6).
///
/// `UserDefaults.standard` is a single domain per OS user (the executable
/// name), so every assistant would share the OpenRouter spend ledger,
/// `/archiveinline`, `/prunebackground`, `/keepsummaries`, the tool switches,
/// the web-search backend, privacy mode, the last user channel, … The
/// default profile keeps `UserDefaults.standard` (byte-identical behaviour);
/// an extra gets its own suite `briglia.profile.<name>.<h>`, where `<h>` is
/// derived from the extra's absolute data root so two XDG installations of
/// one OS user never share a suite.
///
/// A lint (scripts/prefs_lint.py) fails when `UserDefaults.standard` appears
/// in production code outside this file.
enum Prefs {
    /// Test-only suite prefix. Honoured only when the executable's own
    /// domain is a throwaway test domain (`briglia-mw-*`) and the prefix
    /// itself is one, so `TestPrefsDomains` can purge it.
    static let testSuitePrefixKey = "BRIGLIA_TEST_PREFS_SUITE_PREFIX"

    /// The preferences store of the selected profile.
    static let store: UserDefaults = makeStore()

    /// Named-domain API (`persistentDomain(forName:)`, `removePersistentDomain`)
    /// used by the identity migration and the selftest purge. These calls name
    /// their domain explicitly and are not profile state.
    static var domains: UserDefaults { UserDefaults.standard }

    /// The suite name for an extra, or nil for default.
    static func suiteName(profile: String = AssistantProfile.selectedName,
                          environment: [String: String] = ProcessInfo.processInfo.environment,
                          processName: String = ProcessInfo.processInfo.processName) -> String? {
        guard profile != AssistantProfile.defaultName else { return nil }
        let base = "briglia.profile.\(profile).\(AssistantProfile.installationHash(profile, environment: environment))"
        if let prefix = environment[testSuitePrefixKey], !prefix.isEmpty,
           prefix.hasPrefix("briglia-mw-"), processName.hasPrefix("briglia-mw-") {
            return prefix + base
        }
        return base
    }

    private static func makeStore() -> UserDefaults {
        guard let name = suiteName() else { return UserDefaults.standard }
        // Never fall back to the shared domain for an extra: that would
        // silently mix two assistants' settings.
        guard let suite = UserDefaults(suiteName: name) else {
            fatalError("cannot open the preferences suite \(name) for this assistant")
        }
        return suite
    }
}
