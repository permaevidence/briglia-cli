#!/usr/bin/env python3
"""Machine-readable dependency inventory (security auto-update plan, Phase 0).

Writes security/dependencies.json: every dependency Briglia compiles in,
installs, downloads or relies on, with ecosystem, version/pin, source, owner
and whether the daily watch job (scripts/security_watch.py) can check it.

Generated FROM THE SOURCES so it cannot silently drift:
  * Package.resolved                         Swift packages (compiled in)
  * Resources/MCPBundles/playwright lockfile  managed Playwright npm tree (transitive)
  * AgentMailInstaller.swift                  pinned AgentMail CLI version + hashes
  * Resources/WhatsAppBridge/package.json     WhatsApp bridge npm ranges (no lockfile)
  * ToolchainService.swift installSpecs       Homebrew formulae + shared-pip packages
  * UserdataToolchain.swift packages          userdata (apt-sourced) toolchain
  * .github/workflows/*.yml                   pinned GitHub Actions + build containers
plus a short list of hand-written entries (Node, gws, OS tools, browsers,
skill-only Python packages) that each name an EVIDENCE anchor: a string that
must still exist in a named source file. If the code behind an entry changes
(the anchor disappears) generation fails, so the entry gets reviewed.

Deterministic: no timestamps, sorted output. Standard library only.

Usage:
  security_inventory.py            regenerate security/dependencies.json
  security_inventory.py --check    exit 1 if the committed file differs from a fresh generation
  security_inventory.py --stdout   print the generated JSON
"""
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "security", "dependencies.json")
SRC = "TelegramConcierge"

# owner values
PRIVATE = "briglia-private"   # lives only in Briglia's own directories; exact pin allowed
SHARED = "shared"             # a public entry point (~/.local/bin, ~/.local/node) others may use
HOST = "user-os"              # installed/updated by the user or the OS; Briglia's version is a minimum
BUILD = "build"               # used only to build/release Briglia (CI); not on users' machines


class InventoryError(Exception):
    pass


def read(rel):
    path = os.path.join(ROOT, rel)
    try:
        with open(path, encoding="utf-8") as f:
            return f.read()
    except OSError as e:
        raise InventoryError(f"cannot read {rel}: {e}")


def need(rel, needle):
    """Evidence anchor: `needle` must occur in `rel`, else the entry is stale."""
    if needle not in read(rel):
        raise InventoryError(f"evidence anchor gone: {rel!r} no longer contains {needle!r} — review the inventory entry")
    return f"{rel}: {needle}"


def entry(**kw):
    base = {
        "id": None, "group": None, "ecosystem": None, "name": None, "version": None,
        "pin": None, "pin_kind": None, "owner": None, "scope": None, "source": None,
        "watch": None, "gap": None, "exposure": None,
    }
    unknown = set(kw) - set(base)
    if unknown:
        raise InventoryError(f"unknown entry keys {sorted(unknown)}")
    base.update(kw)
    for k in ("id", "group", "name", "pin_kind", "owner", "scope", "source", "watch"):
        if not base[k]:
            raise InventoryError(f"entry {base.get('id')!r} lacks {k}")
    if base["watch"] == "gap" and not base["gap"]:
        raise InventoryError(f"entry {base['id']!r}: a coverage gap needs a reason")
    if base["watch"] in ("osv", "osv-package") and not (base["ecosystem"] and base["version"]):
        raise InventoryError(f"entry {base['id']!r}: an OSV-watched entry needs ecosystem and exact version")
    return base


def github_name(url):
    m = re.match(r"^https://(github\.com/[^/]+/[^/]+?)(?:\.git)?/?$", url)
    if not m:
        raise InventoryError(f"not a GitHub URL: {url}")
    return m.group(1)


# ---------------------------------------------------------------------------
# Generated sections
# ---------------------------------------------------------------------------

def swift_packages():
    data = json.loads(read("Package.resolved"))
    if data.get("version") != 3:
        raise InventoryError("Package.resolved: expected version 3")
    out = []
    for pin in data.get("pins", []):
        state = pin.get("state") or {}
        if pin.get("kind") != "remoteSourceControl" or not state.get("revision") or not state.get("version"):
            raise InventoryError(f"Package.resolved pin {pin.get('identity')!r} is not an exact versioned remote pin")
        out.append(entry(
            id=f"swift:{pin['identity']}", group="B2 Swift packages (compiled in)",
            ecosystem="SwiftURL", name=github_name(pin["location"]), version=state["version"],
            pin=f"revision {state['revision']}", pin_kind="exact", owner=PRIVATE, scope="compiled-in",
            source="Package.resolved", watch="osv",
            exposure="compiled into the signed binary; reaches users only through a Briglia release"))
    return out


