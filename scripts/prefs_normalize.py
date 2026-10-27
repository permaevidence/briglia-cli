"""Instrumentation helper for trees that route preferences through `Prefs`
(MULTI_ASSISTANT_PLAN v5 §3.6, stage 1).

The lifecycle / compaction gates redirect every `UserDefaults.standard`
access of a source tree to a test store and COUNT them per file against the
pinned reference. Since stage 1, production code reaches preferences through
`Prefs.store` (the selected assistant's store, which for the default profile
IS `UserDefaults.standard`) and `Prefs.domains` (the named-domain API, also
`UserDefaults.standard`). For the default profile both are exactly
`UserDefaults.standard`, so mapping them back before instrumentation gives the
gates the same accesses, in the same files, as before; the accessor file
itself keeps its own literal (one reviewed new key). Pinned trees, which have
no `Prefs`, are untouched.
"""
from pathlib import Path

ACCESSOR = "TelegramConcierge/Utilities/Prefs.swift"
PAIRS = [("UserDefaults = Prefs.store", "UserDefaults = .standard"),
         ("Prefs.store", "UserDefaults.standard"),
         ("Prefs.domains", "UserDefaults.standard")]


def normalize_text(name, text):
    if name == ACCESSOR:
        return text
    for old, new in PAIRS:
        text = text.replace(old, new)
    return text


def normalize_tree(tree):
    """Rewrite a checked-out tree in place; returns the number of files changed."""
    tree = Path(tree)
    if not (tree / ACCESSOR).exists():
        return 0
    changed = 0
    for path in (tree / "TelegramConcierge").rglob("*.swift"):
        name = str(path.relative_to(tree))
        text = path.read_text()
        new = normalize_text(name, text)
        if new != text:
            path.write_text(new)
            changed += 1
    return changed


def normalize_sources(sources):
    """Same, for a {relative path: text} dictionary."""
    if ACCESSOR not in sources:
        return 0
    changed = 0
    for name in list(sources):
        if not name.endswith(".swift"):
            continue
        new = normalize_text(name, sources[name])
        if new != sources[name]:
            sources[name] = new
            changed += 1
    return changed
