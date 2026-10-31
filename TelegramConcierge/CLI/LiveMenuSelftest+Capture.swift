import Foundation

// Preparation (plan B.4), the key roles (completeness guard) and the
// classification at the decision point.
extension LiveMenuHarness {
    func captureSection() async {
        reset(Self.routeBase)
        let before = store()
        let (change, reply) = await SettingsCapture.prepare(origin: "selftest", label: "Serper key") {
            await SetupAPICore.apply(["serper": ["api_key": "serper-synthetic-new-0002"], "web": ["keyless_search": false]], ownsLease: true)
        }
        check("capture: setup-api apply under capture writes nothing to disk", store() == before)
        check("capture: the reply is the request's own (ok)", reply["ok"] as? Bool == true, "\(reply)")
        guard let change else { check("capture: a change was prepared", false); return }
        check("capture: the delta holds exactly the keys the request wrote",
              change.writes[KeychainHelper.serperApiKeyKey] == "serper-synthetic-new-0002"
              && change.writes[KeychainHelper.keylessSearchKey] == "false" && change.deletes.isEmpty, "\(change.writes.keys.sorted())")
        check("capture: preconditions cover every written key at its old value",
              change.expected[KeychainHelper.serperApiKeyKey] == SettingsDigest.of("serper-synthetic-old-0001")
              && change.expected[KeychainHelper.keylessSearchKey] == SettingsDigest.absent)
        check("capture: the epoch read before preparation is recorded", change.epoch == 0)
        check("capture: the category of a search key change is ai", change.category == "ai")
        // Removal → a delete in the delta.
        let removal = await prepare { try KeychainHelper.delete(key: KeychainHelper.serperApiKeyKey) }
        check("capture: a removal is a delete", removal?.deletes == [KeychainHelper.serperApiKeyKey] && removal?.writes.isEmpty == true)
        // A read of the whole store adds the route digest.
        let whole = await prepare { _ = KeychainHelper.loadSnapshot(); try KeychainHelper.save(key: KeychainHelper.userNameKey, value: "New") }
        check("capture: a whole-store read records the route digest", whole?.routeDigest == SettingsKeyRoles.routeDigest(store()))
        // A failed request: nothing committed, applied emptied.
        let (failed, failedReply) = await SettingsCapture.prepare(origin: "selftest", label: "bad") {
            await SetupAPICore.apply(["telegram": ["token": "123:abc", "chat_id": "letters"]], ownsLease: true)
        }
        check("capture: a refused request prepares no change", failed == nil, "\(failedReply)")
        check("capture: a refused request reports nothing applied", (failedReply["applied"] as? [String])?.isEmpty ?? true)
        // Identity: recorded, not reserved.
        let email = await prepare { try IdentityChange.apply(kind: .inbox, rawValue: "agent@example.invalid") {
            try KeychainHelper.save(key: KeychainHelper.agentMailInboxAddressKey, value: "agent@example.invalid")
        } }
        check("capture: an inbox change is recorded as the identity operation",
              email?.identity == SettingsIdentityOp(kind: "inbox", value: "agent@example.invalid"))
        check("capture: an inbox-only change is in the email slot", email?.category == "email")
    }

    func captureEdgeSection() async {
        reset(Self.routeBase)
        // The /websearch choice lands in secrets.json; the preference mirror
        // is recorded, not written, during preparation.
        Prefs.store.removeObject(forKey: WebSearchBackend.selectionKey)
        let (change, _) = await SettingsCapture.prepare(origin: "selftest", label: "backend") {
            await SetupAPICore.apply(["web_search_backend": "opencode"], ownsLease: true)
        }
        check("capture: /websearch is a secrets key now", change?.writes[WebSearchBackend.secretsSelectionKey] == "opencode")
        check("capture: the downgrade mirror is recorded, not written",
              change?.webBackendMirror == "opencode" && Prefs.store.string(forKey: WebSearchBackend.selectionKey) == nil)
        // Pure evaluation: reads come from the dictionary; writes are refused.
        let evaluated = SettingsCapture.evaluate(store: [KeychainHelper.serperApiKeyKey: "x"]) {
            KeychainHelper.load(key: KeychainHelper.serperApiKeyKey)
        }
        check("evaluate: resolvers read the given dictionary", evaluated == "x")
        var threw = false
        SettingsCapture.evaluate(store: [:]) {
            do { try KeychainHelper.save(key: "k", value: "v") } catch { threw = true }
        }
        check("evaluate: a write inside a pure evaluation is refused", threw)
        // Nested capture: the inner change is its own; the outer is untouched by it.
        var inner: PreparedChange?
        let outer = await prepare {
            try KeychainHelper.save(key: KeychainHelper.userNameKey, value: "Outer")
        }
        _ = await SettingsCapture.prepare(origin: "selftest", label: "outer") {
            inner = await self.prepare { try KeychainHelper.save(key: KeychainHelper.jinaApiKeyKey, value: "jina-synthetic-1") }
            return ["ok": true]
        }
        check("capture: a nested preparation produces its own change",
              inner?.writes[KeychainHelper.jinaApiKeyKey] == "jina-synthetic-1" && outer?.writes[KeychainHelper.jinaApiKeyKey] == nil)
    }