def playwright_tree():
    rel = f"{SRC}/Resources/MCPBundles/playwright/package-lock.json"
    lock = json.loads(read(rel))
    if lock.get("lockfileVersion") != 3:
        raise InventoryError(f"{rel}: expected lockfileVersion 3")
    out = []
    for path, pkg in sorted(lock.get("packages", {}).items()):
        if path == "":
            continue
        if not path.startswith("node_modules/"):
            raise InventoryError(f"{rel}: unexpected package path {path!r}")
        name = path.split("node_modules/")[-1]
        version, integrity = pkg.get("version"), pkg.get("integrity", "")
        if not version or not integrity.startswith("sha512-"):
            raise InventoryError(f"{rel}: {name} lacks an exact version or sha512 integrity")
        out.append(entry(
            id=f"npm:playwright-tree:{name}", group="B3 managed Playwright MCP (npm tree)",
            ecosystem="npm", name=name, version=version, pin=integrity, pin_kind="exact",
            owner=PRIVATE, scope="runtime-managed", source=rel, watch="osv",
            exposure="installed with npm ci --ignore-scripts into ~/.local/share/briglia/mcp/playwright-<hash>; drives a browser on untrusted web pages"
                     + ("; PRERELEASE build" if "-" in version else "")))
    return out


def agentmail():
    rel = f"{SRC}/Services/AgentMailInstaller.swift"
    text = read(rel)
    m = re.search(r'static let pinnedVersion = "([^"]+)"', text)
    if not m:
        raise InventoryError(f"{rel}: pinnedVersion not found")
    hashes = re.findall(r'"([a-z0-9_]+-[a-z0-9_-]+)":\s+"([0-9a-f]{64})"', text)
    if len(hashes) < 4:
        raise InventoryError(f"{rel}: expected the per-target SHA-256 table")
    need(rel, "https://github.com/agentmail-to/agentmail-cli/releases/download/v")
    return [entry(
        id="github-release:agentmail-cli", group="B4 AgentMail CLI",
        ecosystem=None, name="agentmail-to/agentmail-cli", version=m.group(1),
        pin="compiled SHA-256 per target: " + ", ".join(f"{t}={h[:12]}" for t, h in sorted(hashes)),
        pin_kind="exact", owner=SHARED, scope="runtime-managed", source=rel, watch="github-repo-advisories",
        gap="no OSV ecosystem for a prebuilt GitHub-release binary; its own embedded (Rust) dependencies are not inventoried",
        exposure="binary and key-broker wrapper live in ~/.local/bin (a shared entry point); parses email from the network; updated only by `briglia agentmail upgrade`")]


def whatsapp():
    rel = f"{SRC}/Resources/WhatsAppBridge/package.json"
    pkg = json.loads(read(rel))
    lock = os.path.join(ROOT, f"{SRC}/Resources/WhatsAppBridge/package-lock.json")
    out = []
    for name, rng in sorted((pkg.get("dependencies") or {}).items()):
        out.append(entry(
            id=f"npm:whatsapp:{name}", group="U3 WhatsApp bridge (npm)",
            ecosystem="npm", name=name, version=None, pin=rng, pin_kind="range",
            owner=PRIVATE, scope="runtime-managed", source=rel, watch="gap",
            gap=("version range, no lockfile: the installed version is whatever npm resolved at deploy time"
                 if not os.path.exists(lock) else "lockfile present but not yet inventoried"),
            exposure="opt-in channel; `npm install --omit=dev` WITH install scripts into ~/.local/share/briglia/whatsapp-bridge"))
    return out


