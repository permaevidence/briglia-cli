"""r6: subagent compaction summarizer requests (dialogue-preserving compaction, 2026-09-13).

Applied to the pinned-SOURCE lifecycle fixtures before the r5 verification. The
three subagent summarizer requests (eager retry, eager, midrun) change in exactly
three ways, rewritten at the byte level inside the JSON-encoded body so every
other byte stays exact: the intro sentence names the subagent/main-agent roles,
section 0 (dialogue with the main agent) is inserted before section 1, and the
evicted transcript is rendered as a labelled DIALOGUE block with MAIN AGENT /
SUBAGENT roles instead of USER / ASSISTANT. The pinned transcripts contain only
dialogue (no rounds, no prior summary); a transcript carrying work markers is an
error here, not silently migrated. Every other capture and every observation
passes through unchanged.
"""
import base64
import copy
import json
from pathlib import Path

RULE = json.loads((Path(__file__).parent / 'fixtures/chat-lifecycle/subagent-dialogue-compaction-r6.json').read_text())


def enc(text):
    """The bytes a JSON string fragment occupies inside the encoded body."""
    return json.dumps(text, ensure_ascii=False)[1:-1].encode()


INTRO_OLD, INTRO_NEW = enc(RULE['intro_old']), enc(RULE['intro_new'])
ANCHOR, SECTION_ZERO = enc(RULE['section_anchor']), enc(RULE['section_zero'])
MARKER, DIALOGUE_HEADER = enc(RULE['transcript_marker']), enc(RULE['dialogue_header'])
ROLES = {enc(RULE['role_old'][k]): enc(RULE['role_new'][k]) for k in RULE['role_old']}
WORK = [enc(m) for m in RULE['work_markers']]


def migrate_body(body, expected_roles):
    json.loads(body)  # a JSON request; never re-serialised
    if body.count(INTRO_OLD) != 1 or body.count(ANCHOR) != 1 or body.count(MARKER) != 1:
        raise RuntimeError('r6: pinned summarizer request does not have the expected shape')
    head, transcript = body.split(MARKER)
    if any(m in transcript for m in WORK) or DIALOGUE_HEADER in transcript:
        raise RuntimeError('r6: pinned transcript carries work or is already migrated')
    roles = sum(transcript.count(old) for old in ROLES)
    if roles != expected_roles or not any(transcript.startswith(old) for old in ROLES):
        raise RuntimeError(f'r6: expected {expected_roles} dialogue roles in the pinned transcript, found {roles}')
    for old, new in ROLES.items():
        transcript = transcript.replace(old, new)
    head = head.replace(INTRO_OLD, INTRO_NEW).replace(ANCHOR, ANCHOR + SECTION_ZERO)
    return head + MARKER + DIALOGUE_HEADER + transcript


def migrate_lifecycle(fixtures):
    result = copy.deepcopy(fixtures)
    names = [c['fixture'] for c in result['captures']]
    for name in RULE['captures']:
        if names.count(name) != 1:
            raise RuntimeError(f'r6: {name} must appear exactly once in the pinned captures')
    for item in result['captures']:
        if item['fixture'] in RULE['captures']:
            body = base64.b64decode(item['body'], validate=True)
            item['body'] = base64.b64encode(migrate_body(body, RULE['expected_role_counts'][item['fixture']])).decode()
    return result
