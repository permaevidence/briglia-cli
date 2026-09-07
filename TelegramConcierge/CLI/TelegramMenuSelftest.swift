import ArgumentParser
import Foundation

/// Telegram inline-keyboard command menus (owner request 2026-09-07): the
/// callback payload codec and its bounds, the three menu builders and the
/// owner's button policy (OpenCode catalog + ChatGPT four, text-only
/// elsewhere), the wire shape of a keyboard send — and that a plain send is
/// unchanged — the callback_query decode, the pairing gate the tap path
/// reuses, and the ChatGPT list staying in step with the two browser pages.
/// Pure static checks — no storage, no network.
struct TelegramMenuSelftest: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__telegram-menu-selftest",
        abstract: "Internal: verify the Telegram inline-keyboard menus for /provider, /model and /effort.",
        shouldDisplay: false
    )

    func run() throws {
        var total = 0
        var failures = 0
        func check(_ label: String, _ ok: Bool, _ detail: String = "") {
            total += 1
            print("\(ok ? "✔" : "✖") \(label)\(ok || detail.isEmpty ? "" : " — \(detail)")")
            if !ok { failures += 1 }
        }
        typealias Menu = TelegramCommandMenu

        // ---- 1. Codec: round trip for every id a button can carry, bound
        // to its context (profile for models, profile+model hash for effort).
        let ctx = Menu.effortContext(profile: "opencode", model: "kimi-k3")
        var roundTrips: [Menu.Action] = ProviderProfiles.Profile.allCases.map { .provider($0.rawValue) }
        roundTrips += OpenCodeGo.choices.map { .model(profile: "opencode", id: $0.id) }
        roundTrips += ResponsesAdapter.subscriptionModelChoices.map { .model(profile: "chatgpt", id: $0.id) }
        roundTrips += ["none", "minimal", "low", "medium", "high", "xhigh", "max", "off"].map { .effort(context: ctx, level: $0) }
        roundTrips.append(.modelTyped)
        var bad: [String] = []
        for action in roundTrips {
            guard let data = Menu.encode(action) else { bad.append("\(action): unencodable"); continue }
            if data.utf8.count > Menu.maxDataBytes { bad.append("\(data): \(data.utf8.count) bytes") }
            if Menu.decode(data) != action { bad.append("\(data) → \(String(describing: Menu.decode(data)))") }
        }
        check("codec: every catalog action round-trips within 64 bytes (\(roundTrips.count))", bad.isEmpty, bad.joined(separator: "; "))
        check("codec: payload shapes bm1:p:<profile>, bm1:m:<profile>:<id>, bm1:m:?, bm1:e:<context>:<level>",
              Menu.encode(.provider("opencode")) == "bm1:p:opencode"
              && Menu.encode(.model(profile: "opencode", id: "kimi-k3")) == "bm1:m:opencode:kimi-k3"
              && Menu.encode(.modelTyped) == "bm1:m:?"
              && Menu.encode(.effort(context: ctx, level: "high")) == "bm1:e:\(ctx):high")
        check("codec: the longest catalog model + effort payloads stay under the cap",
              (Menu.encode(.model(profile: "opencode", id: "deepseek-v4-flash-vision-exp"))?.utf8.count ?? 99) <= 64
              && (Menu.encode(.effort(context: ctx, level: "minimal"))?.utf8.count ?? 99) <= 64)

        check("effort context: 8 lowercase hex, deterministic, differs by profile and by model",
              Menu.isValidContext(ctx) && ctx == Menu.effortContext(profile: "opencode", model: "kimi-k3")
              && ctx != Menu.effortContext(profile: "custom", model: "kimi-k3")
              && ctx != Menu.effortContext(profile: "opencode", model: "glm-5.3-flash")
              && Menu.isValidContext(Menu.effortContext(profile: "custom", model: "meta-llama/Llama-4 Maverick")))

        let rejected = ["", "bm1", "bm1:e", "bm1:e:", "bm0:e:\(ctx):high", "BM1:e:\(ctx):high", "bm1:x:\(ctx):high",
                        "bm1:e:\(ctx):hi gh", "bm1:e:\(ctx):/stop", "bm1:e:high", "bm1:e:zz:high", "bm1:e:1234567:high",
                        "bm1:e:ABCDEF01:high", "bm1:e:\(ctx):high:extra",
                        "bm1:m:opencode:" + String(repeating: "a", count: Menu.maxArgumentLength + 1),
                        "bm1:m:opencode:glm;rm", "bm1:m:Open Code:kimi-k3", "bm1:m:opencode", "bm1:m:?:kimi-k3",
                        "bm1:p:opencode:extra", "bm1:p:Open Code", "bm1:e:" + String(repeating: "x", count: 70)]
        let accepted = rejected.filter { Menu.decode($0) != nil }
        check("codec: malformed, unbound (pre-context), foreign-version, whitespace, shell-ish, bad-context and oversized payloads decode to nil",
              accepted.isEmpty, accepted.joined(separator: " | "))
        check("codec: unencodable arguments are refused at build time",
              Menu.encode(.model(profile: "opencode", id: "has space")) == nil
              && Menu.encode(.effort(context: "nothex", level: "high")) == nil
              && Menu.encode(.effort(context: ctx, level: "")) == nil
              && Menu.encode(.model(profile: "opencode", id: String(repeating: "m", count: 60))) == nil)

        check("commandText: taps map to the exact typed commands (context stripped), the typed-model button to none",
              Menu.commandText(for: .provider("chatgpt")) == "/provider chatgpt"
              && Menu.commandText(for: .model(profile: "opencode", id: "glm-5.3-flash")) == "/model glm-5.3-flash"
              && Menu.commandText(for: .effort(context: ctx, level: "off")) == "/effort off"
              && Menu.commandText(for: .modelTyped) == nil)

        // ---- 2. /provider menu: configured profiles only, active ticked.
        let status = ["• opencode — ACTIVE", "• chatgpt — subscription"]
        let providerMenu = Menu.providerMenu(statusLines: status, configured: [
            .init(id: "opencode", displayName: "OpenCode Go", active: true),
            .init(id: "chatgpt", displayName: "ChatGPT subscription", active: false),
            .init(id: "openrouter", displayName: "OpenRouter", active: false),
        ])
        check("provider menu: two buttons per row, active profile ticked, payloads carry the profile ids",
              providerMenu.rows.map { $0.map(\.label) } == [["✓ OpenCode Go", "ChatGPT subscription"], ["OpenRouter"]]
              && providerMenu.rows.flatMap { $0 }.map(\.data) == ["bm1:p:opencode", "bm1:p:chatgpt", "bm1:p:openrouter"],
              "\(providerMenu.rows)")
        check("provider menu: text keeps the status listing and the typed-command hint",
              status.allSatisfy { providerMenu.text.contains($0) } && providerMenu.text.contains("/provider <name>"))
        check("provider menu: nothing configured → no keyboard (plain text)",
              Menu.providerMenu(statusLines: status, configured: []).rows.isEmpty
              && Menu.keyboard(for: Menu.providerMenu(statusLines: status, configured: [])) == nil)

        // ---- 3. /model menu: OpenCode catalog in catalog order + typed button,
        // every button bound to the profile; ChatGPT exactly the owner's four.
        let opencodeChoices = OpenCodeGo.choices.map { Menu.ModelChoice(id: $0.id, label: $0.label, textOnly: $0.textOnly) }
        let ocMenu = Menu.modelMenu(catalog: .opencode(opencodeChoices), profile: "opencode", current: "kimi-k3")
        let ocData = ocMenu.rows.map { $0.map(\.data) }
        check("model menu (OpenCode): one row per catalog entry in catalog order, bound to the profile, then the typed-model button",
              ocData == OpenCodeGo.choices.map { ["bm1:m:opencode:\($0.id)"] } + [["bm1:m:?"]], "\(ocData)")
        let kimiRow = ocMenu.rows.first { $0.first?.data == "bm1:m:opencode:kimi-k3" }?.first
        let textOnlyRow = ocMenu.rows.first { $0.first?.data == "bm1:m:opencode:glm-5.3" }?.first
        check("model menu (OpenCode): active model ticked, text-only models tagged, typed button last",
              kimiRow?.label == "✓ Kimi K3" && textOnlyRow?.label == "GLM 5.3 · text-only"
              && ocMenu.rows.last?.first?.label == "Type a model name…" && ocMenu.text.contains("Current model: kimi-k3"))
        let gptMenu = Menu.modelMenu(catalog: .chatgpt, profile: "chatgpt", current: "gpt-6-astra")
        check("model menu (ChatGPT): exactly Luna, Terra, Sol, Astra bound to chatgpt + typed button",
              gptMenu.rows.map { $0.map(\.data) } == [["bm1:m:chatgpt:gpt-5.6-luna"], ["bm1:m:chatgpt:gpt-5.6-terra"], ["bm1:m:chatgpt:gpt-5.6-sol"], ["bm1:m:chatgpt:gpt-6-astra"], ["bm1:m:?"]]
              && gptMenu.rows[3].first?.label == "✓ GPT-6 Astra", "\(gptMenu.rows.map { $0.map(\.label) })")
        check("model menu: keeps the typed-command hint for users who prefer typing",
              ocMenu.text.contains("/model <model-id>") && gptMenu.text.contains("/model <model-id>"))

        // ---- 4. /effort menu: provider's levels three per row, off row only
        // where /effort off is accepted, current ticked (off when unset),
        // every button bound to the context.
        let astra = ResponsesAdapter.allowedEfforts(model: "gpt-6-astra")
        let astraCtx = Menu.effortContext(profile: "chatgpt", model: "gpt-6-astra")
        let astraMenu = Menu.effortMenu(levels: astra, context: astraCtx, current: "high", currentDescription: "high", offAllowed: true)
        check("effort menu (Astra): low…max in three-per-row chunks + the endpoint-default row, all bound to the context",
              astraMenu.rows.map { $0.map(\.data) } == [["bm1:e:\(astraCtx):low", "bm1:e:\(astraCtx):medium", "bm1:e:\(astraCtx):high"], ["bm1:e:\(astraCtx):xhigh", "bm1:e:\(astraCtx):max"], ["bm1:e:\(astraCtx):off"]]
              && astraMenu.rows[0][2].label == "✓ high" && astraMenu.rows[2][0].label == "Endpoint default (off)",
              "\(astraMenu.rows)")
        let chatLevels = ["minimal", "low", "medium", "high", "xhigh"]
        let orMenu = Menu.effortMenu(levels: chatLevels, context: ctx, current: "", currentDescription: "high (default)", offAllowed: false)
        check("effort menu (OpenRouter): no off row, nothing ticked when unset",
              orMenu.rows.flatMap { $0 }.map(\.data) == chatLevels.map { "bm1:e:\(ctx):\($0)" }
              && !orMenu.rows.flatMap { $0 }.contains { $0.label.hasPrefix("✓") } && !orMenu.text.contains("/effort off"))
        let unsetOff = Menu.effortMenu(levels: chatLevels, context: ctx, current: "", currentDescription: "not sent (endpoint default)", offAllowed: true)
        check("effort menu (custom, unset): the endpoint-default row is the ticked one",
              unsetOff.rows.last?.first?.label == "✓ Endpoint default (off)")

        // ---- 5. Wire shape: keyboard send carries reply_markup; a plain send
        // encodes exactly the pre-keyboard body (no reply_markup key at all).
        let encoder = JSONEncoder()
        func json(_ data: Data) -> [String: Any] { (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:] }
        let plain = json(try encoder.encode(TelegramSendMessageRequest(chatId: 7, text: "hi", parseMode: nil, replyMarkup: nil)))
        check("wire: plain sendMessage body has exactly chat_id + text",
              Set(plain.keys) == ["chat_id", "text"], "\(plain.keys.sorted())")
        let withKeyboard = json(try encoder.encode(TelegramSendMessageRequest(
            chatId: 7, text: "menu", parseMode: nil, replyMarkup: Menu.keyboard(for: astraMenu))))
        let markup = withKeyboard["reply_markup"] as? [String: Any]
        let rows = markup?["inline_keyboard"] as? [[[String: Any]]]
        check("wire: keyboard send carries reply_markup.inline_keyboard rows with text + callback_data",
              rows?.count == 3 && rows?[0].count == 3
              && rows?[0][0]["text"] as? String == "low" && rows?[0][0]["callback_data"] as? String == "bm1:e:\(astraCtx):low",
              "\(withKeyboard)")
        let answer = json(try encoder.encode(TelegramAnswerCallbackQueryRequest(callbackQueryId: "cq1", text: nil, showAlert: nil)))
        check("wire: a plain answerCallbackQuery carries only callback_query_id", Set(answer.keys) == ["callback_query_id"])
        let edit = json(try encoder.encode(TelegramEditMessageTextRequest(chatId: 7, messageId: 3, text: "frozen")))
        check("wire: editMessageText carries chat_id, message_id, text and NO reply_markup (keyboard removed)",
              Set(edit.keys) == ["chat_id", "message_id", "text"])

        // ---- 6. Decode: a callback_query update, an inaccessible-message
        // form, and a message update still decoding with callbackQuery nil.
        let decoder = JSONDecoder()
        let tap = """
        {"update_id": 501, "callback_query": {"id": "4382", "from": {"id": 12345, "is_bot": false, "first_name": "M"},
         "message": {"message_id": 77, "date": 1, "text": "Providers", "chat": {"id": 12345, "type": "private"}},
         "chat_instance": "-1", "data": "bm1:m:chatgpt:gpt-6-astra"}}
        """
        let tapUpdate = try? decoder.decode(TelegramUpdate.self, from: Data(tap.utf8))
        check("decode: callback_query update yields id, sender, menu message and data",
              tapUpdate?.message == nil && tapUpdate?.callbackQuery?.id == "4382"
              && tapUpdate?.callbackQuery?.from.id == 12345 && tapUpdate?.callbackQuery?.message?.messageId == 77
              && tapUpdate?.callbackQuery?.message?.text == "Providers" && tapUpdate?.callbackQuery?.data == "bm1:m:chatgpt:gpt-6-astra")
        let inaccessible = """
        {"update_id": 502, "callback_query": {"id": "9", "from": {"id": 12345, "is_bot": false, "first_name": "M"},
         "message": {"message_id": 78, "date": 0, "chat": {"id": 12345, "type": "private"}}, "chat_instance": "-1", "data": "bm1:m:?"}}
        """
        let inaccessibleUpdate = try? decoder.decode(TelegramUpdate.self, from: Data(inaccessible.utf8))
        check("decode: Bot API 7 inaccessible-message form (date 0, no text) still decodes",
              inaccessibleUpdate?.callbackQuery?.message?.messageId == 78 && inaccessibleUpdate?.callbackQuery?.message?.text == nil)
        let plainMessage = """
        {"update_id": 503, "message": {"message_id": 5, "date": 1, "text": "/effort", "chat": {"id": 12345, "type": "private"},
         "from": {"id": 12345, "is_bot": false, "first_name": "M"}}}
        """
        let messageUpdate = try? decoder.decode(TelegramUpdate.self, from: Data(plainMessage.utf8))
        check("decode: message update unchanged — callbackQuery nil, text intact",
              messageUpdate?.callbackQuery == nil && messageUpdate?.message?.text == "/effort")

        // ---- 7. The tap path reuses the fail-closed pairing gate: paired
        // private chat AND paired sender; anything else is dropped.
        check("gate: paired sender in the paired private chat is accepted",
              TelegramPairing.acceptsPolledMessage(chatId: 12345, chatType: "private", fromId: 12345, pairedChatId: 12345))
        check("gate: foreign sender, group chat, no sender and unpaired install are all refused",
              !TelegramPairing.acceptsPolledMessage(chatId: 12345, chatType: "private", fromId: 999, pairedChatId: 12345)
              && !TelegramPairing.acceptsPolledMessage(chatId: 12345, chatType: "group", fromId: 12345, pairedChatId: 12345)
              && !TelegramPairing.acceptsPolledMessage(chatId: 12345, chatType: "private", fromId: nil, pairedChatId: 12345)
              && !TelegramPairing.acceptsPolledMessage(chatId: 12345, chatType: "private", fromId: 12345, pairedChatId: nil))

        // ---- 8. The ChatGPT list is one source: both browser pages' pickers
        // must list exactly these ids, in this order, plus "custom".
        let expected = ResponsesAdapter.subscriptionModelChoices.map(\.id)
        check("chatgpt list: exactly the owner's four, in order",
              expected == ["gpt-5.6-luna", "gpt-5.6-terra", "gpt-5.6-sol", "gpt-6-astra"])
        if let quickSetup = Bundle.module.resourceURL?.appendingPathComponent("QuickSetup", isDirectory: true) {
            for page in ["index.html", "settings.html"] {
                let html = (try? String(contentsOf: quickSetup.appendingPathComponent(page), encoding: .utf8)) ?? ""
                let options = Self.subscriptionPickerOptions(in: html)
                check("chatgpt list: \(page) picker matches the Swift list (+ custom)",
                      options == expected + ["custom"], "\(options)")
            }
        } else {
            check("chatgpt list: QuickSetup resources reachable", false)
        }

        // ---- 9. Frozen-menu text.
        check("frozen text: original menu + note; note alone when the menu text is unavailable",
              Menu.frozenText(original: "Menu", note: "▸ /effort high") == "Menu\n\n▸ /effort high"
              && Menu.frozenText(original: "", note: "n") == "n")

        print("\n\(total - failures)/\(total) checks passed")
        if failures > 0 { throw ExitCode.failure }
    }

    /// Option values of the `subscription-model-choice` <select>, in order.
    static func subscriptionPickerOptions(in html: String) -> [String] {
        guard let start = html.range(of: "id=\"subscription-model-choice\""),
              let end = html.range(of: "</select>", range: start.upperBound..<html.endIndex) else { return [] }
        let block = String(html[start.upperBound..<end.lowerBound])
        guard let regex = try? NSRegularExpression(pattern: #"<option value="([^"]*)""#) else { return [] }
        return regex.matches(in: block, range: NSRange(block.startIndex..., in: block)).compactMap {
            Range($0.range(at: 1), in: block).map { String(block[$0]) }
        }
    }
}