def toolchain_specs():
    rel = f"{SRC}/Services/ToolchainService.swift"
    text = read(rel)
    block = re.search(r"private static let installSpecs: \[String: InstallSpec\] = \[(.*?)\n    \]", text, re.S)
    if not block:
        raise InventoryError(f"{rel}: installSpecs table not found")
    specs = re.findall(r'InstallSpec\(manager: "(\w+)", package: "([^"]+)"', block.group(1))
    if not specs:
        raise InventoryError(f"{rel}: installSpecs table is empty")
    out, seen = [], set()
    for manager, package in specs:
        if (manager, package) in seen:
            continue
        seen.add((manager, package))
        if manager == "brewFormula":
            out.append(entry(
                id=f"brew:{package}", group="S3 Homebrew formulae Briglia installs (macOS)",
                ecosystem="Homebrew", name=package, version=None, pin="none (brew head at install time)",
                pin_kind="unpinned", owner=HOST, scope="runtime-host", source=rel, watch="gap",
                gap="version is whatever Homebrew installed; Briglia never upgrades it (report-only, plan D6)",
                exposure="parses untrusted media/PDF/documents"))
        elif manager == "pip":
            out.append(entry(
                id=f"pypi:{package}", group="U4 Python packages for skills (shared interpreter)",
                ecosystem="PyPI", name=package, version=None, pin="none (`pip install <name>`)",
                pin_kind="unpinned", owner=SHARED, scope="runtime-host", source=rel, watch="gap",
                gap="unpinned pip install into the shared python3 (--break-system-packages when needed)",
                exposure="parses untrusted documents/images" if package in ("pillow", "pymupdf", "openpyxl", "python-docx", "python-pptx") else "skill helper"))
        else:
            raise InventoryError(f"{rel}: unknown install manager {manager!r}")
    return out


def userdata_toolchain():
    rel = f"{SRC}/Services/UserdataToolchain.swift"
    text = read(rel)
    specs = re.findall(r'PackageSpec\(key: "([^"]+)",\s*apt: \[([^\]]*)\].*?optional: (true|false)\)', text, re.S)
    if not specs:
        raise InventoryError(f"{rel}: packages table not found")
    out = []
    for key, apt, optional in specs:
        for pkg in re.findall(r'"([^"]+)"', apt):
            out.append(entry(
                id=f"deb:userdata:{pkg}", group="B5 userdata toolchain (Ubuntu Touch / Debian-family prefix)",
                ecosystem="Debian/Ubuntu (device sources)", name=pkg, version=None,
                pin="the device's configured apt sources at install/upgrade time; recorded in toolchain/installed-packages.json",
                pin_kind="os-repo", owner=PRIVATE, scope="runtime-managed", source=rel, watch="gap",
                gap="version comes from the device's apt repository (unknown here); not scheduled — `briglia toolchain upgrade` only; whether the sources include the -security pocket is unverified",
                exposure=("optional; " if optional == "true" else "") + "parses untrusted media/documents; prefix is private but wrappers are published in ~/.local/bin"))
    return out


ACTION_RE = re.compile(r"uses: ([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)@([0-9a-f]{40})(?:\s*#\s*v?([0-9][^\s]*))?")
CONTAINER_RE = re.compile(r"^\s*container: (\S+)", re.M)


def workflows():
    out, seen = [], set()
    wdir = os.path.join(ROOT, ".github", "workflows")
    for fname in sorted(os.listdir(wdir)):
        if not fname.endswith(".yml"):
            continue
        rel = f".github/workflows/{fname}"
        text = read(rel)
        for name, sha, tag in ACTION_RE.findall(text):
            key = ("action", name, sha)
            if key in seen:
                continue
            seen.add(key)
            out.append(entry(
                id=f"action:{name}@{sha[:12]}", group="CI GitHub Actions (build/release only)",
                ecosystem="GitHub Actions", name=name, version=tag or None, pin=f"commit {sha}",
                pin_kind="exact", owner=BUILD, scope="build", source=rel,
                # OSV does not version-match this ecosystem (verified 2026-10-23: a version
                # query for tj-actions/changed-files 45.0.7 returns nothing although
                # GHSA-mrrh-fwg8-r2c3 affects it): query the package, evaluate ranges locally.
                watch="osv-package" if tag else "gap", gap=None if tag else "pinned by SHA without a version comment",
                exposure="runs in Briglia's CI/release pipeline"))
        for image in CONTAINER_RE.findall(text):
            key = ("container", image)
            if key in seen:
                continue
            seen.add(key)
            digest = "@sha256:" in image
            out.append(entry(
                id=f"container:{image[:40]}", group="CI build containers (build/release only)",
                ecosystem=None, name=image.split("@")[0], version=None, pin=image,
                pin_kind="digest" if digest else "tag", owner=BUILD, scope="build", source=rel, watch="gap",
                gap="Swift toolchain image: no OSV coverage; the static Swift stdlib it links ships in the Linux binary"
                    + ("" if digest else "; referenced by a MOVABLE tag"),
                exposure="builds the release binaries" if digest else "CI test runs only"))
    return out


# ---------------------------------------------------------------------------
# Hand-written entries (each with an evidence anchor in the code)
# ---------------------------------------------------------------------------

