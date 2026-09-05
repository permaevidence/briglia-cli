"""Signed-release verification for the Briglia Ubuntu Touch app.

Both things this app downloads and installs — the Briglia CLI, and new versions
of itself — are authenticated here before a single artifact byte is trusted:

  1. fetch the channel's signed envelope (bounded size) from its pinned
     GitHub Releases location;
  2. verify the Ed25519 signature over the domain-separated input
     ("ada-release-envelope-v1\\0" + channel + "\\0" + keyId + "\\0" + exact
     payload bytes) with the key baked into this file;
  3. validate the authenticated manifest exactly like the Briglia CLI's own
     verifier (schema, channel, SemVer, expiry, not-before, per-version
     asset URL prefix, plain asset names, sha256, size bounds);
  4. refuse rollback: the sequence must be at least the embedded minimum for
     the channel AND the highest sequence this device ever accepted for the
     same trust domain (channel + pinned artifact location), persisted under
     a cross-process lock;
  5. hand the caller the authenticated url/size/sha256 — downloads are then
     streamed with a hard byte bound and hashed on the way in.

Ed25519 provider order (plan §9.1): a system OpenSSL proven against the
RFC 8032 known-answer vectors first; otherwise the dependency-free verifier
below, a verify-only derivative of the public-domain reference
implementation with strict encoding checks, also proven against the same
vectors before its first real use. There is deliberately NO environment
override for keys, URLs or the OpenSSL path: the threat model is the network
and the distribution channel, and a caller that can set this process's
environment already runs code as this user. Tests inject fixtures by
assigning module attributes (policies, trust file) from the test process.
"""

import base64
import datetime
import fcntl
import hashlib
import json
import os
import re
import subprocess
import tempfile
import urllib.request

# Historical format name of the signed envelope (rename plan §3): the byte
# layout, channel and keyId domain-separation did not change with the
# product rename, so the name stays — renaming it would fork every signer
# and verifier for no security gain.
FORMAT = "ada-release-envelope-v1"
MAX_ENVELOPE_BYTES = 128 * 1024
MAX_PAYLOAD_BYTES = 64 * 1024
CLOCK_SKEW_ALLOWANCE = 24 * 3600          # `published` may be this far ahead
MAX_ARTIFACT_BYTES = 2 * 1024 ** 3
USER_AGENT = "briglia-ut-app"

_VERSION_RE = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+$")
_ASSET_NAME_RE = re.compile(r"^[A-Za-z0-9._-]+$")
_SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
_ISO_RE = re.compile(
    r"^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d+)?(Z|[+-]\d{2}:\d{2})$")


class ReleaseVerifyError(Exception):
    """One distinct `kind` per rejection reason (mirrors the CLI's cases)
    so tests assert on the reason and the UI can phrase it."""

    def __init__(self, kind, message):
        super().__init__(message)
        self.kind = kind


# ------------------------------------------------------------- policies

class ReleasePolicy:
    """Everything that pins a channel: which keys may sign it, where its
    envelope lives, where its artifacts must live, and the lowest sequence
    this app build is willing to install."""

    def __init__(self, channel, keys, envelope_url, artifact_url_prefix,
                 min_sequence):
        self.channel = channel
        self.keys = {key_id: bytes.fromhex(hex_key)
                     for key_id, hex_key in keys.items()}
        for key_id, raw in self.keys.items():
            if len(raw) != 32:
                raise ValueError("pinned key %s is not 32 bytes" % key_id)
        self.envelope_url = envelope_url
        self.artifact_url_prefix = artifact_url_prefix
        self.min_sequence = int(min_sequence)

    @property
    def trust_domain(self):
        # Sequences are only comparable inside one channel served from one
        # place — a staging build's floor must never block production.
        return "%s|%s" % (self.channel, self.artifact_url_prefix)


