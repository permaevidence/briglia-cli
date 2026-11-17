#!/usr/bin/env python3
"""Deliberate breaks for the GPT-6.2 Sol / GPT-6.2 Astra tables (0.2.71).

Same method as gpt_profile_break_test.py: copy the tree to a scratch
directory, build once (positive controls: every selftest a break is judged
by passes on the unmodified copy), then apply one mutation at a time,
rebuild incrementally and require the NAMED check (a label prefix) to be
reported as failed (✖). The repository is never modified.

Every binary this script runs is a hard link under a private process name
beside the built one (never `briglia`): on macOS the preferences domain
follows the executable name.

Usage: python3 scripts/gpt62_models_break_test.py [--keep-build DIR] [--only B1,B2] [--verbose] [--dry-anchors]
"""
import argparse
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LINUX_JOBS = ["-j", "2"] if sys.platform.startswith("linux") else []
S = "TelegramConcierge/Services/"
CLI = "TelegramConcierge/CLI/"
Q = "TelegramConcierge/Resources/QuickSetup/"
FIXTURES = ROOT / "scripts/fixtures/codex-apply-patch"
LINK_NAME = "briglia-gpt62-break"

PROVIDER = ["__provider-selftest"]
TELEGRAM = ["__telegram-menu-selftest"]
PIN = ["__or-pin-selftest"]
GP = ["__gpt-profile-selftest", "--fixtures", str(FIXTURES), "--only", "M,R,G"]
SIWC = ["__siwc-selftest", "--only", "gpt-patch"]
MENU = ["__menu-selftest"]
CONTROLS = [PROVIDER, TELEGRAM, PIN, GP, SIWC, MENU]

EFFORT_ROW = '        if ["gpt-6-astra", "gpt-6.1-sol", "gpt-6.2-sol", "gpt-6.2-astra"].contains(where: {\n            model == $0 || model.hasPrefix($0 + "-20")\n        }) {\n            return ["low", "medium", "high", "xhigh", "max"]'