def hand_written():
    mcp = f"{SRC}/Services/MCPRegistry.swift"
    gws = f"{SRC}/Services/GoogleWorkspaceService.swift"
    pdf = f"{SRC}/Resources/BundledSkills/pdf/SKILL.md"
    get = "scripts/get-briglia.sh"
    tc = f"{SRC}/Services/ToolchainService.swift"
    upg = f"{SRC}/CLI/UpgradeService.swift"
    rows = [
        entry(id="briglia:binary", group="B1 Briglia binary + resource bundle", name="briglia",
              version=None, pin="Ed25519-signed release envelope, anti-rollback sequence floor",
              pin_kind="exact", owner=PRIVATE, scope="runtime-managed",
              source=need(upg, "manifest.sig.json"),
              watch="gap", gap="the vehicle for every pin above; its advisories are ours (no external feed)",
              exposure="updated only by `briglia upgrade` / `/upgrade` today"),
        entry(id="runtime:node", group="U1 Node.js (managed copy when no system Node >= 20)", ecosystem=None,
              name="node", version=None, pin="latest LTS from nodejs.org/dist/index.json at install time",
              pin_kind="unpinned", owner=SHARED, scope="runtime-managed",
              source=need(mcp, "https://nodejs.org/dist/index.json"), watch="node-releases",
              gap="unpinned at install, then never updated (the installed version is per machine, unknown here); ~/.local/node and its ~/.local/bin links are shared entry points; libraries bundled inside Node (OpenSSL, llhttp, zlib, …) are not inventoried separately",
              exposure="runs the Playwright MCP, the WhatsApp bridge and user MCP/LSP servers"),
        entry(id="runtime:gws", group="U2 gws (Google Workspace CLI)", ecosystem=None,
              name="googleworkspace/cli", version=None, pin="GitHub releases/latest at install time (same-origin .sha256)",
              pin_kind="unpinned", owner=SHARED, scope="runtime-managed",
              source=need(gws, "github.com/googleworkspace/cli/releases/latest/download/"), watch="github-repo-advisories",
              gap="unpinned; self-heal re-installs `latest` automatically; installed at ~/.local/bin/gws (shared); its embedded dependencies are not inventoried",
              exposure="optional email/calendar provider; parses mail and calendar data"),
        entry(id="pypi:weasyprint", group="Skill-only Python dependencies (installed by the agent, not by Briglia)",
              ecosystem="PyPI", name="weasyprint", version=None, pin="none (skill instructions: `pip install weasyprint`)",
              pin_kind="unpinned", owner=HOST, scope="runtime-host", source=need(pdf, "python3 -m pip install weasyprint"),
              watch="gap", gap="installed on demand by the agent following skill text; native pango/cairo closure is OS-owned",
              exposure="renders agent-generated HTML to PDF"),
        entry(id="host:pdf-renderer-browser", group="S5 Browsers (Playwright target, PDF rendering)", ecosystem=None,
              name="Google Chrome / Chromium / Edge", version=None, pin="system install", pin_kind="unpinned",
              owner=HOST, scope="runtime-host", source=need(f"{SRC}/Resources/BundledSkills/pdf/render_pdf.py", "chrom"),
              watch="gap", gap="self-updates on macOS; on Linux only via the vendor's apt repo (not a distro security pocket)",
              exposure="loads untrusted web pages (Browse subagent) and renders generated HTML"),
        entry(id="host:libcurl-libxml2", group="S1 Linux system libraries for the static-Swift binary", ecosystem=None,
              name="libcurl4, libxml2", version=None, pin="distribution package", pin_kind="os-repo",
              owner=HOST, scope="runtime-host", source=need(get, "libcurl"), watch="gap",
              gap="OS-owned; covered by the distribution's security updates (doctor reports pending ones)",
              exposure="every HTTPS request Briglia makes on Linux"),
        entry(id="host:linux-media-tools", group="S2 Linux media tools installed system-wide", ecosystem=None,
              name="poppler-utils, imagemagick, ffmpeg, pandoc, libreoffice", version=None,
              pin="`sudo <apt-get|dnf|pacman> install`", pin_kind="os-repo", owner=HOST, scope="runtime-host",
              source=need(tc, "installLinuxPackage"), watch="gap",
              gap="OS-owned; covered by the distribution's security updates (doctor reports pending ones)",
              exposure="parses untrusted media/PDF/documents"),
        entry(id="host:libreoffice-cask", group="S3 Homebrew formulae Briglia installs (macOS)", ecosystem="Homebrew",
              name="libreoffice (cask)", version=None, pin="brew cask at install time", pin_kind="unpinned",
              owner=HOST, scope="runtime-host", source=need(tc, "libreoffice"), watch="gap",
              gap="cask; Briglia never upgrades it (report-only)", exposure="parses untrusted Office documents"),
        entry(id="host:os-tools", group="S4 OS tools Briglia invokes", ecosystem=None,
              name="python3, git, rg, sudo, zip, unzip, tar, systemctl/loginctl, caffeinate/systemd-inhibit",
              version=None, pin="OS / Xcode CLT / Homebrew", pin_kind="os-repo", owner=HOST, scope="runtime-host",
              source=need(f"{SRC}/Services/MindExportService.swift", "unzip"), watch="gap",
              gap="OS-owned; zip/unzip/tar handle imported archives", exposure="archives, VCS, shell"),
        entry(id="host:ubuntu-touch-rootfs", group="S6 Ubuntu Touch root filesystem", ecosystem=None,
              name="UBports system image", version=None, pin="UBports OTA", pin_kind="os-repo", owner=HOST,
              scope="runtime-host", source=need(f"{SRC}/CLI/ServiceCommand.swift", "isUbuntuTouch"), watch="gap",
              gap="read-only rootfs; updated only by UBports OTA", exposure="everything on the phone"),
        entry(id="user:mcp-lsp-servers", group="S7 user-configured MCP/LSP servers and agent-installed code",
              ecosystem=None, name="mcp.json / LSP commands", version=None, pin="user's choice (often @latest)",
              pin_kind="unpinned", owner=HOST, scope="runtime-host",
              source=need(f"{SRC}/Services/MCPRegistry.swift", "mcp.json"), watch="gap",
              gap="user-managed; no finite Briglia pin list exists", exposure="arbitrary"),
    ]
    return rows


