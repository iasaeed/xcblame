#!/usr/bin/env python3
"""Anonymize the recorded fixtures and the tests that pin their strings (fixtures/ANONYMIZATION.md).

    Scripts/anonymize-fixtures.py --private-map FILE [PATH ...]   rewrite in place (default paths: fixtures Tests)
    Scripts/anonymize-fixtures.py --check [--private-map FILE] [PATH ...]   audit only, exit 1 on a leak

The replacement side of the table is MAPPING below. The original values are private and never committed: FILE is
a JSON object {"<role>": "<original>"} kept outside the repo. Every replacement has the same UTF-8 length as the
original (the script refuses a pair whose lengths differ), so byte offsets, base64 and hex blobs keep their length.
Text hides in four encodings in these logs, and each is rewritten in its own form: plain bytes; base64 strings (JSON
blobs in SLF strings); hex strings (the task-signature slot of an SLF section: a prefix byte plus the task key); and
JSON arrays of byte values (task keys in Task Backtrace attachments). A byte array's decimal digits can change length
(`o` 111 -> `c` 99), so SLF streams are rewritten token by token with the tokenizer below: a string or JSON token
whose payload changed is re-emitted with its new length prefix (`<len>"<bytes>`, `<len>*<json>`) and every other
byte is copied verbatim, so timings and structure are untouched. The rewritten stream is re-tokenized to prove it
parses end to end. Gzip files (.xcactivitylog, .gz) are inflated, rewritten and re-gzipped (mtime 0); paths that
carry a name are renamed. Idempotent: a second run changes nothing. Python 3 standard library only.
"""
import argparse, base64, binascii, gzip, json, os, re, sys

MAPPING = json.loads(r"""
{
  "project":   {"to": "AcmeApp",           "cases": true,  "what": "the app project, scheme, target and module name"},
  "account":   {"to": "ciuser",            "cases": true,  "what": "the macOS account name (home folder, scratch paths)"},
  "email":     {"to": "acmebuilder",       "cases": true,  "what": "the e-mail local part"},
  "host":      {"to": "Build-Host-Mac-01", "cases": false, "what": "the host name"},
  "hostLocal": {"to": "BuildHostMac001",   "cases": false, "what": "the Bonjour local host name"},
  "person":    {"to": "Jamie",             "cases": true,  "what": "the owner's first name"}
}
""")

DEFAULT_PATHS = ["fixtures", "Tests"]
B64 = re.compile(rb"^(?:[A-Za-z0-9+/]{4})+(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$")
HEX = re.compile(rb"^(?:[0-9a-f]{2})+$|^(?:[0-9A-F]{2})+$")
QUOTED = re.compile(rb'(?<=")(?:[0-9a-fA-F]{16,}|[A-Za-z0-9+/]{16,}={0,2})(?=")')
BYTES = re.compile(rb"\[\s*\d{1,3}(?:\s*,\s*\d{1,3}){7,}\s*\]")
# Generic leaks the audit flags even without the private map: a home folder or a scratch path of another account,
# a personal mail address, a signing team. The allowed accounts are the synthetic ones the tests use.
GENERIC = re.compile(rb"(/Users/(?!(?:ciuser|Shared|runner|USER|alice|ann|bob|eve|joe|max|me|sam|zed|zqxuser|guide"
                     rb"|sample|o|x)\b|<)[A-Za-z][\w.-]*"
                     rb"|-Users-(?!ciuser-)[A-Za-z][\w.]*-"
                     rb"|[\w.+-]+@(?:gmail|icloud|me|hotmail|outlook|yahoo)\.com"
                     rb"|DEVELOPMENT_TEAM\s*=\s*[A-Z0-9]{10}\b)")


def pairs(private):
    out = {}
    for role, original in private.items():
        spec = MAPPING.get(role)
        if spec is None:
            sys.exit(f"unknown role {role!r} in the private map (known: {', '.join(MAPPING)})")
        to = spec["to"]
        forms = [(original, to)]
        if spec["cases"]:
            forms += [(original.lower(), to.lower()), (original.upper(), to.upper()),
                      (original.capitalize(), to.capitalize())]
        for a, b in forms:
            if len(a.encode()) != len(b.encode()):
                sys.exit(f"{role}: {len(a.encode())}-byte original vs {len(b.encode())}-byte replacement; "
                         "every pair must keep its UTF-8 length")
            if a != b and a.encode() not in out:  # the exact form wins over a case form that equals it
                out[a.encode()] = b.encode()
    return sorted(out.items(), key=lambda kv: -len(kv[0]))


def slf_tokens(data):
    """(token start, payload start, payload end, type byte) of every length-prefixed token of an SLF0 stream
    (`"` string, `*` JSON, `%` class name); raises ValueError where the stream stops parsing."""
    if data[:4] != b"SLF0":
        raise ValueError("no SLF0 header")
    i, n, out = 4, len(data), []
    while i < n:
        if data[i] == 0x2D:  # '-' null
            i += 1
            continue
        j = i
        while j < n and data[j] in b"0123456789abcdef":
            j += 1
        if j == i or j >= n:
            raise ValueError(f"bad token at {i}")
        t = data[j]
        if t in b'"*%':
            length = int(data[i:j], 10)
            if j + 1 + length > n:
                raise ValueError(f"truncated token at {i}")
            out.append((i, j + 1, j + 1 + length, t))
            i = j + 1 + length
        elif t in b"#@(^-":
            i = j + 1
        else:
            raise ValueError(f"unexpected byte {chr(t)!r} at {j}")
    return out