# (id label, failing check prefix, [(file, old, new), ...], selftest args)
BREAKS = [
    ("B1 the new-setup default left at GPT-6.1 Sol", "P1d GPT-6.2 Sol is the subscription default and first in the catalog", [(S + "ResponsesAdapter.swift",
        '    static let subscriptionDefaultModel = "gpt-6.2-sol"', '    static let subscriptionDefaultModel = "gpt-6.1-sol"')], PROVIDER),
    ("B2 the default left at GPT-6.1 Sol: an unset profile", "S2 with no stored subscription model the default is GPT-6.2 Sol", [(S + "ResponsesAdapter.swift",
        '    static let subscriptionDefaultModel = "gpt-6.2-sol"', '    static let subscriptionDefaultModel = "gpt-6.1-sol"')], PROVIDER),
    ("B3 the default is GPT-6.2 Astra", "P1d GPT-6.2 Sol is the subscription default and first in the catalog", [(S + "ResponsesAdapter.swift",
        '    static let subscriptionDefaultModel = "gpt-6.2-sol"', '    static let subscriptionDefaultModel = "gpt-6.2-astra"')], PROVIDER),
    ("B4 GPT-6.2 Sol missing from the low…max effort row", "P1d gpt-6.2-sol takes low…max only", [(S + "ResponsesAdapter.swift",
        EFFORT_ROW, EFFORT_ROW.replace('"gpt-6.1-sol", "gpt-6.2-sol", "gpt-6.2-astra"', '"gpt-6.1-sol", "gpt-6.2-astra"'))], PROVIDER),
    ("B5 GPT-6.2 Astra missing from the low…max effort row", "P1d gpt-6.2-astra takes low…max only", [(S + "ResponsesAdapter.swift",
        EFFORT_ROW, EFFORT_ROW.replace('"gpt-6.1-sol", "gpt-6.2-sol", "gpt-6.2-astra"', '"gpt-6.1-sol", "gpt-6.2-sol"'))], PROVIDER),
    ("B6 the effort row matches by loose prefix", "P1d a model that only looks like GPT-6.2 Sol / Astra keeps the common list", [(S + "ResponsesAdapter.swift",
        EFFORT_ROW, EFFORT_ROW.replace('model == $0 || model.hasPrefix($0 + "-20")', 'model.hasPrefix($0)'))], PROVIDER),
    ("B7 the new models put in the none…max row (none would be sent and refused)", "P1d gpt-6.2-sol: a stored none/minimal becomes low", [(S + "ResponsesAdapter.swift",
        EFFORT_ROW + '\n        }\n        if ["gpt-6-sol", "gpt-6-luna",',
        EFFORT_ROW.replace('"gpt-6.1-sol", "gpt-6.2-sol", "gpt-6.2-astra"', '"gpt-6.1-sol"') + '\n        }\n        if ["gpt-6.2-sol", "gpt-6.2-astra", "gpt-6-sol", "gpt-6-luna",')], PROVIDER),
    ("B8 an older model's effort list changed with the row", "P1d every older catalog model keeps its 0.2.70 effort list", [(S + "ResponsesAdapter.swift",
        EFFORT_ROW, EFFORT_ROW.replace('"gpt-6-astra", "gpt-6.1-sol", "gpt-6.2-sol"', '"gpt-6-astra", "gpt-6-sol", "gpt-6.1-sol", "gpt-6.2-sol"'))], PROVIDER),
    ("B9 /model no longer turns none into low", "S2 /model gpt-6.2-sol on the subscription with effort 'none'", [(S + "ResponsesAdapter.swift",
        '        if ["none", "minimal"].contains(raw), allowed.contains("low") { return "low" }', '        if ["minimal"].contains(raw), allowed.contains("low") { return "low" }')], PROVIDER),
    ("B10 /model repairs the effort silently", "S2 /model gpt-6.2-astra on the subscription with effort 'none'", [(S + "ConversationManager+ModelCommands.swift",
        '''                note += compatible.map { " Reasoning effort \\"\\(effort)\\" isn't available on \\(stored); set to \\($0)." }
                    ?? " Reasoning effort \\"\\(effort)\\" isn't available on \\(stored); cleared (endpoint default)."
            }
        }
        try? KeychainHelper.saveBatch(changes)''',
        '''            }
        }
        try? KeychainHelper.saveBatch(changes)''')], PROVIDER),
    ("B11 catalog order: Astra before Sol", "chatgpt list: exactly the owner's nine", [(S + "ResponsesAdapter.swift",
        '        ("gpt-6.2-sol", "GPT-6.2 Sol"),\n        ("gpt-6.2-astra", "GPT-6.2 Astra"),', '        ("gpt-6.2-astra", "GPT-6.2 Astra"),\n        ("gpt-6.2-sol", "GPT-6.2 Sol"),')], TELEGRAM),
    ("B12 GPT-6.2 Astra missing from the catalog", "model menu (ChatGPT): exactly GPT-6.2 Sol, GPT-6.2 Astra", [(S + "ResponsesAdapter.swift",
        '        ("gpt-6.2-sol", "GPT-6.2 Sol"),\n        ("gpt-6.2-astra", "GPT-6.2 Astra"),', '        ("gpt-6.2-sol", "GPT-6.2 Sol"),')], TELEGRAM),
    ("B13 an older model dropped from the catalog", "chatgpt list: exactly the owner's nine", [(S + "ResponsesAdapter.swift",
        '        ("gpt-6.1-sol", "GPT-6.1 Sol"),\n', '')], TELEGRAM),
    ("B14 settings page picker lacks GPT-6.2 Astra", "chatgpt list: settings.html picker matches the Swift list", [(Q + "settings.html",
        '<option value="gpt-6.2-astra">GPT-6.2 Astra</option>', '')], TELEGRAM),
    ("B15 settings page effort rule lacks the new models", "chatgpt efforts: settings.js offers gpt-6.2-sol exactly", [(Q + "settings.js",
        " || /^gpt-6\\.2-(?:sol|astra)(?:-20.*)?$/.test(model)) return", ") return")], TELEGRAM),
    ("B16 settings page effort rule covers only Sol", "chatgpt efforts: settings.js offers gpt-6.2-astra exactly", [(Q + "settings.js",
        "/^gpt-6\\.2-(?:sol|astra)(?:-20.*)?$/", "/^gpt-6\\.2-sol(?:-20.*)?$/")], TELEGRAM),
    ("B17 the menu page still recommends GPT-6.1 Sol", "chatgpt list: menu.js recommends the new-setup default by name", [(Q + "menu.js",
        "T('Model — GPT-6.2 Sol is recommended. Not every plan includes every model.', 'Modello: consigliato GPT-6.2 Sol.",
        "T('Model — GPT-6.1 Sol is recommended. Not every plan includes every model.', 'Modello: consigliato GPT-6.1 Sol.")], TELEGRAM),
    ("B18 the Italian sentence recommends another model", "chatgpt list: menu.js recommends the new-setup default by name", [(Q + "menu.js",
        "'Modello: consigliato GPT-6.2 Sol. Non tutti i piani includono tutti i modelli.'", "'Modello: consigliato GPT-6.1 Sol. Non tutti i piani includono tutti i modelli.'")], TELEGRAM),
    ("B19 the menu page marks no model as recommended", "the ChatGPT model list starts with GPT-6.2 Sol (the only recommended one)", [(CLI + "Menu/MenuWorkflow.swift",
        '["id": $0.id, "label": $0.label, "recommended": $0.id == ResponsesAdapter.subscriptionDefaultModel] as [String: Any]',
        '["id": $0.id, "label": $0.label, "recommended": $0.id == "gpt-6.1-sol"] as [String: Any]')], MENU),
    ("B20 the menu sign-in default left at GPT-6.1 Sol", "after sign-in ChatGPT is selected with GPT-6.2 Sol", [(S + "ResponsesAdapter.swift",
        '    static let subscriptionDefaultModel = "gpt-6.2-sol"', '    static let subscriptionDefaultModel = "gpt-6.1-sol"')], MENU),
    ("B21 the menu offers the new models no Maximum", "ChatGPT (0.2.71): GPT-6.2 Sol and GPT-6.2 Astra offer Light to Maximum", [(CLI + "Menu/MenuWorkflow.swift",
        '            return (base + ["xhigh", "max"]).filter(allowed.contains)', '            return (base + ["xhigh"]).filter(allowed.contains)')], MENU),
    ("B22 Astra priced at GPT-6 Astra's rates", "G rates: GPT-6.2 Astra $8 / $40", [(S + "ResearchSpend.swift",
        '        ("gpt-6.2-astra", 8.0, 40.0),', '        ("gpt-6.2-astra", 10.0, 50.0),')], GP),
    ("B23 Sol has no rate row (priced as an unknown model)", "G rates: GPT-6.2 Astra $8 / $40, GPT-6.2 Sol $2 / $10", [(S + "ResearchSpend.swift",
        '        ("gpt-6.2-sol", 2.0, 10.0),\n', '')], GP),
    ("B24 a new rate row shadows an older family", "G rates: the older rows are unchanged and no row shadows another", [(S + "ResearchSpend.swift",
        '        ("gpt-6.2-astra", 8.0, 40.0),', '        ("gpt-6", 8.0, 40.0),')], GP),
    ("B25 the version parser stops at a minor version", "G matcher accepts gpt-6.2-sol", [(S + "CodexPatch/GPTEditing.swift",
        '        return next == "." || next == "-" || next == ":"', '        return next == "-" || next == ":"')], GP),
    ("B26 the provider prefix is not stripped", "G matcher accepts openai/gpt-6.2-astra", [(S + "CodexPatch/GPTEditing.swift",
        '        guard let slash = trimmed.lastIndex(of: "/") else { return trimmed }', '        guard let slash = trimmed.lastIndex(of: "/"), false else { return trimmed }')], GP),
    ("B27 the OpenAI key route is not freeform", "G gpt-6.2-sol on OpenAI key (api.openai.com Responses) → freeform", [(S + "CodexPatch/GPTEditing.swift",
        '    static let freeformHosts: Set<String> = ["openrouter.ai", "api.openai.com"]', '    static let freeformHosts: Set<String> = ["openrouter.ai"]')], GP),
    ("B28 OpenRouter chat gets the freeform form", "G gpt-6.2-astra on OpenRouter chat → JSON", [(S + "CodexPatch/GPTEditing.swift",
        '        guard context.wireProtocol == .responses else { return .jsonOnly }', '        guard context.wireProtocol == .responses else { return .freeformVerified }')], GP),
    ("B29 the Sign in with ChatGPT route is not freeform", "G gpt-6.2-sol on Sign in with ChatGPT route → freeform", [(S + "CodexPatch/GPTEditing.swift",
        '        if context.siwc != nil || context.siwcFailure != nil { return .freeformVerified }', '        if context.siwc != nil || context.siwcFailure != nil { return .jsonOnly }')], GP),
    ("B30 the legacy ChatGPT route is not freeform", "G gpt-6.2-astra on legacy ChatGPT route at its pinned endpoint → freeform", [(S + "CodexPatch/GPTEditing.swift",
        '            return context.endpoint == SubscriptionEndpoint.inference ? .freeformVerified : .jsonOnly', '            return .jsonOnly')], GP),
    ("B31 a refused effort reaches the wire (OpenAI key)", "G gpt-6.2-sol: effort none is refused before sending", [(S + "ResponsesAdapter.swift",
        '''            guard Self.allowedEfforts(model: context.model).contains(effort) else {
                throw ResponsesFailure.unsupported("reasoning effort \\(effort) for \\(context.model); use /effort off or a supported value")
            }
            body["reasoning"] = .object(["effort": .string(effort)])
        }
        if let maxOutputTokens''',
        '''            body["reasoning"] = .object(["effort": .string(effort)])
        }
        if let maxOutputTokens''')], GP),
    ("B32 max is rewritten on the way out", "G gpt-6.2-astra: effort max is sent verbatim", [(S + "ResponsesAdapter.swift",
        '''            body["reasoning"] = .object(["effort": .string(effort)])
        }
        if let maxOutputTokens''',
        '''            body["reasoning"] = .object(["effort": .string(effort == "max" ? "xhigh" : effort)])
        }
        if let maxOutputTokens''')], GP),
    ("B33 the grammar tool is not sent on the OpenAI key route", "G gpt-6.2-sol OpenAI key request: model verbatim, effort max verbatim, Codex grammar tool", [(S + "ResponsesAdapter.swift",
        '                if context.editing.form == .freeform, tool.function.name == "apply_patch" { return GPTFreeform.customToolEntry() }\n                let parameters = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(tool.function.parameters))\n                return .object(["type": .string("function"), "name": .string(tool.function.name),\n                    "description": .string(MarkerNeutralizer.escape(tool.function.description)),',
        '                let parameters = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(tool.function.parameters))\n                return .object(["type": .string("function"), "name": .string(tool.function.name),\n                    "description": .string(MarkerNeutralizer.escape(tool.function.description)),')], GP),
    ("B34 a refused effort reaches the wire (Sign in with ChatGPT)", "gpt-patch: gpt-6.2-sol on Sign in with ChatGPT: effort none is refused before anything is sent", [(S + "SIWC/ResponsesAdapter+SIWC.swift",
        '''            guard Self.allowedEfforts(model: context.model).contains(effort) else {
                throw ResponsesFailure.unsupported("reasoning effort \\(effort) for \\(context.model); use /effort off or a supported value")
            }
            body["reasoning"] = .object(["effort": .string(effort)])''',
        '''            body["reasoning"] = .object(["effort": .string(effort)])''')], SIWC),
    ("B35 the grammar tool leaves the namespace slot (Sign in with ChatGPT)", "gpt-patch: gpt-6.2-astra on Sign in with ChatGPT: freeform run, model and effort max verbatim", [(S + "CodexPatch/GPTEditing.swift",
        '        if context.siwc != nil || context.siwcFailure != nil { return .freeformVerified }', '        if context.siwc != nil || context.siwcFailure != nil { return .jsonOnly }')], SIWC),
    ("B36 the Sol preset has no host", "W62 the two new presets: keys, ids, labels and the OpenAI host", [(S + "OpenRouterPresets.swift",
        '        Preset(key: "sol62", id: "openai/gpt-6.2-sol", label: "GPT-6.2 Sol",\n               autoHost: "openai", autoHostName: "OpenAI"),',
        '        Preset(key: "sol62", id: "openai/gpt-6.2-sol", label: "GPT-6.2 Sol",\n               autoHost: nil, autoHostName: nil),')], PIN),
    ("B37 the Astra preset has no host: nothing pinned on a first pick", "W62 openai/gpt-6.2-astra: a first pick pins the OpenAI host", [(S + "OpenRouterPresets.swift",
        '        Preset(key: "astra62", id: "openai/gpt-6.2-astra", label: "GPT-6.2 Astra",\n               autoHost: "openai", autoHostName: "OpenAI"),',
        '        Preset(key: "astra62", id: "openai/gpt-6.2-astra", label: "GPT-6.2 Astra",\n               autoHost: nil, autoHostName: nil),')], PIN),
    ("B38 the Sol preset points at the Astra id", "W62 Telegram button bm1:r:sol62", [(S + "OpenRouterPresets.swift",
        '        Preset(key: "sol62", id: "openai/gpt-6.2-sol", label: "GPT-6.2 Sol",', '        Preset(key: "sol62", id: "openai/gpt-6.2-astra-x", label: "GPT-6.2 Sol",')], PIN),
    ("B39 an older preset's key changed", "W62 the five older presets keep their keys, ids, labels and hosts", [(S + "OpenRouterPresets.swift",
        '        Preset(key: "luna", id: "openai/gpt-6-luna", label: "GPT-6 Luna",', '        Preset(key: "luna6", id: "openai/gpt-6-luna", label: "GPT-6 Luna",')], PIN),
    ("B40 a GPT-6.2 preset becomes the setup default", "W62 the setup default is still the first preset", [(S + "OpenRouterPresets.swift",
        '    static let all: [Preset] = [\n', '    static let all: [Preset] = [\n        Preset(key: "sol62first", id: "openai/gpt-6.2-sol-first", label: "GPT-6.2 Sol", autoHost: "openai", autoHostName: "OpenAI"),\n')], PIN),
    ("B41 the openai pin covers the Fast tier", "W62 today's listing: the openai pin is served by the standard endpoint only", [(S + "OpenRouterProviderPin.swift",
        '    static let tierAliases: [String: String] = ["flex": "flex", "priority": "priority", "fast": "priority", "ultrafast": "ultrafast"]',
        '    static let tierAliases: [String: String] = ["flex": "flex"]')], PIN),
    ("B42 the Ultrafast tier is not known as a tier", "W62 today's listing without tier metadata", [(S + "OpenRouterProviderPin.swift",
        '    static let tierAliases: [String: String] = ["flex": "flex", "priority": "priority", "fast": "priority", "ultrafast": "ultrafast"]',
        '    static let tierAliases: [String: String] = ["flex": "flex", "priority": "priority", "fast": "priority"]')], PIN),
    ("B43 an upgrade pins the new presets on existing installs", "W62 openai/gpt-6.2-sol: the frozen upgrade rule gives no upgrade marker", [(S + "OpenRouterPinMap.swift",
        '        "deepseek/deepseek-v4.1-flash", "anthropic/claude-haiku-5.5", "openai/gpt-6-luna", "z-ai/glm-5.3-flash",',
        '        "deepseek/deepseek-v4.1-flash", "anthropic/claude-haiku-5.5", "openai/gpt-6-luna", "z-ai/glm-5.3-flash", "openai/gpt-6.2-sol",')], PIN),
    ("B44 the Telegram picker drops a preset row", "W62 the OpenRouter menu: seven preset buttons in order + Other", [(S + "ConversationManager+ModelCommands.swift",
        '        OpenRouterPresets.all.map { preset in', '        OpenRouterPresets.all.dropLast().map { preset in')], PIN),
]