# STAMP-CLI-KEY-BEGIN — the Briglia CLI release key (briglia-cli .github/release-keys;
# same Ed25519 key as before the rename, keyId re-derived under the new channel)
CLI_KEYS = {
    "briglia-cli-release-v1-94d967bae0867c2e":
        "621031636aa2bb2edb64a58f2f72de7bc3559b08d717c79b4251f8b1e35b8a95",
}
# STAMP-CLI-KEY-END
# STAMP-APP-KEY-BEGIN — this app's own release key (.release-keys/)
APP_KEYS = {
    "briglia-ut-release-v1-7bb0163ac16c5cb3":
        "cdfa5dba857ad9276f2630c0c7028b53ea9933cc969e69f0a1cff4727ff0b7dc",
}
# STAMP-APP-KEY-END

# Lowest CLI release this app build knows how to manage (setup-api schema 2,
# the `migrate` verb, app-chat socket): a fresh app must never install an
# older signed CLI. Sequences CONTINUE across the rename (plan §3): the
# first Briglia CLI release is v0.2.0 = sequence 60, right after the last
# release of the previous identity (59), so the floor also refuses every
# pre-rename envelope by number, not only by channel name.
MIN_CLI_SEQUENCE = 60
# Lowest app release this build accepts as an update target (the first
# Briglia click is sequence 2; sequence 1 was the previous identity).
MIN_APP_SEQUENCE = 2
# THIS build's own release sequence. publish_click.sh signs exactly this
# value into the app envelope and refuses to publish anything else; a
# device records it as its floor once the update lands.
APP_RELEASE_SEQUENCE = 6

CLI_POLICY = ReleasePolicy(
    "briglia-cli", CLI_KEYS,
    "https://github.com/permaevidence/briglia-cli/releases/latest/download/manifest.sig.json",
    "https://github.com/permaevidence/briglia-cli/releases/download/v{version}/",
    MIN_CLI_SEQUENCE)
APP_POLICY = ReleasePolicy(
    "briglia-ut", APP_KEYS,
    "https://github.com/permaevidence/briglia-ut/releases/latest/download/manifest.sig.json",
    "https://github.com/permaevidence/briglia-ut/releases/download/v{version}/",
    MIN_APP_SEQUENCE)

TRUST_FILE = os.path.expanduser("~/.config/briglia-ut/release_trust.json")


# ------------------------------------------------- Ed25519, pure Python
# Verify-only derivative of the public-domain reference implementation
# (ed25519.cr.yp.to), rewritten on extended twisted-Edwards coordinates
# (RFC 8032 §5.1.4 formulas) so a verification costs milliseconds, not
# seconds, on a phone. Strictness on top of the reference: non-canonical
# point encodings (y >= p), the x=0/sign=1 encoding, and scalars s >= L
# are all rejected, and lengths are checked before any arithmetic.

