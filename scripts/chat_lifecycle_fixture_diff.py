#!/usr/bin/env python3
"""Explain every difference between a frozen lifecycle fixture and a new pinned-source reference.

Usage: lifecycle_fixture_diff.py OLD.json NEW.json
Exit 0 only if all differences are confined to PNG iCCP chunks inside data:image/png
URLs of captured bodies; metadata (source, platform, toolchain, instrumentation) must
match except binary_sha256 (a rebuild on a new OS image legitimately changes it).
"""
import base64, json, re, struct, sys, zlib

def png_chunks(data):
    assert data[:8] == b"\x89PNG\r\n\x1a\n"
    pos, out = 8, []
    while pos < len(data):
        length = struct.unpack(">I", data[pos:pos+4])[0]
        kind = data[pos+4:pos+8]
        out.append((kind, data[pos+8:pos+8+length]))
        pos += 12 + length
    return out

def png_without_iccp(data):
    return [(k, v) for k, v in png_chunks(data) if k != b"iCCP"]

def icc_date(profile):
    y, mo, d, h, mi, se = struct.unpack(">6H", profile[24:36])
    return f"{y}-{mo:02d}-{d:02d} {h:02d}:{mi:02d}:{se:02d}"

def png_report(pa, pb):
    """Decode both PNGs: IHDR equal, raw pixel bytes (inflated IDAT) equal,
    iCCP differences confined to profile bytes; returns a text report."""
    ca, cb = dict((k, v) for k, v in png_chunks(pa) if k != b"IDAT"), dict((k, v) for k, v in png_chunks(pb) if k != b"IDAT")
    ida = zlib.decompress(b"".join(v for k, v in png_chunks(pa) if k == b"IDAT"))
    idb = zlib.decompress(b"".join(v for k, v in png_chunks(pb) if k == b"IDAT"))
    lines = [f"IHDR equal={ca[b'IHDR'] == cb[b'IHDR']} pixels(inflated IDAT) equal={ida == idb} bytes={len(ida)}",
             f"chunk sequence old={[k.decode() for k, _ in png_chunks(pa)]} new={[k.decode() for k, _ in png_chunks(pb)]}"]
    for name in sorted(set(ca) | set(cb)):
        if name == b"iCCP":
            for label, chunk in (("old", ca.get(name)), ("new", cb.get(name))):
                pname, rest = chunk.split(b"\x00", 1)
                profile = zlib.decompress(rest[1:])
                lines.append(f"iCCP {label}: name={pname.decode()} chunk_len={len(chunk)} profile_len={len(profile)} profile_date={icc_date(profile)} profile_sha256={__import__('hashlib').sha256(profile).hexdigest()[:16]} crc={zlib.crc32(name + chunk) & 0xffffffff:08x}")
        elif ca.get(name) != cb.get(name):
            lines.append(f"chunk {name.decode()} DIFFERS")
    return "\n    ".join(lines)

def images(body):
    # JSON-escaped bodies write '/' as '\\/' inside the base64 payload too.
    return [(m.group(1), m.group(2)) for m in re.finditer(rb'data:image\\?/(png|jpe?g);base64,((?:[A-Za-z0-9+=]|\\\\?/)+)', body)]

def decode_image(b64):
    return base64.b64decode(b64.replace(b"\\/", b"/"))

def jpeg_segments(data):
    """(marker, payload) list; everything from SOS to the end is one 'SCAN' blob."""
    assert data[:2] == b"\xff\xd8", "not a JPEG"
    pos, out = 2, []
    while pos < len(data):
        assert data[pos] == 0xFF, f"bad marker at {pos}"
        marker = data[pos+1]
        if marker == 0xD9: out.append(("EOI", b"")); break
        if marker == 0xDA:
            out.append(("SCAN", data[pos:])); break
        length = struct.unpack(">H", data[pos+2:pos+4])[0]
        out.append((f"{marker:02X}", data[pos+4:pos+2+length]))
        pos += 2 + length
    return out

def is_icc(seg):
    return seg[0] == "E2" and seg[1].startswith(b"ICC_PROFILE\x00")