def replace_plain(data, table):
    for a, b in table:
        data = data.replace(a, b)
    return data


def decode(chunk):
    """('hex'|'b64', bytes) when the whole chunk is a hex or base64 encoding, else None."""
    if len(chunk) >= 8 and HEX.match(chunk):
        return "hex", binascii.unhexlify(chunk)
    if len(chunk) >= 8 and B64.match(chunk):
        try:
            return "b64", base64.b64decode(chunk, validate=True)
        except (binascii.Error, ValueError):
            return None
    return None


def encode(kind, raw, like):
    if kind == "hex":
        text = binascii.hexlify(raw)
        return text.upper() if like.isupper() else text
    return base64.b64encode(raw)


def scrub_text(data, table):
    """Plain bytes plus the JSON byte arrays and the quoted hex / base64 strings inside them."""
    def arrays(m):
        values = [int(x) for x in re.findall(rb"\d+", m.group(0))]
        if max(values) > 255:
            return m.group(0)
        new = iter(replace_plain(bytes(values), table))
        return re.sub(rb"\d+", lambda _: str(next(new)).encode(), m.group(0))

    def quoted(m):
        hit = decode(m.group(0))
        if hit is None:
            return m.group(0)
        fixed = replace_plain(hit[1], table)
        return m.group(0) if fixed == hit[1] else encode(hit[0], fixed, m.group(0))

    return replace_plain(QUOTED.sub(quoted, BYTES.sub(arrays, data)), table)


def scrub_payload(payload, table):
    hit = decode(payload)
    if hit is not None:
        fixed = scrub_text(hit[1], table)
        if fixed != hit[1]:
            return encode(hit[0], fixed, payload)
    return scrub_text(payload, table)  # also a plain word that merely looks like base64


def scrub_slf(data, table):
    out, last = [], 0
    for start, p0, p1, t in slf_tokens(data):
        if t == 0x25:  # '%' class names are Xcode's
            continue
        payload = data[p0:p1]
        new = scrub_payload(payload, table)
        if new != payload:
            out += [data[last:start], b"%d" % len(new), bytes([t]), new]
            last = p1
    out.append(data[last:])
    return b"".join(out)


def views(data, slf):
    """Every decoded form of the data the audit searches: the bytes, SLF payloads decoded from hex or base64, JSON
    byte arrays and quoted hex / base64 strings."""
    found = [data]
    if slf:
        found += [hit[1] for _, p0, p1, _ in slf_tokens(data) if (hit := decode(data[p0:p1])) is not None]
    for blob in list(found):
        found += [bytes(v) for m in BYTES.finditer(blob)
                  if max(v := [int(x) for x in re.findall(rb"\d+", m.group(0))]) <= 255]
        found += [hit[1] for m in QUOTED.finditer(blob) if (hit := decode(m.group(0))) is not None]
    return found


def leaks(data, table, slf):
    """Originals (case-insensitive, also as UTF-16) and generic leaks in every view of the data."""
    names = {a.lower() for a, _ in table}
    found = []
    for blob in views(data, slf):
        low = blob.lower()
        found += [n.decode() for n in names if n in low or n.decode().encode("utf-16-le") in low]
        found += [m.group(0).decode("utf8", "replace") for m in GENERIC.finditer(blob)]
    return found


def files(paths):
    for root in paths:
        if os.path.isfile(root):
            yield root
            continue
        for d, dirs, names in os.walk(root):
            dirs[:] = sorted(x for x in dirs if x not in {".build", ".git"})
            for name in sorted(names):
                yield os.path.join(d, name)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--private-map", help="JSON {role: original}, kept outside the repo")
    ap.add_argument("--check", action="store_true", help="audit only")
    ap.add_argument("paths", nargs="*", default=DEFAULT_PATHS)
    args = ap.parse_args()
    if not args.check and not args.private_map:
        ap.error("rewriting needs --private-map")
    table = pairs(json.load(open(args.private_map))) if args.private_map else []
    changed, renamed, problems = 0, 0, []
    for path in list(files(args.paths)):
        raw = open(path, "rb").read()
        gz = raw[:2] == b"\x1f\x8b"
        data = gzip.decompress(raw) if gz else raw
        slf = data[:4] == b"SLF0"
        if args.check:
            hits = leaks(data, table, slf) + [f"path:{n.decode()}" for n in {a.lower() for a, _ in table}
                                               if n.decode() in path.lower()]
            if hits:
                problems.append(f"{path}: {sorted(set(hits))[:8]}")
            continue
        new = scrub_slf(data, table) if slf else scrub_text(data, table)
        if new != data:
            if slf:
                slf_tokens(new)  # raises if the rewrite broke the stream
            open(path, "wb").write(gzip.compress(new, 9, mtime=0) if gz else new)
            changed += 1
        target = os.path.join(os.path.dirname(path), replace_plain(os.path.basename(path).encode(), table).decode())
        if target != path:
            os.rename(path, target)
            renamed += 1
    if args.check:
        print("\n".join(problems) or "clean")
        return 1 if problems else 0
    print(f"rewrote {changed} files, renamed {renamed}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