def run(cmd, cwd, timeout=None, env=None):
    return subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout, env=env)


def build(tree, scratch):
    r = run(["swift", "build", "--build-system", "native", *LINUX_JOBS, "--scratch-path", str(scratch)], tree, timeout=3600)
    if r.returncode != 0:
        raise RuntimeError("build failed:\n" + (r.stdout + r.stderr)[-3000:])
    out = run(["swift", "build", "--build-system", "native", "--scratch-path", str(scratch), "--show-bin-path"], tree).stdout.strip()
    return Path(out) / "briglia"


def private_link(binary):
    """A hard link (copy as fallback) under a private process name beside the
    binary, so the resource bundle next to it still resolves."""
    target = binary.parent / LINK_NAME
    try:
        target.unlink()
    except FileNotFoundError:
        pass
    try:
        os.link(binary, target)
    except OSError:
        shutil.copy2(binary, target)
    return target


def purge_prefs():
    if sys.platform != "darwin":
        return
    subprocess.run(["defaults", "delete", LINK_NAME], capture_output=True)
    try:
        (Path.home() / "Library/Preferences" / (LINK_NAME + ".plist")).unlink()
    except FileNotFoundError:
        pass


def selftest(binary, workdir, args):
    env = {k: v for k, v in os.environ.items() if not (k.startswith("BRIGLIA_") or k.startswith("ADA_"))}
    home = Path(workdir) / "home"
    for sub in (".config", ".local/share", "tmp"):
        (home / sub).mkdir(parents=True, exist_ok=True)
    env["HOME"] = str(home)
    env["CFFIXED_USER_HOME"] = str(home)
    env["XDG_CONFIG_HOME"] = str(home / ".config")
    env["XDG_DATA_HOME"] = str(home / ".local/share")
    env["TMPDIR"] = str(home / "tmp") + "/"
    try:
        return run([str(private_link(binary)), *args], workdir, timeout=1800, env=env)
    finally:
        purge_prefs()