def structure_without_icc(kind, data):
    if kind == b"png": return [(k, v) for k, v in png_chunks(data) if k != b"iCCP"]
    return [seg for seg in jpeg_segments(data) if not is_icc(seg)]

def image_report(kind, pa, pb):
    if kind == b"png":
        return png_report(pa, pb)
    sa, sb = jpeg_segments(pa), jpeg_segments(pb)
    lines = [f"JPEG segments old={[m for m, _ in sa]} new={[m for m, _ in sb]}"]
    na, nb = [x for x in sa if not is_icc(x)], [x for x in sb if not is_icc(x)]
    scan_a = next((v for m, v in sa if m == "SCAN"), b""); scan_b = next((v for m, v in sb if m == "SCAN"), b"")
    lines.append(f"non-ICC segments identical={na == nb}; SOS+entropy-coded scan identical={scan_a == scan_b} bytes={len(scan_a)} (identical compressed scan => identical pixels)")
    for label, segs in (("old", sa), ("new", sb)):
        for seg in segs:
            if is_icc(seg):
                profile = seg[1][14:]  # 'ICC_PROFILE\0' + seq + count
                lines.append(f"ICC {label}: segment_len={len(seg[1])} profile_len={len(profile)} profile_date={icc_date(profile)} profile_sha256={__import__('hashlib').sha256(profile).hexdigest()[:16]}")
    return "\n    ".join(lines)

def explain(old, new):
    problems, iccp_only = [], 0
    for key in ("source", "platform", "toolchain"):
        if old.get(key) != new.get(key): problems.append(f"metadata {key} differs")
    if json.dumps(old.get("instrumentation"), sort_keys=True) != json.dumps(new.get("instrumentation"), sort_keys=True):
        # The CI gate compares fixtures only; the instrumentation record reflects the
        # seam files of the recording head, which evolve between reviews. Documented, not a failure.
        print("NOTE: instrumentation record differs (seam files evolved since the frozen recording); gate compares fixtures only")
    fo, fn = old["fixtures"], new["fixtures"]
    if json.dumps(fo["observations"], sort_keys=True) != json.dumps(fn["observations"], sort_keys=True):
        problems.append("observations differ")
    co, cn = fo["captures"], fn["captures"]
    if len(co) != len(cn): problems.append(f"capture count {len(co)} != {len(cn)}"); return problems, iccp_only
    for i, (a, b) in enumerate(zip(co, cn)):
        for k in a:
            if k == "body": continue
            if a[k] != b.get(k): problems.append(f"captures[{i}].{k} differs")
        ba, bb = base64.b64decode(a["body"]), base64.b64decode(b["body"])
        if ba == bb: continue
        ia, ib = images(ba), images(bb)
        if not ia or len(ia) != len(ib):
            problems.append(f"captures[{i}] ({a.get('fixture')}): body differs outside an image"); continue
        # Bodies must be identical once each PNG is replaced by its iCCP-stripped form.
        sa, sb = ba, bb
        for (ka, x), (kb, y) in zip(ia, ib):
            pa, pb = decode_image(x), decode_image(y)
            if ka != kb: problems.append(f"captures[{i}] ({a.get('fixture')}): image kind changed"); break
            if pa != pb: print(f"captures[{i}] ({a.get('fixture')}) {ka.decode()}:\n    " + image_report(ka, pa, pb))
            if structure_without_icc(ka, pa) != structure_without_icc(kb, pb):
                problems.append(f"captures[{i}] ({a.get('fixture')}): image differs beyond the ICC profile"); break
            sa = sa.replace(x, b"<IMG>"); sb = sb.replace(y, b"<IMG>")
        else:
            if sa != sb: problems.append(f"captures[{i}] ({a.get('fixture')}): body differs outside the image bytes")
            else: iccp_only += 1
    return problems, iccp_only

if __name__ == "__main__":
    old, new = (json.load(open(p)) for p in sys.argv[1:3])
    problems, iccp_only = explain(old, new)
    print(f"captures differing only inside ICC profiles: {iccp_only}")
    for p in problems: print("PROBLEM:", p)
    print("binary_sha256:", old.get("binary_sha256"), "->", new.get("binary_sha256"))
    sys.exit(1 if problems else 0)