def generate():
    comps = (swift_packages() + playwright_tree() + agentmail() + whatsapp() + toolchain_specs()
             + userdata_toolchain() + workflows() + hand_written())
    ids = [c["id"] for c in comps]
    dup = sorted({i for i in ids if ids.count(i) > 1})
    if dup:
        raise InventoryError(f"duplicate ids: {dup}")
    comps.sort(key=lambda c: (c["group"], c["id"]))
    return {
        "schema": 1,
        "generated_by": "scripts/security_inventory.py (do not edit by hand; run it and commit the result)",
        "owners": {
            PRIVATE: "only in Briglia's own directories; an exact pin is allowed",
            SHARED: "a public entry point (~/.local/bin, ~/.local/node, shared python3) others may use; Briglia's version is a minimum",
            HOST: "installed/updated by the user or the OS; Briglia never downgrades or replaces it",
            BUILD: "used only in Briglia's CI/release pipeline",
        },
        "watch": {
            "osv": "exact version checked daily against OSV (scripts/security_watch.py)",
            "osv-package": "all OSV advisories of the package fetched daily; affected ranges evaluated by the watch itself (OSV does not version-match this ecosystem)",
            "github-repo-advisories": "checked daily against the upstream repository's published GitHub security advisories",
            "node-releases": "newest Node.js security release per supported LTS line tracked daily (nodejs.org/dist/index.json); the per-machine installed version is not known here",
            "gap": "cannot be checked automatically today; listed in the watch job's coverage-gap issue",
        },
        "components": comps,
    }


def render(doc):
    return json.dumps(doc, indent=1, sort_keys=True, ensure_ascii=False) + "\n"


def main(argv):
    try:
        text = render(generate())
    except InventoryError as e:
        print(f"✖ inventory: {e}", file=sys.stderr)
        return 1
    if "--stdout" in argv:
        sys.stdout.write(text)
        return 0
    if "--check" in argv:
        try:
            with open(OUT, encoding="utf-8") as f:
                committed = f.read()
        except OSError:
            print(f"✖ {os.path.relpath(OUT, ROOT)} missing — run scripts/security_inventory.py and commit it", file=sys.stderr)
            return 1
        if committed != text:
            print(f"✖ {os.path.relpath(OUT, ROOT)} is stale — run scripts/security_inventory.py and commit the result", file=sys.stderr)
            return 1
        print(f"✔ dependency inventory current ({len(json.loads(text)['components'])} components)")
        return 0
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w", encoding="utf-8") as f:
        f.write(text)
    print(f"wrote {os.path.relpath(OUT, ROOT)} ({len(json.loads(text)['components'])} components)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