    // MARK: Roles (completeness guard)

    func rolesCompletenessSection() {
        // Every key constant the code defines in the files the credential
        // catalog scans is matched by exactly one role pattern.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let files = ["Utilities/KeychainHelper.swift", "Services/ProviderProfiles.swift", "Services/ProviderServers.swift",
                     "Services/OpenRouterPinMap.swift", "Services/SubscriptionSharing.swift"]
        var unmatched: [String] = []
        var doubled: [String] = []
        var scanned = 0
        let pattern = try? NSRegularExpression(pattern: #"static let (\w+Key)\s*=\s*"([^"]+)""#)
        for file in files {
            guard let text = try? String(contentsOf: root.appendingPathComponent(file), encoding: .utf8), let pattern else { continue }
            for m in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let r = Range(m.range(at: 2), in: text) else { continue }
                let key = String(text[r])
                scanned += 1
                switch SettingsKeyRoles.matchCount(key) {
                case 0: unmatched.append(key)
                case 1: break
                default: doubled.append(key)
                }
            }
        }
        if scanned == 0 {
            // A build without sources next to it: the runtime list instead.
            for key in CredentialCatalog.entries.map(\.key) { if SettingsKeyRoles.matchCount(key) != 1 { unmatched.append(key) } }
        }
        check("roles: every key constant matches a role (\(scanned) scanned)", unmatched.isEmpty, unmatched.joined(separator: ", "))
        check("roles: no key matches two roles", doubled.isEmpty, doubled.joined(separator: ", "))
        // Generated families and settings bookkeeping.
        let generated = [SubagentModelLanes.storageKey(.cheapText, provider: .openRouter),
                         SubagentModelLanes.storageKey(.cheapVision, provider: .openAICompatible),
                         KeychainHelper.serviceKeyPrefix + "DEPLOY", "mcp_env_server_TOKEN",
                         SettingsWriter.attemptMarkerKey("ai"), SettingsWriter.scopePublishedKey,
                         WebSearchBackend.secretsSelectionKey, SetupWizard.progressKey, SetupWizard.completeKey]
        let bad = generated.filter { SettingsKeyRoles.matchCount($0) != 1 }
        check("roles: generated key families match exactly one role", bad.isEmpty, bad.joined(separator: ", "))
        check("roles: an unknown key is treated as a route input (conservative)",
              SettingsKeyRoles.role("some_future_key") == .route)
        // Every key the catalog knows is classified too.
        let catalogMissing = CredentialCatalog.entries.map(\.key).filter { SettingsKeyRoles.matchCount($0) != 1 }
        check("roles: every credential-catalog key has exactly one role", catalogMissing.isEmpty, catalogMissing.joined(separator: ", "))
    }

    /// Activating scenarios: a route key's value, a credential's presence,
    /// and never an other key or a credential's value, change the snapshot.
    func rolesMutationSection() {
        let switches = SettingsToolSwitches(subagents: true, webSubagent: true)
        func snap(_ s: [String: String]) -> RouteSnapshot { RouteSnapshot.of(stored: s, subscription: .absent, switches: switches) }
        var base = Self.routeBase
        for key in SettingsKeyRoles.credentialKeys { base[key] = "present-\(key)" }
        let original = snap(base)
        var routeMisses: [String] = [], credValue: [String] = [], credPresence: [String] = [], otherHits: [String] = []
        for key in SettingsKeyRoles.routeKeys {
            var s = base; s[key] = (s[key] ?? "") + "-changed"
            if snap(s) == original { routeMisses.append(key) }
        }
        for key in SettingsKeyRoles.credentialKeys {
            var s = base; s[key] = "replaced-\(key)"
            if snap(s) != original { credValue.append(key) }
            s.removeValue(forKey: key)
            if snap(s) == original { credPresence.append(key) }
        }
        for key in SettingsKeyRoles.otherKeys {
            var s = base; s[key] = "changed"
            if snap(s) != original { otherHits.append(key) }
        }
        check("roles: every route key's value changes the snapshot", routeMisses.isEmpty, routeMisses.joined(separator: ", "))
        check("roles: a credential's new value never changes the snapshot", credValue.isEmpty, credValue.joined(separator: ", "))
        check("roles: a credential's presence changes the snapshot", credPresence.isEmpty, credPresence.joined(separator: ", "))
        check("roles: no other key changes the snapshot", otherHits.isEmpty, otherHits.joined(separator: ", "))
        // Against the request path's own resolvers: whenever a resolver's
        // output differs, the snapshot differs too (soundness).
        var unsound: [String] = []
        let resolverScenarios: [(String, [String: String], [String: String])] = [
            ("transcription", base, base.merging([KeychainHelper.voiceTranscriptionProviderKey: "local"]) { $1 }),
            ("image backend", base, base.merging([KeychainHelper.imageGenerationProviderKey: "openai"]) { $1 }),
            ("image via key removal", base, base.filter { $0.key != KeychainHelper.openAIImageApiKeyKey }),
            ("search via Serper removal", base, base.filter { $0.key != KeychainHelper.serperApiKeyKey }),
            ("search switch", base.filter { $0.key != KeychainHelper.serperApiKeyKey },
             base.filter { $0.key != KeychainHelper.serperApiKeyKey }.merging([KeychainHelper.keylessSearchKey: "false"]) { $1 }),
            ("extraction backend", base, base.merging([WebSearchBackend.secretsSelectionKey: "opencode", KeychainHelper.llmProviderKey: "openai_compatible"]) { $1 }),
        ]
        for (name, a, b) in resolverScenarios {
            let resolved: ([String: String]) -> String = { s in
                SettingsCapture.evaluate(store: s) {
                    "\(MediaRouting.transcription(stored: s))|\(MediaRouting.imageBackend(stored: s))|\(KeylessSearchSwitch.resolve(snapshot: s).rawValue)|\(WebSearchBackend.selection(stored: s))"
                }
            }
            if resolved(a) != resolved(b) && snap(a) == snap(b) { unsound.append(name) }
        }
        check("roles: a resolver change always changes the snapshot (activating scenarios)", unsound.isEmpty, unsound.joined(separator: ", "))
    }

    // MARK: Classification

    func classifySection() async {
        let switches = SettingsToolSwitches(subagents: true, webSubagent: true)
        func differs(_ a: [String: String], _ b: [String: String], _ fa: SubscriptionRouteFacts = .absent, _ fb: SubscriptionRouteFacts = .absent) -> Bool {
            RouteSnapshot.of(stored: a, subscription: fa, switches: switches) != RouteSnapshot.of(stored: b, subscription: fb, switches: switches)
        }
        let base = Self.routeBase
        check("classify: replacing a key with another is S", !differs(base, base.merging([KeychainHelper.serperApiKeyKey: "other-key"]) { $1 }))
        check("classify: removing the Serper key is D (search moves to the free service)",
              differs(base, base.filter { $0.key != KeychainHelper.serperApiKeyKey }))
        check("classify: a model change is D", differs(base, base.merging([KeychainHelper.openRouterModelKey: "openai/gpt-6-luna"]) { $1 }))
        check("classify: the user's name is S", !differs(base, base.merging([KeychainHelper.userNameKey: "Other"]) { $1 }))
        let usable = SubscriptionRouteFacts(present: true, requiresLogin: false, accountFingerprint: "fp-a")
        let relogin = SubscriptionRouteFacts(present: true, requiresLogin: false, accountFingerprint: "fp-a")
        let other = SubscriptionRouteFacts(present: true, requiresLogin: false, accountFingerprint: "fp-b")
        check("classify: a ChatGPT login for another lane is S (OpenRouter active)", !differs(base, base, .absent, usable))
        var chat = base; chat[ProviderProfiles.activeProfileKey] = "chatgpt"
        check("classify: the same account signing in again while ChatGPT runs is S", !differs(chat, chat, usable, relogin))
        check("classify: a different account while ChatGPT runs is D", differs(chat, chat, usable, other))
        check("classify: signing out the active ChatGPT login is D", differs(chat, chat, usable, .absent))
        check("classify: activating ChatGPT is D", differs(base, chat, usable, usable))
        check("classify: a tool switch is part of the snapshot",
              RouteSnapshot.of(stored: base, subscription: .absent, switches: switches)
              != RouteSnapshot.of(stored: base, subscription: .absent, switches: SettingsToolSwitches(subagents: false, webSubagent: true)))
    }
}