_P = 2 ** 255 - 19
_L = 2 ** 252 + 27742317777372353535851937790883648493
_D = (-121665 * pow(121666, _P - 2, _P)) % _P
_I = pow(2, (_P - 1) // 4, _P)
_2D = (2 * _D) % _P


def _inv(x):
    return pow(x, _P - 2, _P)


def _xrecover(y):
    xx = (y * y - 1) * _inv(_D * y * y + 1) % _P
    x = pow(xx, (_P + 3) // 8, _P)
    if (x * x - xx) % _P != 0:
        x = x * _I % _P
    if (x * x - xx) % _P != 0:
        return None
    return x


_BY = 4 * _inv(5) % _P
_BX = _xrecover(_BY)
if _BX & 1:
    _BX = _P - _BX
_B = (_BX, _BY, 1, _BX * _BY % _P)
_IDENTITY = (0, 1, 1, 0)


def _pt_add(p, q):
    x1, y1, z1, t1 = p
    x2, y2, z2, t2 = q
    a = (y1 - x1) * (y2 - x2) % _P
    b = (y1 + x1) * (y2 + x2) % _P
    c = t1 * _2D * t2 % _P
    d = z1 * 2 * z2 % _P
    e, f, g, h = b - a, d - c, d + c, b + a
    # (X3, Y3, Z3, T3) — the tuple layout every caller reads.
    return (e * f % _P, g * h % _P, f * g % _P, e * h % _P)


def _pt_mul(scalar, point):
    result, addend = _IDENTITY, point
    while scalar:
        if scalar & 1:
            result = _pt_add(result, addend)
        addend = _pt_add(addend, addend)
        scalar >>= 1
    return result


def _pt_equal(p, q):
    x1, y1, z1, _ = p
    x2, y2, z2, _ = q
    return (x1 * z2 - x2 * z1) % _P == 0 and (y1 * z2 - y2 * z1) % _P == 0


def _pt_decode(raw):
    if len(raw) != 32:
        return None
    y = int.from_bytes(raw, "little")
    sign = y >> 255
    y &= (1 << 255) - 1
    if y >= _P:
        return None
    x = _xrecover(y)
    if x is None:
        return None
    if x == 0 and sign == 1:
        return None
    if (x & 1) != sign:
        x = _P - x
    return (x, y, 1, x * y % _P)


def ed25519_verify_python(public_key, signature, message):
    """True only for a valid signature; never raises on bad input."""
    if not (isinstance(public_key, (bytes, bytearray))
            and isinstance(signature, (bytes, bytearray))
            and isinstance(message, (bytes, bytearray))):
        return False
    if len(public_key) != 32 or len(signature) != 64:
        return False
    r = _pt_decode(bytes(signature[:32]))
    a = _pt_decode(bytes(public_key))
    if r is None or a is None:
        return False
    s = int.from_bytes(signature[32:], "little")
    if s >= _L:
        return False
    h = int.from_bytes(hashlib.sha512(
        bytes(signature[:32]) + bytes(public_key) + bytes(message)).digest(),
        "little") % _L
    return _pt_equal(_pt_mul(s, _B), _pt_add(r, _pt_mul(h, a)))


# --------------------------------------------- Ed25519 via system OpenSSL
# Fixed absolute candidates only — never PATH, never an env override: a
# verifier chosen by the environment is a verifier chosen by whoever set it.
OPENSSL_CANDIDATES = ("/usr/bin/openssl", "/usr/local/bin/openssl",
                      "/opt/homebrew/bin/openssl", "/opt/homebrew/opt/openssl@3/bin/openssl")
_SPKI_PREFIX = bytes.fromhex("302a300506032b6570032100")

# RFC 8032 §7.1 known-answer vectors: TEST 1 (empty message), TEST 2 (one
# byte 0x72). Both providers must accept these AND reject a flipped bit
# before they may verify anything real.
KNOWN_VECTORS = (
    ("d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a", "",
     "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b"),
    ("3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c", "72",
     "92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00"),
)


def ed25519_verify_openssl(openssl, public_key, signature, message):
    """Invoke openssl without a shell, fixed arguments, bounded temp files.
    Any failure (missing tool, bad exit, odd output) is simply 'not valid'."""
    if len(public_key) != 32 or len(signature) != 64:
        return False
    work = tempfile.mkdtemp(prefix="briglia-ut-verify-")
    try:
        pub = os.path.join(work, "pub.der")
        sig = os.path.join(work, "sig.bin")
        msg = os.path.join(work, "msg.bin")
        with open(pub, "wb") as f:
            f.write(_SPKI_PREFIX + bytes(public_key))
        with open(sig, "wb") as f:
            f.write(bytes(signature))
        with open(msg, "wb") as f:
            f.write(bytes(message))
        try:
            result = subprocess.run(
                [openssl, "pkeyutl", "-verify", "-rawin", "-pubin",
                 "-keyform", "DER", "-inkey", pub, "-in", msg, "-sigfile", sig],
                stdin=subprocess.DEVNULL, capture_output=True, timeout=30)
        except (OSError, subprocess.SubprocessError):
            return False
        return result.returncode == 0 and b"Verified Successfully" in result.stdout
    finally:
        for name in ("pub.der", "sig.bin", "msg.bin"):
            try:
                os.unlink(os.path.join(work, name))
            except OSError:
                pass
        try:
            os.rmdir(work)
        except OSError:
            pass


def _provider_passes_vectors(verify):
    """Known-answer gate: every vector verifies (TEST 1's empty message is
    skipped for OpenSSL, whose pkeyutl refuses empty input), and a flipped
    signature bit, a flipped message byte and a wrong key are all rejected."""
    checked = 0
    for pub_hex, msg_hex, sig_hex in KNOWN_VECTORS:
        pub, msg, sig = (bytes.fromhex(pub_hex), bytes.fromhex(msg_hex),
                         bytes.fromhex(sig_hex))
        if not msg and verify is not ed25519_verify_python:
            continue
        if not verify(pub, sig, msg):
            return False
        bad_sig = bytes([sig[0] ^ 1]) + sig[1:]
        if verify(pub, bad_sig, msg):
            return False
        if verify(pub, sig, msg + b"x"):
            return False
        wrong_pub = bytes([pub[0] ^ 1]) + pub[1:]
        if verify(wrong_pub, sig, msg):
            return False
        checked += 1
    return checked > 0


_PROVIDER = None


def provider():
    """('openssl', path) or ('python', None) — chosen once per process,
    each candidate proven by the known-answer gate before selection."""
    global _PROVIDER
    if _PROVIDER is not None:
        return _PROVIDER
    for candidate in OPENSSL_CANDIDATES:
        if not (os.path.isfile(candidate) and os.access(candidate, os.X_OK)):
            continue

        def _verify(pub, sig, msg, _c=candidate):
            return ed25519_verify_openssl(_c, pub, sig, msg)
        if _provider_passes_vectors(_verify):
            _PROVIDER = ("openssl", candidate)
            return _PROVIDER
    if _provider_passes_vectors(ed25519_verify_python):
        _PROVIDER = ("python", None)
        return _PROVIDER
    raise ReleaseVerifyError(
        "no-verifier",
        "no Ed25519 verifier passes the known-answer vectors on this device")


def ed25519_verify(public_key, signature, message):
    kind, path = provider()
    if kind == "openssl":
        return ed25519_verify_openssl(path, public_key, signature, message)
    return ed25519_verify_python(public_key, signature, message)


# ------------------------------------------------------------ envelope

def _strict_b64(value, field):
    if not isinstance(value, str):
        raise ReleaseVerifyError("malformed-envelope",
                                 "'%s' is not a string" % field)
    try:
        raw = base64.b64decode(value, validate=True)
    except (ValueError, TypeError):
        raise ReleaseVerifyError("malformed-envelope",
                                 "'%s' is not strict base64" % field)
    if base64.b64encode(raw).decode() != value:
        raise ReleaseVerifyError("malformed-envelope",
                                 "'%s' is not canonical base64" % field)
    return raw


def domain_input(channel, key_id, payload):
    return (FORMAT.encode() + b"\0" + channel.encode() + b"\0"
            + key_id.encode() + b"\0" + payload)


def parse_iso8601(value, field):
    match = _ISO_RE.match(value) if isinstance(value, str) else None
    if not match:
        raise ReleaseVerifyError("malformed-manifest",
                                 "'%s' is not an ISO 8601 timestamp" % field)
    y, mo, d, h, mi, s, tz = match.groups()
    try:
        naive = datetime.datetime(int(y), int(mo), int(d), int(h), int(mi), int(s),
                                  tzinfo=datetime.timezone.utc)
    except ValueError:
        raise ReleaseVerifyError("malformed-manifest",
                                 "'%s' is not a real date" % field)
    epoch = naive.timestamp()
    if tz != "Z":
        sign = 1 if tz[0] == "+" else -1
        epoch -= sign * (int(tz[1:3]) * 3600 + int(tz[4:6]) * 60)
    return epoch


def _is_int(value):
    return isinstance(value, int) and not isinstance(value, bool)


def validate_manifest(payload, policy, now=None):
    """Validate the AUTHENTICATED payload bytes only — verify_envelope
    checks the signature first. Returns the manifest dict."""
    now = now if now is not None else _now()
    try:
        raw = json.loads(payload.decode("utf-8"))
    except (ValueError, UnicodeDecodeError):
        raise ReleaseVerifyError("malformed-manifest",
                                 "payload is not a valid manifest JSON object")
    if not isinstance(raw, dict):
        raise ReleaseVerifyError("malformed-manifest", "payload is not an object")
    if raw.get("schema") != 1 or not _is_int(raw.get("schema")):
        raise ReleaseVerifyError("malformed-manifest",
                                 "unsupported schema %r" % (raw.get("schema"),))
    if raw.get("channel") != policy.channel:
        raise ReleaseVerifyError("wrong-channel",
                                 "manifest channel %r is not %s"
                                 % (raw.get("channel"), policy.channel))
    sequence = raw.get("sequence")
    if not _is_int(sequence) or sequence < 1:
        raise ReleaseVerifyError("malformed-manifest",
                                 "sequence %r is not a positive integer" % (sequence,))
    version = raw.get("version")
    if not isinstance(version, str) or not _VERSION_RE.match(version):
        raise ReleaseVerifyError("malformed-manifest",
                                 "version %r is not exact SemVer" % (version,))
    published = parse_iso8601(raw.get("published"), "published")
    expires = parse_iso8601(raw.get("expires"), "expires")
    if not expires > now:
        raise ReleaseVerifyError(
            "expired", "release metadata expired %s — the release channel "
            "looks stale or frozen; not updating" % raw["expires"])
    if not published <= now + CLOCK_SKEW_ALLOWANCE:
        raise ReleaseVerifyError(
            "not-yet-valid", "release metadata is published in the future "
            "(%s) — check this device's clock; not updating" % raw["published"])
    platforms = raw.get("platforms")
    if not isinstance(platforms, dict) or not platforms:
        raise ReleaseVerifyError("malformed-manifest", "manifest lists no platforms")
    allowed_prefix = policy.artifact_url_prefix.replace("{version}", version)
    out = {}
    for name, entry in platforms.items():
        if not isinstance(name, str) or not isinstance(entry, dict):
            raise ReleaseVerifyError("bad-platform", "malformed platform entry")
        url, sha, size = entry.get("url"), entry.get("sha256"), entry.get("size")
        if not isinstance(url, str) or not url.startswith(allowed_prefix):
            raise ReleaseVerifyError(
                "bad-platform", "%s: url is outside the pinned release location" % name)
        filename = url[len(allowed_prefix):]
        if not filename or not _ASSET_NAME_RE.match(filename) or ".." in filename:
            raise ReleaseVerifyError(
                "bad-platform", "%s: url filename is not a plain asset name" % name)
        if not isinstance(sha, str) or not _SHA256_RE.match(sha):
            raise ReleaseVerifyError(
                "bad-platform", "%s: sha256 is not 64 lowercase hex characters" % name)
        if not _is_int(size) or size <= 0 or size > MAX_ARTIFACT_BYTES:
            raise ReleaseVerifyError("bad-platform",
                                     "%s: size %r is out of range" % (name, size))
        out[name] = {"url": url, "sha256": sha, "size": size, "filename": filename}
    return {"schema": 1, "channel": raw["channel"], "sequence": sequence,
            "version": version, "published": published, "expires": expires,
            "platforms": out}


def verify_envelope(raw, policy, now=None):
    """Authenticate an envelope's bytes against the policy's pinned keys and
    return the validated manifest, or raise ReleaseVerifyError."""
    if not policy.keys:
        raise ReleaseVerifyError("no-keys", "no pinned keys for channel %s" % policy.channel)
    if len(raw) > MAX_ENVELOPE_BYTES:
        raise ReleaseVerifyError("too-large", "envelope is %d bytes" % len(raw))
    try:
        envelope = json.loads(raw.decode("utf-8"))
    except (ValueError, UnicodeDecodeError):
        raise ReleaseVerifyError("malformed-envelope", "not a valid envelope JSON object")
    if not isinstance(envelope, dict):
        raise ReleaseVerifyError("malformed-envelope", "envelope is not an object")
    if envelope.get("format") != FORMAT:
        raise ReleaseVerifyError("unsupported-format",
                                 "unsupported envelope format %r" % (envelope.get("format"),))
    if envelope.get("channel") != policy.channel:
        raise ReleaseVerifyError("wrong-channel",
                                 "envelope channel %r is not %s"
                                 % (envelope.get("channel"), policy.channel))
    key_id = envelope.get("keyId")
    if not isinstance(key_id, str) or key_id not in policy.keys:
        raise ReleaseVerifyError("unknown-key", "unknown signing key %r" % (key_id,))
    signature = _strict_b64(envelope.get("signature"), "signature")
    if len(signature) != 64:
        raise ReleaseVerifyError("malformed-envelope",
                                 "signature is %d bytes, not 64" % len(signature))
    payload = _strict_b64(envelope.get("payload"), "payload")
    if len(payload) > MAX_PAYLOAD_BYTES:
        raise ReleaseVerifyError("too-large", "payload is %d bytes" % len(payload))
    if not ed25519_verify(policy.keys[key_id], signature,
                          domain_input(policy.channel, key_id, payload)):
        raise ReleaseVerifyError("bad-signature", "signature does not verify")
    manifest = validate_manifest(payload, policy, now)
    manifest["keyId"] = key_id
    return manifest


# --------------------------------------------------------- trust store
# {"schema": 2, "domains": {"<channel>|<artifact prefix>": <sequence>}} —
# the same shape as the Briglia CLI's ~/.local/share/briglia/release_trust.json,
# kept in this app's own file. Every access is under flock(2) on a sibling
# lock file; a store keeps max(stored, new) so concurrent checks never
# regress the floor. Unrecognized/corrupt content is reported and treated
# as absent — the embedded minimums still apply.

def _lock_path():
    return TRUST_FILE + ".lock"


class _Locked:
    def __init__(self, exclusive):
        self.flag = fcntl.LOCK_EX if exclusive else fcntl.LOCK_SH
        self.fd = None

    def __enter__(self):
        os.makedirs(os.path.dirname(TRUST_FILE), exist_ok=True)
        self.fd = os.open(_lock_path(), os.O_RDWR | os.O_CREAT, 0o600)
        fcntl.flock(self.fd, self.flag)
        return self

    def __exit__(self, *exc):
        fcntl.flock(self.fd, fcntl.LOCK_UN)
        os.close(self.fd)
        return False


def _read_trust_unlocked():
    """(domains dict, note) — note is set when the file was unusable."""
    try:
        with open(TRUST_FILE, "rb") as f:
            raw = f.read(64 * 1024)
    except FileNotFoundError:
        return {}, None
    except OSError as exc:
        return {}, "trust file unreadable: %s" % exc
    try:
        data = json.loads(raw.decode("utf-8"))
    except (ValueError, UnicodeDecodeError):
        return {}, "trust file is corrupt — ignoring it"
    if not (isinstance(data, dict) and data.get("schema") == 2
            and isinstance(data.get("domains"), dict)):
        return {}, "trust file has an unrecognized layout — ignoring it"
    domains = {}
    for domain, seq in data["domains"].items():
        if isinstance(domain, str) and _is_int(seq) and seq >= 0:
            domains[domain] = seq
        else:
            return {}, "trust file has an unrecognized entry — ignoring it"
    return domains, None


def trust_floor(domain):
    """(highest accepted sequence for this domain or 0, note-or-None)."""
    with _Locked(exclusive=False):
        domains, note = _read_trust_unlocked()
    return domains.get(domain, 0), note


def trust_record(domain, sequence):
    """Locked read-modify-write keeping max(stored, sequence); atomic
    replace + fsync so a power cut leaves either the old or the new file."""
    if not _is_int(sequence) or sequence < 1:
        raise ValueError("sequence must be a positive integer")
    with _Locked(exclusive=True):
        domains, _ = _read_trust_unlocked()
        domains[domain] = max(domains.get(domain, 0), sequence)
        tmp = TRUST_FILE + ".tmp"
        with open(tmp, "w") as f:
            json.dump({"schema": 2, "domains": domains}, f, sort_keys=True)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, 0o600)
        os.replace(tmp, TRUST_FILE)
        try:
            dir_fd = os.open(os.path.dirname(TRUST_FILE), os.O_RDONLY)
            try:
                os.fsync(dir_fd)
            finally:
                os.close(dir_fd)
        except OSError:
            pass
        return domains[domain]


# ------------------------------------------------------ bounded network

def bounded_fetch(url, max_bytes, timeout=30):
    """Read at most max_bytes; one byte more is an error, not a truncation."""
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(request, timeout=timeout) as response:
        data = response.read(max_bytes + 1)
    if len(data) > max_bytes:
        raise ReleaseVerifyError("too-large",
                                 "response exceeds %d bytes" % max_bytes)
    return data


def download_to_file(url, dest, size, sha256, progress=None, timeout=120):
    """Stream url into dest with a hard bound of `size` bytes and a
    streaming SHA-256; returns None on success or an error string. The
    bound is the AUTHENTICATED size — Content-Length is only cosmetic."""
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    digest = hashlib.sha256()
    done = 0
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response, \
                open(dest, "wb") as sink:
            while True:
                chunk = response.read(min(256 * 1024, size + 1 - done))
                if not chunk:
                    break
                done += len(chunk)
                if done > size:
                    return ("download exceeded the authenticated size "
                            "(%d bytes) — refusing" % size)
                sink.write(chunk)
                digest.update(chunk)
                if progress:
                    progress(done, size)
            sink.flush()
            os.fsync(sink.fileno())
    except ReleaseVerifyError:
        raise
    except Exception as exc:  # network/IO — reported, never raised to QML
        return "download failed: %s" % exc
    if done != size:
        return ("download is %d bytes, authenticated size is %d — refusing"
                % (done, size))
    if digest.hexdigest() != sha256:
        return "checksum mismatch — refusing to install"
    return None


# ---------------------------------------------------------- resolution

def _now():
    return datetime.datetime.now(datetime.timezone.utc).timestamp()


def resolve_release(policy, now=None):
    """Fetch + authenticate + validate + anti-rollback for one channel.
    Returns the manifest with 'floor' and 'trust_note' added. Raises
    ReleaseVerifyError with a distinct kind for every refusal."""
    try:
        raw = bounded_fetch(policy.envelope_url, MAX_ENVELOPE_BYTES)
    except ReleaseVerifyError:
        raise
    except Exception as exc:
        raise ReleaseVerifyError("unreachable",
                                 "could not fetch release metadata: %s" % exc)
    manifest = verify_envelope(raw, policy, now)
    stored, note = trust_floor(policy.trust_domain)
    floor = max(policy.min_sequence, stored)
    if manifest["sequence"] < floor:
        raise ReleaseVerifyError(
            "rollback", "release sequence %d is older than the lowest this "
            "device accepts (%d) — refusing" % (manifest["sequence"], floor))
    manifest["floor"] = floor
    manifest["trust_note"] = note
    return manifest


def record_accepted(policy, manifest):
    """Persist the floor ONLY after the release actually installed."""
    return trust_record(policy.trust_domain, manifest["sequence"])


def provider_status():
    """For the Dashboard: which verifier this device uses, or why none."""
    try:
        kind, path = provider()
    except ReleaseVerifyError as exc:
        return {"ok": False, "provider": None, "error": str(exc)}
    return {"ok": True, "provider": kind, "path": path}