def check_anchors():
    bad = 0
    for label, _, edits, _ in BREAKS:
        for rel, old, new in edits:
            n = (ROOT / rel).read_text().count(old)
            if n != 1 or old == new:
                bad += 1
                print(f"✖ anchor {label}: {rel}: found {n}: {old[:70]!r}")
    ids = [label.split()[0] for label, *_ in BREAKS]
    if len(set(ids)) != len(ids):
        bad += 1
        print("✖ duplicate break ids")
    print(f"{len(BREAKS)} breaks, {bad} bad anchor(s)")
    return 1 if bad else 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--keep-build")
    ap.add_argument("--only")
    ap.add_argument("--verbose", action="store_true")
    ap.add_argument("--dry-anchors", action="store_true")
    args = ap.parse_args()
    if args.dry_anchors:
        return check_anchors()
    work = Path(tempfile.mkdtemp(prefix="briglia-gpt62break-"))
    tree = work / "tree"
    tree.mkdir()
    for name in ("Package.swift", "Package.resolved"):
        shutil.copy2(ROOT / name, tree / name)
    shutil.copytree(ROOT / "TelegramConcierge", tree / "TelegramConcierge")
    scratch = Path(args.keep_build) if args.keep_build else work / "build"
    failures = executed = 0
    try:
        binary = build(tree, scratch)
        for control in CONTROLS:
            r = selftest(binary, work, control)
            ok = r.returncode == 0
            print(("✔" if ok else "✖") + f" positive control: the unmodified copy passes {' '.join(control[:1] + control[3:])}", flush=True)
            if not ok:
                print((r.stdout + r.stderr)[-3000:])
                return 1
        for label, prefix, edits, suite in BREAKS:
            if args.only and label.split()[0] not in args.only.split(","):
                continue
            originals = {}
            try:
                for rel, old, new in edits:
                    path = tree / rel
                    current = path.read_text()
                    if current.count(old) != 1:
                        raise RuntimeError(f"break anchor moved: {label}: {rel}: {old[:80]!r} (found {current.count(old)})")
                    originals.setdefault(rel, current)
                    path.write_text(current.replace(old, new))
                binary = build(tree, scratch)
                r = selftest(binary, work, suite)
                failed = [l for l in r.stdout.splitlines() if l.startswith("✖")]
                caught = r.returncode != 0 and any(l.startswith(f"✖ {prefix}") for l in failed)
                print(("✔" if caught else "✖") + f" {label}: '{prefix}' fails"
                      + (f" ({len(failed)} failing check(s))" if failed else ""), flush=True)
                failures += 0 if caught else 1
                executed += 1
                if not caught and args.verbose:
                    print((r.stdout + r.stderr)[-6000:])
            finally:
                for rel, text in originals.items():
                    (tree / rel).write_text(text)
    finally:
        shutil.rmtree(work, ignore_errors=True)
    print(f"\n{executed - failures}/{executed} deliberate breaks caught")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
