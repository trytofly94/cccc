#!/usr/bin/env python3
"""cc-webui.py — Local web UI for editing the cccc projects.conf registry.

Self-contained, Python 3 stdlib ONLY (zero npm/pip/CDN). Serves one offline
HTML page plus a tiny JSON API for reading and writing
`~/.config/claude-control/projects.conf`.

The parser/serializer is byte-compatible with cccc's parse contract
(see cccc/cccc lines ~1107-1131, ~2202-2214). File ordering is significant: cccc
assigns dashboard letters a-z in the order project lines appear across the
whole file, so the writer preserves the exact order the UI arranged.

Server binds 127.0.0.1 by default. Pass --host 0.0.0.0 to expose it on your
network interfaces (no authentication — see the warning printed at launch). Writes
are atomic (temp file + os.replace) and a timestamped backup is taken before
overwriting.
"""

import argparse
import datetime
import json
import os
import re
import socket
import subprocess
import sys
import tempfile
import webbrowser
from http.server import BaseHTTPRequestHandler, HTTPServer
from socketserver import ThreadingMixIn, TCPServer

# Honor CC_CONFIG_DIR so a DEV/test launch is pinned to an isolated sandbox and
# can never truncate the real registry (the dev/live split's enforced half).
# cccc's cmd_webui already passes explicit --config/--settings, so this default
# only matters when cc-webui.py is launched directly with no args.
_CONFIG_ROOT = os.environ.get("CC_CONFIG_DIR") or os.path.expanduser("~/.config/claude-control")
DEFAULT_CONFIG = os.path.join(_CONFIG_ROOT, "projects.conf")
DEFAULT_SETTINGS = os.path.join(_CONFIG_ROOT, "settings.conf")

# Mirror cccc's num_to_letter reserved set (cccc/cccc: _CC_RESERVED="hnqr").
# These single letters are reserved for dashboard hotkeys and skipped.
RESERVED_LETTERS = "hnqr"

SECTION_RE = re.compile(r"^\[(.+)\]$")


# ---------------------------------------------------------------------------
# Parse / serialize (byte-compatible with cc/cc)
# ---------------------------------------------------------------------------

def parse_conf(text):
    """Parse projects.conf text into the JSON model.

    Returns {"sections": [...], "unsectioned": [...]}.
    Each section is {"name": str, "projects": [{"name", "path"}, ...]}.
    Mirrors cc's parser: skip blank lines and `#` comments; `^\\[(.+)\\]$` is a
    section header; otherwise split on the FIRST `|` and require both parts
    non-empty (else skip the line).
    """
    unsectioned = []
    sections = []
    current = None  # None => still in the unsectioned (pre-header) region

    for raw in text.split("\n"):
        line = raw
        if line == "":
            continue
        if line.startswith("#"):
            continue
        m = SECTION_RE.match(line)
        if m:
            current = {"name": m.group(1), "projects": []}
            sections.append(current)
            continue
        # Project line: split on FIRST pipe only.
        parts = line.split("|", 1)
        if len(parts) != 2:
            # No pipe at all -> cc would read name=line, path="" -> skipped.
            continue
        name, path = parts[0], parts[1]
        if name == "" or path == "":
            continue
        entry = {"name": name, "path": path}
        if current is None:
            unsectioned.append(entry)
        else:
            current["projects"].append(entry)

    return {"sections": sections, "unsectioned": unsectioned}


def serialize_conf(model):
    """Serialize the JSON model back to projects.conf text.

    Rules (see plan):
    - Unsectioned projects first (none today, but guarded), then each section.
    - `[<section>]` header, then `name|path` lines (no spaces around pipe).
    - Exactly ONE blank line between blocks (cc tolerates/skips blanks).
    - Single trailing newline.
    """
    blocks = []

    unsectioned = model.get("unsectioned") or []
    if unsectioned:
        blocks.append("\n".join(p["name"] + "|" + p["path"] for p in unsectioned))

    for section in model.get("sections") or []:
        lines = ["[" + section["name"] + "]"]
        for p in section.get("projects") or []:
            lines.append(p["name"] + "|" + p["path"])
        blocks.append("\n".join(lines))

    if not blocks:
        return ""
    return "\n\n".join(blocks) + "\n"


# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------

def _iter_projects(model):
    for p in model.get("unsectioned") or []:
        yield p
    for s in model.get("sections") or []:
        for p in s.get("projects") or []:
            yield p


def validate(model):
    """Validate the model. Raises ValueError on hard-fail.

    Returns a list of soft warnings (duplicate names, missing path on disk).
    Hard rejects (corrupt the parse contract):
      - empty name or path
      - name contains `|`, `[`, `]`, or starts with `#`
      - name contains a newline
      - section name contains `[`, `]`, or a newline
    """
    if not isinstance(model, dict):
        raise ValueError("body must be a JSON object")
    if not isinstance(model.get("sections", []), list):
        raise ValueError("'sections' must be a list")
    if not isinstance(model.get("unsectioned", []), list):
        raise ValueError("'unsectioned' must be a list")

    for s in model.get("sections") or []:
        name = s.get("name", "")
        if not isinstance(name, str) or name == "":
            raise ValueError("section name must be a non-empty string")
        if "[" in name or "]" in name:
            raise ValueError("section name may not contain '[' or ']': %r" % name)
        # A '|' in a section name can never round-trip a group-color override
        # (group-colors.conf re-partitions on the first '|' at read time -> the
        # override is silently lost every reload), so reject it outright.
        if "|" in name:
            raise ValueError("section name may not contain '|': %r" % name)
        # Reject CR/LF/NUL (not just LF): a lone '\r' would be split by Python's
        # universal-newline read into fabricated header lines while bash read -r
        # sees one garbage line -> parser divergence.
        if _NEWLINE_RE.search(name):
            raise ValueError("section name may not contain newline/CR/NUL: %r" % name)
        if not isinstance(s.get("projects", []), list):
            raise ValueError("section %r projects must be a list" % name)

    seen = {}
    warnings = []
    for p in _iter_projects(model):
        name = p.get("name", "")
        path = p.get("path", "")
        if not isinstance(name, str) or not isinstance(path, str):
            raise ValueError("project name and path must be strings")
        if name == "" or path == "":
            raise ValueError("project name and path are both required (got name=%r path=%r)" % (name, path))
        if "|" in name:
            raise ValueError("project name may not contain '|': %r" % name)
        if "[" in name or "]" in name:
            raise ValueError("project name may not contain '[' or ']': %r" % name)
        if name.startswith("#"):
            raise ValueError("project name may not start with '#': %r" % name)
        # Reject CR/LF/NUL in BOTH name and path (mirrors the settings side's
        # _NEWLINE_RE). A lone '\r' in a path passes a plain '\n' check but is
        # split by Python's universal-newline read into fabricated section /
        # project lines while bash read -r sees one garbage line.
        if _NEWLINE_RE.search(name) or _NEWLINE_RE.search(path):
            raise ValueError("project name/path may not contain newline/CR/NUL characters")
        seen[name] = seen.get(name, 0) + 1
        if not os.path.exists(os.path.expanduser(path)):
            warnings.append("path does not exist on disk: %s (%s)" % (path, name))

    for name, count in seen.items():
        if count > 1:
            warnings.append("duplicate project name appears %d times: %s" % (count, name))

    return warnings


# ---------------------------------------------------------------------------
# Atomic write + backup
# ---------------------------------------------------------------------------

def atomic_write(path, text):
    """Backup the existing file (timestamped) then write atomically.

    Returns the backup path (or None if there was no pre-existing file).
    """
    backup_path = None
    if os.path.exists(path):
        stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
        backup_path = path + ".bak-" + stamp
        with open(path, "rb") as src:
            data = src.read()
        with open(backup_path, "wb") as dst:
            dst.write(data)

    # Per-call unique temp file in the target directory. A fixed
    # ".tmp.<pid>" name is identical across every thread of the
    # ThreadingHTTPServer, so two concurrent PUTs would open+write the SAME
    # temp file and os.replace an interleaved mess. NamedTemporaryFile gives
    # each call its own name; os.replace stays atomic (same filesystem).
    dirn = os.path.dirname(path) or "."
    tmp_f = tempfile.NamedTemporaryFile(
        mode="w", encoding="utf-8", dir=dirn,
        prefix=os.path.basename(path) + ".tmp.", delete=False,
    )
    tmp = tmp_f.name
    try:
        tmp_f.write(text)
        tmp_f.flush()
        os.fsync(tmp_f.fileno())
        tmp_f.close()
        os.replace(tmp, path)
    except Exception:
        tmp_f.close()
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise
    return backup_path


# ---------------------------------------------------------------------------
# settings.conf parse / validate / serialize
#
# SYNC: The key list, defaults, and enum whitelists below are a hand-duplicate
# of cccc/cccc's load_settings() (~lines 231-341, defaults + parse contract)
# and write_setting() (~lines 353-431, the validating case-statement that is
# the authoritative whitelist). Any enum/key change in either bash function
# MUST be mirrored here AND in the HTML_PAGE <select> option lists (plan
# 15-03's Einstellungen tab). cccc/test-settings-webui.sh's drift guard reads
# cccc/cccc's case-statement literals and asserts they are a subset of
# SETTINGS_ENUMS below, so a future desync fails the test suite instead of
# silently diverging at runtime.
# ---------------------------------------------------------------------------

SETTINGS_KEYS = (
    "PERMISSION_MODE",
    "PERMISSION_MODE_FALLBACK",
    "MODEL",
    "MEMORY_LIMIT_MB",
    "CLAUDE_BIN",
    "EXTRA_FLAGS",
    "LIMIT_WATCHER",
    "AUTO_TRUST",
    "SHOW_LOGO",
    "IDLE_WATCHDOG",
)

# Documented defaults (cccc/cccc load_settings() lines ~242-266) -- applied
# whenever settings.conf is absent, or a key within a present file is absent.
SETTINGS_DEFAULTS = {
    "PERMISSION_MODE": "auto",
    "PERMISSION_MODE_FALLBACK": "default",
    "MODEL": "",
    "MEMORY_LIMIT_MB": "6144",
    "CLAUDE_BIN": "claude",
    "EXTRA_FLAGS": "",
    "LIMIT_WATCHER": "auto",
    "AUTO_TRUST": "on-add",
    "SHOW_LOGO": "true",
    "IDLE_WATCHDOG": "off",
}

# Enum allowed-value sets, exposed as an importable module constant so the
# Task-3 bash<->Python drift guard can compare them programmatically. NOTE:
# PERMISSION_MODE_FALLBACK deliberately excludes "auto" -- see cccc/cccc
# write_setting()'s comment on why the fallback is never itself "auto".
SETTINGS_ENUMS = {
    "PERMISSION_MODE": ("default", "acceptEdits", "plan", "auto", "bypassPermissions"),
    "PERMISSION_MODE_FALLBACK": ("default", "acceptEdits", "plan", "bypassPermissions"),
    "LIMIT_WATCHER": ("auto", "manual", "off"),
    "AUTO_TRUST": ("on-add", "always", "off"),
    "SHOW_LOGO": ("true", "false"),
    "IDLE_WATCHDOG": ("off", "on"),
}

# Human-readable labels for SOME enum values, shown alongside the raw value in
# the <select> options rendered below -- display only, never changes what is
# written to settings.conf (the <option value="..."> is always the bare enum
# literal cccc/cccc's write_setting() whitelist expects). Keys not present
# here (or values within them) fall back to the bare literal with no label.
SETTINGS_ENUM_LABELS = {
    "LIMIT_WATCHER": {
        "auto": "every session",
        "manual": "on request",
        "off": "disabled",
    },
    "IDLE_WATCHDOG": {
        "off": "disabled (default)",
        "on": "enabled — opt-in RAM reclaim, macOS-only",
    },
}

# CLAUDE_BIN is spliced unescaped into a shell string later sent to tmux
# send-keys (cccc/cccc write_setting() WR-03 comment) -- reject the same
# shell metacharacters the bash side rejects.
_SETTINGS_METACHAR_RE = re.compile(r"[;|&$`]")

# SEC-01 (16-CONTEXT.md D-01/D-02, closes 15-REVIEW.md CR-01): serialize_settings()
# joins every key with "\n" -- an embedded \n/\r in ANY value splices an extra
# KEY=value line into settings.conf, silently overriding a later-parsed key
# (e.g. injecting PERMISSION_MODE=bypassPermissions past the enum whitelist).
# NUL is included because, unlike bash, a Python str can genuinely hold \x00.
_NEWLINE_RE = re.compile(r"[\r\n\x00]")


def parse_settings_conf(text):
    """Parse settings.conf text into a dict containing only KNOWN keys.

    Byte-mirrors cccc/cccc load_settings()'s parse contract: skip blank
    lines and `#` comments, split on the FIRST `=` only (so free-text values
    like EXTRA_FLAGS may contain embedded `=`), trim whitespace from the key
    only, strip one optional layer of matching single/double quotes from the
    value. Unknown keys are silently ignored -- never raise -- identical to
    the bash `case "$key" in ... *) : ;; esac` fallthrough.
    """
    result = {}
    for raw in text.split("\n"):
        line = raw
        if line == "":
            continue
        if line.startswith("#"):
            continue
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        if len(value) >= 2 and value[0] == '"' and value[-1] == '"':
            value = value[1:-1]
        elif len(value) >= 2 and value[0] == "'" and value[-1] == "'":
            value = value[1:-1]
        if key in SETTINGS_KEYS:
            result[key] = value
    return result


# ---------------------------------------------------------------------------
# Per-category colors (BRAND-06)
# ---------------------------------------------------------------------------
# Stored in a SEPARATE file (group-colors.conf, "groupname|colorname" lines) so
# the safety-critical projects.conf format is never touched. Mirrors the bash
# palette in cccc/cccc: the terminal auto-assigns a hue per category by order
# and reads this file only for per-category overrides.
PROJECT_COLOR_NAMES = ["cyan", "green", "blue", "pink", "purple", "orange", "teal", "indigo"]


def group_colors_path(config_path):
    return os.path.join(os.path.dirname(os.path.abspath(config_path)), "group-colors.conf")


def read_group_colors(path):
    """Parse name|colorname lines -> {name: colorname}. Unknown color names are
    dropped. Absent/unreadable file -> {} (every project just auto-assigns)."""
    colors = {}
    try:
        with open(path, "r", encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line or line.startswith("#") or "|" not in line:
                    continue
                name, _, cname = line.partition("|")
                name, cname = name.strip(), cname.strip()
                if name and cname in PROJECT_COLOR_NAMES:
                    colors[name] = cname
    except OSError:
        pass
    return colors


def write_group_colors(path, colors, valid_names):
    """Atomically write name|colorname lines, keeping only entries whose name
    still exists (valid_names) and whose color is valid. Empty result writes an
    empty file (equivalent to 'all auto').

    Keys are stripped on the way out so write/read/prune all agree: read_group_colors
    strips at parse time, so an unstripped key written here (e.g. a section named
    with a trailing space) would key the override differently than the next GET
    reads it -> swatch shows 'auto' and the next Save prunes the override.
    """
    stripped_colors = {}
    for name, cname in colors.items():
        stripped_colors[name.strip()] = cname
    stripped_valid = {n.strip() for n in valid_names}
    lines = sorted(
        "%s|%s" % (name, stripped_colors[name])
        for name in stripped_valid
        if stripped_colors.get(name) in PROJECT_COLOR_NAMES
    )
    text = ("\n".join(lines) + "\n") if lines else ""
    atomic_write(path, text)


def read_settings(path):
    """Read settings.conf at path, filling documented defaults for any
    missing/absent key. Returns all-defaults (no error) when the file does
    not exist."""
    text = ""
    if os.path.exists(path):
        with open(path, "r", encoding="utf-8") as f:
            text = f.read()
    parsed = parse_settings_conf(text)
    model = dict(SETTINGS_DEFAULTS)
    model.update(parsed)
    # Per-key whitelist / numeric fallback, mirroring cccc/cccc load_settings():
    # bash falls back to the documented default when a file holds an
    # out-of-whitelist enum or a non-numeric MEMORY_LIMIT_MB. Without this, GET
    # would surface an invalid enum that blanks the dropdown and blocks Save,
    # and --selftest would hard-fail on a file the CLI itself accepts.
    for key, allowed in SETTINGS_ENUMS.items():
        if model.get(key) not in allowed:
            model[key] = SETTINGS_DEFAULTS[key]
    if not re.match(r"^[0-9]+$", str(model.get("MEMORY_LIMIT_MB", ""))):
        model["MEMORY_LIMIT_MB"] = SETTINGS_DEFAULTS["MEMORY_LIMIT_MB"]
    return model


def validate_settings(model):
    """Validate a settings model dict. Raises ValueError on any hard
    failure (out-of-whitelist enum, non-numeric MEMORY_LIMIT_MB, a CLAUDE_BIN
    containing shell metacharacters, or an unknown key present).

    Returns a list of soft warnings -- currently always empty (settings.conf
    has no soft-warning class today), kept for response-shape parity with
    the projects.conf validate()/API contract.
    """
    if not isinstance(model, dict):
        raise ValueError("body must be a JSON object")

    for key in model:
        if key not in SETTINGS_KEYS:
            raise ValueError("unknown settings key: %r" % (key,))

    # settings.conf is a flat KEY=value text file; every value is serialized
    # verbatim. A non-string JSON value (e.g. {"MODEL": [1, 2]}) would slip past
    # the newline/enum checks below and get written as a Python repr, so require
    # a genuine string for every key up front.
    for key, value in model.items():
        if not isinstance(value, str):
            raise ValueError("%s must be a string (got %r)" % (key, value))

    # SEC-01 (16-CONTEXT.md D-02): key-agnostic -- applies uniformly to every
    # value, not nested inside CLAUDE_BIN's metachar check or any per-key
    # branch, so it cannot be short-circuited by a more specific check below.
    for key, value in model.items():
        if isinstance(value, str) and _NEWLINE_RE.search(value):
            raise ValueError(
                "%s must not contain newline/CR/NUL characters (got %r)" % (key, value)
            )

    for key, allowed in SETTINGS_ENUMS.items():
        if key in model and model[key] not in allowed:
            raise ValueError(
                "%s must be one of %s (got %r)" % (key, "/".join(allowed), model[key])
            )

    if "MEMORY_LIMIT_MB" in model and not re.match(r"^[0-9]+$", str(model["MEMORY_LIMIT_MB"])):
        raise ValueError(
            "MEMORY_LIMIT_MB must be a non-negative integer string (got %r)"
            % (model["MEMORY_LIMIT_MB"],)
        )

    if "CLAUDE_BIN" in model and _SETTINGS_METACHAR_RE.search(str(model["CLAUDE_BIN"])):
        raise ValueError(
            "CLAUDE_BIN may not contain shell metacharacters ; | & $ ` (got %r)"
            % (model["CLAUDE_BIN"],)
        )

    return []


def serialize_settings(model):
    """Serialize a settings model to settings.conf text: every known key as
    `KEY=value`, one per line, in fixed SETTINGS_KEYS order."""
    lines = []
    for key in SETTINGS_KEYS:
        value = model.get(key, SETTINGS_DEFAULTS[key])
        lines.append("%s=%s" % (key, value))
    return "\n".join(lines) + "\n"


# ---------------------------------------------------------------------------
# Letter mapping (mirror cc's num_to_letter)
# ---------------------------------------------------------------------------

def letters_for(model):
    """Return the dashboard letters in project order, mirroring cc.

    cc's num_to_letter walks a-z skipping RESERVED_LETTERS, then z+a, z+b, ...
    for the second tier. We produce labels for every project in file order.
    """
    n = sum(1 for _ in _iter_projects(model))
    labels = []
    pool = [chr(c) for c in range(ord("a"), ord("z") + 1) if chr(c) not in RESERVED_LETTERS]
    for i in range(n):
        if i < len(pool):
            labels.append(pool[i])
        elif i < len(pool) * 2:
            labels.append("z" + pool[i - len(pool)])
        else:
            labels.append("?")
    return labels


# ---------------------------------------------------------------------------
# HTTP server
# ---------------------------------------------------------------------------

def read_config(config_path):
    if not os.path.exists(config_path):
        return {"sections": [], "unsectioned": []}
    with open(config_path, "r", encoding="utf-8") as f:
        return parse_conf(f.read())


def _host_header_hostpart(host_header):
    """Extract the bare host from a Host header value, dropping any :port.

    Handles bracketed IPv6 (`[::1]:8787` -> `::1`), `name:port`, and bare
    `name`. Returns a lowercased string ("" if the header is missing/empty).
    """
    if not host_header:
        return ""
    h = host_header.strip()
    if h.startswith("["):
        end = h.find("]")
        if end != -1:
            return h[1:end].lower()
        return h.lower()
    # A single colon means host:port (IPv4 / hostname). Bare IPv6 without
    # brackets can't carry a port in a Host header, so leaving multi-colon
    # values intact is correct.
    if h.count(":") == 1:
        h = h.split(":", 1)[0]
    return h.lower()


def build_allowed_hosts(host):
    """Allowed Host-header host-parts for a given bind address.

    Anti-DNS-rebinding allowlist: a request whose Host header does not resolve
    to one of these is rejected before any config is read or written, so a
    malicious page that rebinds its own hostname to 127.0.0.1 cannot issue a
    same-origin write to this server.

    Loopback names are always allowed. When bound to a specific LAN/Tailscale
    interface (or to all interfaces via 0.0.0.0/::), the server's own reachable
    IP(s) are added so legitimate LAN/Tailscale usage (the point of --lan) keeps
    working.
    """
    allowed = {"127.0.0.1", "localhost", "::1"}
    if host in ("0.0.0.0", "::"):
        for ip in (lan_ip(), tailscale_ip()):
            if ip:
                allowed.add(ip.lower())
    elif host and host.lower() not in allowed:
        allowed.add(host.lower())
    return allowed


def make_handler(config_path, settings_path, allowed_hosts=None):
    allowed = allowed_hosts if allowed_hosts is not None else {"127.0.0.1", "localhost", "::1"}

    class Handler(BaseHTTPRequestHandler):
        # Quiet by default.
        def log_message(self, fmt, *args):  # noqa: N802
            sys.stderr.write("[cc-webui] " + (fmt % args) + "\n")

        def _send_json(self, obj, status=200):
            body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def _host_ok(self):
            """Anti-DNS-rebinding gate. Return True if the request's Host header
            host-part is in the allowlist; otherwise send 403 (closing the
            connection so an unread body can't be mis-parsed) and return False."""
            hostpart = _host_header_hostpart(self.headers.get("Host", ""))
            if hostpart in allowed:
                return True
            self.close_connection = True
            self._send_json(
                {"ok": False, "error": "forbidden: Host header %r not allowed" % hostpart},
                status=403,
            )
            return False

        def do_OPTIONS(self):  # noqa: N802
            # No CORS: deliberately emit NO Access-Control-Allow-* headers, so a
            # cross-origin preflight can never green-light a mutating request.
            self.close_connection = True
            self._send_json({"ok": False, "error": "forbidden"}, status=403)

        def do_GET(self):  # noqa: N802
            if not self._host_ok():
                return
            if self.path == "/" or self.path == "/index.html":
                body = HTML_PAGE.encode("utf-8")
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return
            if self.path == "/api/config":
                model = read_config(config_path)
                model["path"] = config_path
                model["letters"] = letters_for(model)
                model["colors"] = read_group_colors(group_colors_path(config_path))
                model["colorNames"] = PROJECT_COLOR_NAMES
                self._send_json(model)
                return
            if self.path == "/api/settings":
                model = read_settings(settings_path)
                model["path"] = settings_path
                self._send_json(model)
                return
            self._send_json({"ok": False, "error": "not found"}, status=404)

        def do_PUT(self):  # noqa: N802
            if not self._host_ok():
                return
            if self.path == "/api/config":
                self._handle_put_config()
                return
            if self.path == "/api/settings":
                self._handle_put_settings()
                return
            self._send_json({"ok": False, "error": "not found"}, status=404)

        def _handle_put_config(self):
            try:
                length = int(self.headers.get("Content-Length", 0))
            except ValueError:
                self._send_json({"ok": False, "error": "invalid Content-Length"}, status=400)
                return
            if length < 0 or length > 1_000_000:  # projects.conf-sized payloads only
                self._send_json({"ok": False, "error": "payload too large"}, status=413)
                return
            raw = self.rfile.read(length) if length else b""
            try:
                model = json.loads(raw.decode("utf-8"))
            except Exception as exc:  # noqa: BLE001
                self._send_json({"ok": False, "error": "invalid JSON: %s" % exc}, status=400)
                return
            try:
                warnings = validate(model)
            except ValueError as exc:
                self._send_json({"ok": False, "error": str(exc)}, status=400)
                return
            # 0-byte-wipe guard (this project's documented failure mode): refuse
            # to overwrite a currently-non-empty registry with an empty project
            # set unless the client explicitly confirms via {"allowEmpty": true}.
            # Catches a Save fired before the initial GET populated the model, or
            # after a failed load left it empty.
            incoming_count = sum(1 for _ in _iter_projects(model))
            if incoming_count == 0 and not model.get("allowEmpty"):
                existing_count = sum(1 for _ in _iter_projects(read_config(config_path)))
                if existing_count > 0:
                    self._send_json({
                        "ok": False,
                        "error": "refusing to overwrite %d existing project(s) with an "
                                 "empty set; resend with allowEmpty:true to confirm"
                                 % existing_count,
                    }, status=409)
                    return
            try:
                text = serialize_conf(model)
                backup = atomic_write(config_path, text)
            except Exception as exc:  # noqa: BLE001
                self._send_json({"ok": False, "error": "write failed: %s" % exc}, status=500)
                return
            # Per-category colors ride along in the same Save but land in their
            # own file, keyed by SECTION name. Never let a color problem fail the
            # projects.conf write.
            try:
                if isinstance(model.get("colors"), dict):
                    valid = {s["name"] for s in (model.get("sections") or [])
                             if isinstance(s, dict) and s.get("name")}
                    write_group_colors(group_colors_path(config_path), model["colors"], valid)
            except Exception:  # noqa: BLE001
                pass
            self._send_json({
                "ok": True,
                "backup": backup,
                "letters": letters_for(model),
                "warnings": warnings,
            })

        def _handle_put_settings(self):
            # Write target is ALWAYS the server-fixed settings_path -- never a
            # path read from the request body (path-traversal closed by
            # construction, T-15-02).
            try:
                length = int(self.headers.get("Content-Length", 0))
            except ValueError:
                self._send_json({"ok": False, "error": "invalid Content-Length"}, status=400)
                return
            if length < 0 or length > 100_000:  # settings.conf payloads are tiny
                self._send_json({"ok": False, "error": "payload too large"}, status=413)
                return
            raw = self.rfile.read(length) if length else b""
            try:
                model = json.loads(raw.decode("utf-8"))
            except Exception as exc:  # noqa: BLE001
                self._send_json({"ok": False, "error": "invalid JSON: %s" % exc}, status=400)
                return
            try:
                warnings = validate_settings(model)
            except ValueError as exc:
                self._send_json({"ok": False, "error": str(exc)}, status=400)
                return
            # Upsert semantics (mirror bash write_setting, which edits ONE key in
            # place): merge the request over the current on-disk settings so a
            # partial PUT never reverts keys the client didn't send back to
            # hardcoded defaults. read_settings() already whitelist-sanitizes the
            # base, so a corrupt on-disk value can't leak through the merge.
            try:
                merged = read_settings(settings_path)
                merged.update(model)
                text = serialize_settings(merged)
                backup = atomic_write(settings_path, text)
            except Exception as exc:  # noqa: BLE001
                self._send_json({"ok": False, "error": "write failed: %s" % exc}, status=500)
                return
            self._send_json({
                "ok": True,
                "backup": backup,
                "warnings": warnings,
            })

    return Handler


class ThreadingHTTPServer(ThreadingMixIn, HTTPServer):
    """Handle requests in threads so concurrent clients (multiple devices over
    multiple network interfaces) don't block each other."""

    daemon_threads = True
    allow_reuse_address = True

    def server_bind(self):
        # HTTPServer.server_bind() calls socket.getfqdn(host) to resolve
        # self.server_name, which does a reverse DNS lookup. That lookup is
        # near-instant on a normal dev machine but can stall for well past a
        # minute on sandboxed/firewalled CI network environments (observed on
        # GitHub Actions macos-latest runners) -- blocking server startup
        # (and serve()'s URL= line) long before any output is printed. A
        # local settings-editor UI has no need for a resolved hostname, so
        # skip the DNS call entirely and use the literal bind host.
        TCPServer.server_bind(self)
        host, port = self.server_address[:2]
        self.server_name = host
        self.server_port = port


def pick_port(host="127.0.0.1", start=8787, span=11):
    end = start + span - 1
    for port in range(start, end + 1):
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            s.bind((host, port))
            s.close()
            return port
        except OSError:
            s.close()
            continue
    raise RuntimeError("no free port in range %d-%d" % (start, end))


def lan_ip():
    """Best-effort primary LAN IPv4. Uses a UDP socket's routing decision; no
    packets are actually sent. Returns None if it can't be determined."""
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        return ip if not ip.startswith("127.") else None
    except OSError:
        return None
    finally:
        s.close()


def tailscale_ip():
    """Best-effort Tailscale IPv4 (100.64.0.0/10 CGNAT range). Tries the
    `tailscale` CLI on PATH, then the macOS app bundle path. Returns None if
    Tailscale is not installed/running."""
    candidates = [
        ["tailscale", "ip", "-4"],
        ["/Applications/Tailscale.app/Contents/MacOS/Tailscale", "ip", "-4"],
    ]
    for cmd in candidates:
        try:
            out = subprocess.run(
                cmd, capture_output=True, text=True, timeout=3, check=False
            )
        except (OSError, subprocess.SubprocessError):
            continue
        if out.returncode == 0:
            for line in out.stdout.splitlines():
                ip = line.strip()
                if ip.startswith("100."):
                    return ip
    return None


def reachable_urls(host, port):
    """Return a list of (label, url) the server is reachable at, given its bind
    host. For 0.0.0.0 this includes localhost and any detected network
    interfaces."""
    urls = []
    if host in ("0.0.0.0", "::"):
        urls.append(("local", "http://127.0.0.1:%d" % port))
        lan = lan_ip()
        if lan:
            urls.append(("interface", "http://%s:%d" % (lan, port)))
        ts = tailscale_ip()
        if ts:
            urls.append(("interface", "http://%s:%d" % (ts, port)))
    else:
        urls.append(("local", "http://%s:%d" % (host, port)))
    return urls


def serve(config_path, settings_path, host="127.0.0.1", start_port=8787, open_browser=True):
    port = pick_port(host, start_port)
    allowed_hosts = build_allowed_hosts(host)
    handler = make_handler(config_path, settings_path, allowed_hosts)
    httpd = ThreadingHTTPServer((host, port), handler)
    urls = reachable_urls(host, port)
    primary = urls[0][1]
    # First stdout line is machine-parseable for the cc launcher.
    print("URL=%s" % primary, flush=True)
    exposed = host in ("0.0.0.0", "::")
    if exposed:
        print("", flush=True)
        # Gate the auto-open wording on the ACTUAL open_browser value: a
        # 0.0.0.0/::-bound server can still auto-open locally (e.g.
        # `cccc settings --lan`), in which case claiming "no auto-open" would
        # be false. Only the open_browser=False branch keeps that wording.
        if open_browser:
            print("  Opening the local URL automatically -- also reachable from any of these:", flush=True)
        else:
            print("  Open from any of these (no auto-open — copy the link):", flush=True)
        for label, url in urls:
            print("    %-9s %s" % (label + ":", url), flush=True)
        print("", flush=True)
        print("  ⚠  WARNING: bound to all interfaces with NO authentication.",
              flush=True)
        print("     Anyone who can reach this host:port can edit projects.conf.",
              flush=True)
        print("     Writing settings.conf is command-execution-equivalent:",
              flush=True)
        print("     CLAUDE_BIN/EXTRA_FLAGS are spliced unescaped into the",
              flush=True)
        print("     next Claude launch's tmux command.",
              flush=True)
        print("     Prefer a private/VPN interface URL; avoid untrusted networks.", flush=True)
        print("", flush=True)
        print("  If a remote device can't connect, the macOS firewall is likely",
              flush=True)
        print("     dropping incoming connections to python3. Allow it via:",
              flush=True)
        print("       System Settings > Network > Firewall  (toggle off, or allow python3)",
              flush=True)
        print("     or headless:  sudo /usr/libexec/ApplicationFirewall/socketfilterfw \\",
              flush=True)
        print("       --setglobalstate off", flush=True)
        print("", flush=True)
    print("cc webui editing: %s" % config_path, flush=True)
    print("Press Ctrl-C to stop.", flush=True)
    if open_browser:
        try:
            webbrowser.open(primary)
        except Exception:  # noqa: BLE001
            pass
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nStopped.", flush=True)
    finally:
        httpd.server_close()


# ---------------------------------------------------------------------------
# Self-test
# ---------------------------------------------------------------------------

def _models_equal(a, b):
    def norm(m):
        return {
            "unsectioned": [(p["name"], p["path"]) for p in m.get("unsectioned") or []],
            "sections": [
                (s["name"], [(p["name"], p["path"]) for p in s.get("projects") or []])
                for s in m.get("sections") or []
            ],
        }
    return norm(a) == norm(b)


def selftest(config_path, settings_path=None):
    if not os.path.exists(config_path):
        print("selftest FAIL: config not found: %s" % config_path)
        return 1
    with open(config_path, "r", encoding="utf-8") as f:
        original = f.read()

    model = parse_conf(original)
    roundtrip = parse_conf(serialize_conf(model))

    if not _models_equal(model, roundtrip):
        print("selftest FAIL: parse(serialize(parse(live))) != parse(live)")
        return 1

    # Integrity spot checks on representative tricky values from the live file.
    flat = [(p["name"], p["path"]) for p in _iter_projects(model)]
    flat_names = [n for n, _ in flat]
    flat_paths = [p for _, p in flat]

    checks = []
    # Non-ASCII names.
    checks.append(("Café-Ünïcode-Test" in flat_names, "non-ASCII name Café-Ünïcode-Test"))
    checks.append(("Sample+" in flat_names, "name with + (Sample+)"))
    # Space-containing path.
    checks.append((any("My Project" in p for p in flat_paths), "space-containing path My Project"))
    # Section path with slash.
    checks.append((any(s["name"] == "Work/Shared" for s in model["sections"]),
                   "section with slash Work/Shared"))

    for ok, label in checks:
        if not ok:
            print("selftest WARN: live file did not contain expected sample: %s" % label)

    # Ensure validate() passes on the live model (warnings allowed).
    try:
        validate(model)
    except ValueError as exc:
        print("selftest FAIL: live model fails validation: %s" % exc)
        return 1

    # settings.conf round-trip assertion -- skip gracefully if no --settings
    # path was given or the file doesn't exist yet (same tolerance the
    # projects.conf selftest above would want, but settings.conf is optional).
    if settings_path and os.path.exists(settings_path):
        s_model = read_settings(settings_path)
        s_roundtrip_text = serialize_settings(s_model)
        s_roundtrip = dict(SETTINGS_DEFAULTS)
        s_roundtrip.update(parse_settings_conf(s_roundtrip_text))
        if s_model != s_roundtrip:
            print("selftest FAIL: serialize_settings(read_settings(path)) does not round-trip")
            return 1
        try:
            validate_settings(s_model)
        except ValueError as exc:
            print("selftest FAIL: live settings model fails validation: %s" % exc)
            return 1

    print("selftest OK")
    return 0


# ---------------------------------------------------------------------------
# HTML page (Einstellungen tab added in Phase 15 Plan 03)
# ---------------------------------------------------------------------------

# SYNC: the Einstellungen tab's <select> <option> lists below are generated
# (not hand-typed) from SETTINGS_ENUMS -- the same Python constant that is
# itself a hand-duplicate of cccc/cccc's write_setting() case-statement
# whitelist (see the SYNC comment above SETTINGS_KEYS). This keeps the HTML
# option markup a single generated view of one source rather than a third
# hand-copy; cccc/test-settings-webui.sh's drift guard still backstops the
# remaining bash<->Python leg (SETTINGS_ENUMS vs write_setting()).
def _settings_enum_options_html(key):
    """Render <option> tags for a SETTINGS_ENUMS[key] allowed-value list.

    The option's value is always the bare enum literal; SETTINGS_ENUM_LABELS
    only affects the displayed text (e.g. "auto — every session"), never what
    gets written to settings.conf.
    """
    labels = SETTINGS_ENUM_LABELS.get(key, {})
    lines = []
    for v in SETTINGS_ENUMS[key]:
        label = labels.get(v)
        text = "%s — %s" % (v, label) if label else v
        lines.append('          <option value="%s">%s</option>' % (v, text))
    return "\n".join(lines)


HTML_PAGE = r"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>cc webui — projects.conf editor</title>
<style>
  :root {
    --bg: #181c23; --panel: #0e1116; --panel2: #161b22;
    --line: rgba(255,255,255,0.08); --line2: rgba(255,255,255,0.06);
    --txt: #e6edf3; --dim: #b6c2cf; --mute: #7d8896; --faint: #5a6472;
    --accent: #58a6ff; --accent-h: #8cc5ff; --ink: #04121f;
    --cyan: #56d4dd; --green: #56d364; --red: #ff6b6b; --yellow: #ffcc66; --pink: #ff9bce;
    --letter: #56d4dd; --mono: ui-monospace,'SF Mono',Menlo,Consolas,monospace;
  }
  * { box-sizing: border-box; }
  body {
    margin: 0; background: var(--bg); color: var(--txt);
    font: 13px/1.5 var(--mono);
  }
  a { color: var(--accent); } a:hover { color: var(--accent-h); }
  ::placeholder { color: var(--faint); }

  /* macOS window chrome — decorative frame */
  .chrome {
    display: flex; align-items: center; gap: 8px; padding: 10px 16px;
    background: var(--panel2); border-bottom: 1px solid var(--line2);
  }
  .chrome .dot { width: 12px; height: 12px; border-radius: 50%; }
  .chrome .r { background: #ff5f57; } .chrome .y { background: #febc2e; } .chrome .g { background: #28c840; }
  .chrome .addr {
    margin: 0 auto; background: var(--panel); border: 1px solid var(--line);
    border-radius: 6px; padding: 3px 14px; font-size: 12px; color: var(--mute);
  }
  .chrome .rpad { width: 56px; }

  header {
    padding: 12px 20px; border-bottom: 1px solid var(--line);
    display: flex; align-items: center; gap: 14px; flex-wrap: wrap;
    position: sticky; top: 0; background: var(--bg); z-index: 5;
  }
  .brand {
    background: var(--cyan); color: var(--ink); font-weight: 700;
    font-size: 13px; padding: 3px 9px; border-radius: 5px; letter-spacing: .3px;
  }
  header h1 { font-size: 15px; margin: 0; font-weight: 700; }
  header .path { color: var(--faint); font-size: 11.5px; }
  .spacer { flex: 1; }
  button {
    background: none; color: var(--dim); border: 1px solid var(--line);
    border-radius: 6px; padding: 6px 12px; cursor: pointer; font: 12.5px var(--mono);
  }
  button:hover { border-color: rgba(255,255,255,0.3); color: var(--txt); }
  button.primary { background: var(--accent); color: var(--ink); border-color: var(--accent); font-weight: 700; }
  button.primary:hover { background: var(--accent-h); border-color: var(--accent-h); color: var(--ink); }
  button.danger { color: var(--red); border-color: transparent; }
  button.danger:hover { border-color: rgba(255,107,107,0.4); }
  button.tiny { padding: 2px 7px; font-size: 12px; }
  .swatch { width: 16px; height: 16px; min-width: 16px; padding: 0; border-radius: 4px; border: 1px solid rgba(255,255,255,0.25); cursor: pointer; }
  .swatch:hover { border-color: rgba(255,255,255,0.6); }
  main { padding: 18px 20px 90px; }
  .section {
    background: var(--panel); border: 1px solid var(--line); border-radius: 8px;
    margin-bottom: 14px; overflow: hidden;
  }
  .section.dropzone-active { outline: 2px dashed var(--accent); outline-offset: -2px; }
  .sec-head {
    display: flex; align-items: center; gap: 8px; padding: 8px 14px;
    background: var(--panel2); border-bottom: 1px solid var(--line2);
  }
  .sec-name { font-weight: 700; color: var(--txt); flex: 1; font-size: 13px; text-decoration: underline; text-underline-offset: 3px; }
  .sec-name input { width: 100%; background: var(--panel); color: var(--txt);
    border: 1px solid var(--line); border-radius: 5px; padding: 4px 6px; font: 13px var(--mono); }
  .rows { padding: 4px 6px; min-height: 14px; }
  .row {
    display: flex; align-items: center; gap: 10px; padding: 7px 8px;
    border: 1px solid transparent; border-radius: 6px; cursor: grab;
  }
  .row:hover { background: rgba(255,255,255,0.03); }
  .row.dragging { opacity: .4; }
  .row.drop-before { border-top-color: var(--accent); }
  .row.drop-after { border-bottom-color: var(--accent); }
  .letter {
    display: inline-block; min-width: 22px; text-align: center;
    color: var(--ink); background: var(--letter); border-radius: 4px;
    font-weight: 700; padding: 2px 4px; font-size: 12px;
  }
  .letter.over { background: #444d5a; color: var(--dim); }
  .pname { font-weight: 700; min-width: 190px; }
  .ppath { color: var(--mute); font-size: 12px; flex: 1; word-break: break-all; }
  .ppath.missing { color: var(--yellow); }
  .grip { color: var(--faint); cursor: grab; }
  .add-proj { display: flex; gap: 6px; padding: 8px 12px 12px; flex-wrap: wrap; align-items: center; }
  .add-proj input {
    background: var(--panel); color: var(--txt); border: 1px solid var(--line);
    border-radius: 6px; padding: 5px 9px; font: 12.5px var(--mono);
  }
  .add-proj input.name { width: 170px; }
  .add-proj input.path { flex: 1; min-width: 220px; }
  /* Settings tab: label column + control on the right */
  #panelSettings .row { cursor: default; }
  #panelSettings .pname { min-width: 250px; color: var(--dim); font-weight: 400; font-size: 12.5px; }
  select, input[type=text], input[type=number] {
    background: var(--panel2); color: var(--txt); border: 1px solid var(--line);
    border-radius: 6px; padding: 5px 10px; font: 12.5px var(--mono);
  }
  input[type=checkbox] { accent-color: var(--accent); }
  #toast {
    position: fixed; bottom: 18px; left: 50%; transform: translateX(-50%);
    background: var(--panel2); border: 1px solid var(--line); border-radius: 8px;
    padding: 10px 16px; max-width: 80vw; display: none; z-index: 20;
  }
  #toast.ok { border-color: var(--green); }
  #toast.err { border-color: var(--red); }
  .note { color: var(--faint); font-size: 11.5px; line-height: 1.6; margin-top: 4px; }
  .warns {
    color: var(--yellow); font-size: 12px; line-height: 1.6; margin: 10px 8px;
    background: rgba(255,204,102,0.08); border: 1px solid rgba(255,204,102,0.35);
    border-radius: 8px; padding: 10px 14px;
  }
  .warns code { background: rgba(255,255,255,0.06); padding: 0 4px; border-radius: 3px; }
  footer { padding: 12px 20px; color: var(--faint); font-size: 11.5px; line-height: 1.6; border-top: 1px solid var(--line); }
  .tabs { display: flex; gap: 4px; background: var(--panel2); padding: 3px; border-radius: 8px; }
  .tab { background: none; border: none; color: var(--mute); padding: 6px 14px; border-radius: 6px; }
  .tab:hover { color: var(--txt); border: none; }
  .tab.active { background: var(--accent); color: var(--ink); font-weight: 700; }
</style>
</head>
<body>
<div class="chrome">
  <span class="dot r"></span><span class="dot y"></span><span class="dot g"></span>
  <span class="addr" id="addr">127.0.0.1</span>
  <span class="rpad"></span>
</div>
<script>try{document.getElementById('addr').textContent=location.host||'127.0.0.1';}catch(e){}</script>
<header>
  <span class="brand">cccc</span><h1>Settings</h1>
  <div class="tabs">
    <button type="button" class="tab active" id="tabOrg">Organisation</button>
    <button type="button" class="tab" id="tabSettings">Einstellungen</button>
  </div>
  <span class="path" id="cfgpath"></span>
  <span class="spacer"></span>
  <button id="addSection">+ Section</button>
  <button id="reload">Reload</button>
  <button class="primary" id="save" disabled title="Loading projects.conf…">Save</button>
</header>
<main>
<div id="panelOrg" class="panel">
<div id="app"></div>
</div>
<div id="panelSettings" class="panel" style="display:none">
  <div class="section">
    <div class="sec-head"><span class="sec-name">Einstellungen</span></div>
    <div class="rows">
      <div class="row">
        <span class="pname">PERMISSION_MODE</span>
        <select id="setPermissionMode">
@@ENUM_OPTIONS:PERMISSION_MODE@@
        </select>
      </div>
      <div class="row">
        <span class="pname">PERMISSION_MODE_FALLBACK</span>
        <select id="setPermissionModeFallback">
@@ENUM_OPTIONS:PERMISSION_MODE_FALLBACK@@
        </select>
      </div>
      <div class="row">
        <span class="pname">MODEL</span>
        <input type="text" id="setModel" placeholder="(default: claude's own default model)">
      </div>
      <div class="row">
        <span class="pname">MEMORY_LIMIT_MB</span>
        <input type="number" id="setMemoryLimitMb" min="0" step="1">
      </div>
      <div class="row">
        <span class="pname">CLAUDE_BIN</span>
        <input type="text" id="setClaudeBin" placeholder="claude">
      </div>
      <div class="row">
        <span class="pname">EXTRA_FLAGS</span>
        <input type="text" id="setExtraFlags" placeholder="(none)">
      </div>
      <div class="warns">
        ⚠ CLAUDE_BIN and EXTRA_FLAGS are spliced <strong>unescaped</strong> into the next
        Claude launch command — editing them here is equivalent to shell access on this
        machine. If this settings server is reachable over a network (LAN/Tailscale, not
        just 127.0.0.1), anyone who can reach it can change what the next launched session
        runs.
      </div>
      <div class="row">
        <span class="pname">LIMIT_WATCHER</span>
        <select id="setLimitWatcher">
@@ENUM_OPTIONS:LIMIT_WATCHER@@
        </select>
      </div>
      <div class="row">
        <span class="pname">AUTO_TRUST</span>
        <select id="setAutoTrust">
@@ENUM_OPTIONS:AUTO_TRUST@@
        </select>
      </div>
      <div class="row">
        <span class="pname">SHOW_LOGO</span>
        <label><input type="checkbox" id="setShowLogo"> show ASCII logo on cccc dashboard startup</label>
      </div>
      <div class="row">
        <span class="pname">IDLE_WATCHDOG</span>
        <select id="setIdleWatchdog">
@@ENUM_OPTIONS:IDLE_WATCHDOG@@
        </select>
      </div>
      <div class="warns">
        ⚠ IDLE_WATCHDOG (default off, macOS-only) reclaims RAM by sending
        <strong>SIGTERM</strong> to idle/detached sessions — never <code>kill-session</code>,
        the tmux pane survives, and Claude prints a resume line — but the correct way back
        in is <code>claude --resume &lt;session-id&gt;</code>, <strong>not</strong>
        <code>--continue</code>. If that resume assumption ever doesn't hold, in-flight work
        can be lost. Only takes effect if the daemon is already installed (see
        <code>system/README.md</code>); saving here does not install it, only enables/disables
        an existing install the next time you open the terminal dashboard.
      </div>
    </div>
  </div>
  <div class="note">
    Settings such as <code>MEMORY_LIMIT_MB</code> and <code>PERMISSION_MODE</code> only take
    effect for newly launched sessions — sessions that are already running are not affected.
  </div>
  <div class="add-proj">
    <button id="reloadSettings">Reload</button>
    <button class="primary" id="saveSettings">Save</button>
  </div>
</div>
</main>
<footer>
  Drag rows to reorder within / across sections. Order drives the a–z dashboard
  letters (reserved: h, n, q, r). <strong>Note:</strong> <code>#</code> comments
  are not preserved on save. A timestamped backup is written before each save.
</footer>
<div id="toast"></div>

<script>
"use strict";
// In-memory model: { sections:[{name, projects:[{name,path}]}], unsectioned:[...] }
var model = { sections: [], unsectioned: [], colors: {} };
var cfgPath = "";
// Per-project color palette — name→hex MUST mirror PROJ_* in cccc/cccc.
var PCOLORS = [
  { n: "cyan", h: "#56d4dd" }, { n: "green", h: "#56d364" }, { n: "blue", h: "#58a6ff" },
  { n: "pink", h: "#ff9bce" }, { n: "purple", h: "#bc8cff" }, { n: "orange", h: "#ff9f56" },
  { n: "teal", h: "#5ad1b0" }, { n: "indigo", h: "#8b9cff" }
];
function colorHexFor(name, pos) {
  var cn = (model.colors || {})[name], i;
  if (cn) { for (i = 0; i < PCOLORS.length; i++) if (PCOLORS[i].n === cn) return PCOLORS[i].h; }
  return PCOLORS[pos % PCOLORS.length].h;   // auto by category order (matches terminal)
}
function cycleColor(name) {
  var order = [null], i;                     // null = auto (no override)
  for (i = 0; i < PCOLORS.length; i++) order.push(PCOLORS[i].n);
  var cur = (model.colors || {})[name]; if (cur === undefined) cur = null;
  var idx = order.indexOf(cur); if (idx < 0) idx = 0;
  var next = order[(idx + 1) % order.length];
  model.colors = model.colors || {};
  if (next === null) delete model.colors[name]; else model.colors[name] = next;
}
var RESERVED = "hnqr";

function letterPool() {
  var pool = [];
  for (var c = 97; c <= 122; c++) {
    var ch = String.fromCharCode(c);
    if (RESERVED.indexOf(ch) === -1) pool.push(ch);
  }
  return pool;
}
function lettersFor(count) {
  var pool = letterPool(), out = [];
  for (var i = 0; i < count; i++) {
    if (i < pool.length) out.push(pool[i]);
    else if (i < pool.length * 2) out.push("z" + pool[i - pool.length]);
    else out.push("?");
  }
  return out;
}
function flatProjects() {
  var arr = [];
  (model.unsectioned || []).forEach(function (p) { arr.push(p); });
  (model.sections || []).forEach(function (s) {
    (s.projects || []).forEach(function (p) { arr.push(p); });
  });
  return arr;
}

function api(method, path, body) {
  var opts = { method: method, headers: {} };
  if (body !== undefined) {
    opts.headers["Content-Type"] = "application/json";
    opts.body = JSON.stringify(body);
  }
  return fetch(path, opts).then(function (r) {
    return r.json().then(function (j) { return { status: r.status, body: j }; });
  });
}

function toast(msg, kind) {
  var t = document.getElementById("toast");
  t.textContent = msg;
  t.className = kind || "";
  t.style.display = "block";
  clearTimeout(toast._t);
  toast._t = setTimeout(function () { t.style.display = "none"; }, kind === "err" ? 8000 : 5000);
}

// --- Drag state ----------------------------------------------------------
var drag = null; // { secIdx (or -1 for unsectioned), projIdx }

function locate(secIdx) {
  return secIdx === -1 ? model.unsectioned : model.sections[secIdx].projects;
}

function onDrop(targetSecIdx, targetProjIdx) {
  if (!drag) return;
  var src = locate(drag.secIdx);
  var item = src.splice(drag.projIdx, 1)[0];
  // Adjust target index if removing from same list before insertion point.
  if (drag.secIdx === targetSecIdx && drag.projIdx < targetProjIdx) targetProjIdx--;
  var dst = locate(targetSecIdx);
  if (targetProjIdx < 0 || targetProjIdx > dst.length) targetProjIdx = dst.length;
  dst.splice(targetProjIdx, 0, item);
  drag = null;
  render();
}

// --- Render --------------------------------------------------------------
function render() {
  document.getElementById("cfgpath").textContent = cfgPath;
  var app = document.getElementById("app");
  app.innerHTML = "";

  var letters = lettersFor(flatProjects().length);
  var letterIdx = 0;

  function renderRows(container, secIdx, projects, sectionHex) {
    projects.forEach(function (p, pi) {
      var row = document.createElement("div");
      row.className = "row";
      row.draggable = true;

      var grip = document.createElement("span");
      grip.className = "grip"; grip.textContent = "⠿"; row.appendChild(grip);

      var L = document.createElement("span");
      L.className = "letter"; L.textContent = letters[letterIdx++] || "?";
      if (sectionHex) L.style.background = sectionHex;   // whole category shares its hue
      row.appendChild(L);

      var nm = document.createElement("span");
      nm.className = "pname"; nm.textContent = p.name; row.appendChild(nm);

      var pa = document.createElement("span");
      pa.className = "ppath"; pa.textContent = p.path; row.appendChild(pa);

      var del = document.createElement("button");
      del.className = "tiny danger"; del.textContent = "✕";
      del.title = "Remove project";
      del.addEventListener("click", function (e) {
        e.stopPropagation();
        projects.splice(pi, 1); render();
      });
      row.appendChild(del);

      row.addEventListener("dragstart", function (e) {
        drag = { secIdx: secIdx, projIdx: pi };
        row.classList.add("dragging");
        e.dataTransfer.effectAllowed = "move";
        try { e.dataTransfer.setData("text/plain", p.name); } catch (x) {}
      });
      row.addEventListener("dragend", function () {
        row.classList.remove("dragging");
        Array.prototype.forEach.call(document.querySelectorAll(".drop-before,.drop-after"),
          function (el) { el.classList.remove("drop-before", "drop-after"); });
      });
      row.addEventListener("dragover", function (e) {
        e.preventDefault();
        var rect = row.getBoundingClientRect();
        var after = (e.clientY - rect.top) > rect.height / 2;
        row.classList.toggle("drop-after", after);
        row.classList.toggle("drop-before", !after);
      });
      row.addEventListener("dragleave", function () {
        row.classList.remove("drop-before", "drop-after");
      });
      row.addEventListener("drop", function (e) {
        e.preventDefault(); e.stopPropagation();
        var rect = row.getBoundingClientRect();
        var after = (e.clientY - rect.top) > rect.height / 2;
        onDrop(secIdx, after ? pi + 1 : pi);
      });

      container.appendChild(row);
    });
  }

  // Unsectioned (guard; usually empty)
  if ((model.unsectioned || []).length) {
    var u = document.createElement("div");
    u.className = "section";
    u.innerHTML = '<div class="sec-head"><span class="sec-name">(no section)</span></div>';
    var urows = document.createElement("div");
    urows.className = "rows";
    urows.addEventListener("dragover", function (e) { e.preventDefault(); });
    urows.addEventListener("drop", function (e) { e.preventDefault(); onDrop(-1, model.unsectioned.length); });
    renderRows(urows, -1, model.unsectioned);
    u.appendChild(urows);
    app.appendChild(u);
  }

  model.sections.forEach(function (sec, si) {
    var el = document.createElement("div");
    el.className = "section";

    var head = document.createElement("div");
    head.className = "sec-head";

    var nameWrap = document.createElement("span");
    nameWrap.className = "sec-name";
    var nameSpan = document.createElement("span");
    nameSpan.textContent = "[" + sec.name + "]";
    nameSpan.title = "Click to rename";
    nameSpan.style.cursor = "text";
    nameSpan.addEventListener("click", function () {
      var inp = document.createElement("input");
      inp.value = sec.name;
      function commit() {
        // Trim like addProj/addSection do (an untrimmed trailing space would
        // desync the group-color key: written unstripped, read back stripped).
        var newName = inp.value.trim();
        if (!newName) { render(); return; }   // reject empty rename, keep old name
        var old = sec.name;
        // Carry any color override across the rename so it isn't orphaned and
        // pruned on the next Save.
        if (newName !== old && model.colors && model.colors[old] !== undefined) {
          model.colors[newName] = model.colors[old];
          delete model.colors[old];
        }
        sec.name = newName;
        render();
      }
      inp.addEventListener("blur", commit);
      inp.addEventListener("keydown", function (e) {
        if (e.key === "Enter") inp.blur();
        if (e.key === "Escape") render();
      });
      nameWrap.innerHTML = ""; nameWrap.appendChild(inp); inp.focus(); inp.select();
    });
    nameWrap.appendChild(nameSpan);
    head.appendChild(nameWrap);

    // Category color swatch — one hue for the whole category (chip + title in
    // the terminal). Click cycles auto ⇢ palette; applies after Save.
    var csw = document.createElement("button");
    csw.className = "tiny swatch";
    csw.style.background = colorHexFor(sec.name, si);
    csw.title = "Kategoriefarbe — Klick: nächste (auto ⇢ Farben). Gilt nach Speichern.";
    csw.addEventListener("click", function (e) {
      e.stopPropagation();
      cycleColor(sec.name);
      render();
    });
    head.appendChild(csw);

    var up = document.createElement("button");
    up.className = "tiny"; up.textContent = "▲"; up.title = "Move section up";
    up.disabled = si === 0;
    up.addEventListener("click", function () {
      if (si === 0) return;
      var t = model.sections.splice(si, 1)[0];
      model.sections.splice(si - 1, 0, t); render();
    });
    head.appendChild(up);

    var down = document.createElement("button");
    down.className = "tiny"; down.textContent = "▼"; down.title = "Move section down";
    down.disabled = si === model.sections.length - 1;
    down.addEventListener("click", function () {
      if (si === model.sections.length - 1) return;
      var t = model.sections.splice(si, 1)[0];
      model.sections.splice(si + 1, 0, t); render();
    });
    head.appendChild(down);

    var delSec = document.createElement("button");
    delSec.className = "tiny danger"; delSec.textContent = "Delete";
    delSec.title = "Delete section (projects move to unsectioned)";
    delSec.addEventListener("click", function () {
      var n = (sec.projects || []).length;
      var msg = n
        ? "Delete section [" + sec.name + "]? Its " + n + " project(s) move to (no section)."
        : "Delete empty section [" + sec.name + "]?";
      if (!window.confirm(msg)) return;
      if (n) model.unsectioned = (model.unsectioned || []).concat(sec.projects);
      model.sections.splice(si, 1); render();
    });
    head.appendChild(delSec);

    el.appendChild(head);

    var rows = document.createElement("div");
    rows.className = "rows";
    // Section-level drop = append to end of this section.
    rows.addEventListener("dragover", function (e) {
      e.preventDefault(); el.classList.add("dropzone-active");
    });
    rows.addEventListener("dragleave", function () { el.classList.remove("dropzone-active"); });
    rows.addEventListener("drop", function (e) {
      el.classList.remove("dropzone-active");
      if (e.target === rows) { e.preventDefault(); onDrop(si, sec.projects.length); }
    });
    renderRows(rows, si, sec.projects, colorHexFor(sec.name, si));
    el.appendChild(rows);

    // Add-project form.
    var form = document.createElement("div");
    form.className = "add-proj";
    var inName = document.createElement("input");
    inName.className = "name"; inName.placeholder = "name";
    var inPath = document.createElement("input");
    inPath.className = "path"; inPath.placeholder = "/absolute/path";
    var addBtn = document.createElement("button");
    addBtn.className = "tiny"; addBtn.textContent = "+ Add project";
    function addProj() {
      var nm = inName.value.trim(), pa = inPath.value.trim();
      if (!nm || !pa) { toast("Name and path are both required.", "err"); return; }
      if (/[|\[\]]/.test(nm) || nm.charAt(0) === "#") {
        toast("Name may not contain | [ ] or start with #.", "err"); return;
      }
      sec.projects.push({ name: nm, path: pa });
      inName.value = ""; inPath.value = ""; render();
    }
    addBtn.addEventListener("click", addProj);
    inPath.addEventListener("keydown", function (e) { if (e.key === "Enter") addProj(); });
    form.appendChild(inName); form.appendChild(inPath); form.appendChild(addBtn);
    el.appendChild(form);

    app.appendChild(el);
  });
}

// --- Client-side pre-save validation ------------------------------------
function clientValidate() {
  var errs = [], names = {};
  flatProjects().forEach(function (p) {
    if (!p.name || !p.path) errs.push("empty name or path");
    if (/[|\[\]]/.test(p.name) || p.name.charAt(0) === "#")
      errs.push("invalid chars in name: " + p.name);
    names[p.name] = (names[p.name] || 0) + 1;
  });
  model.sections.forEach(function (s) {
    if (!s.name) errs.push("empty section name");
    if (/[\[\]\n]/.test(s.name)) errs.push("invalid chars in section: " + s.name);
  });
  var dups = Object.keys(names).filter(function (n) { return names[n] > 1; });
  return { errs: errs, dups: dups };
}

// --- Load / Save ---------------------------------------------------------
// Guard against the 0-byte-wipe: Save stays disabled until the first GET
// succeeds, so a Save fired before the fetch resolves (or after a failed load)
// can't serialize an empty model over a populated projects.conf.
var orgLoaded = false;
function load() {
  api("GET", "/api/config").then(function (r) {
    model = { sections: r.body.sections || [], unsectioned: r.body.unsectioned || [], colors: r.body.colors || {} };
    cfgPath = r.body.path || "";
    orgLoaded = true;
    var sb = document.getElementById("save");
    sb.disabled = false; sb.title = "";
    render();
  }).catch(function (e) { toast("Load failed: " + e, "err"); });
}

function save() {
  if (!orgLoaded) { toast("Still loading projects.conf — please wait.", "err"); return; }
  var v = clientValidate();
  if (v.errs.length) { toast("Cannot save: " + v.errs.join("; "), "err"); return; }
  if (v.dups.length && !window.confirm("Duplicate project names: " + v.dups.join(", ") + ". Save anyway?"))
    return;
  api("PUT", "/api/config", { sections: model.sections, unsectioned: model.unsectioned, colors: model.colors || {} })
    .then(function (r) {
      if (r.status === 200 && r.body.ok) {
        var msg = "Saved. Backup: " + (r.body.backup || "(none)") +
                  " — reorder takes effect next time cc renders.";
        if (r.body.warnings && r.body.warnings.length)
          msg += "  Warnings: " + r.body.warnings.join("; ");
        toast(msg, "ok");
      } else {
        toast("Save rejected: " + (r.body.error || ("HTTP " + r.status)), "err");
      }
    }).catch(function (e) { toast("Save failed: " + e, "err"); });
}

document.getElementById("save").addEventListener("click", save);
document.getElementById("reload").addEventListener("click", load);
document.getElementById("addSection").addEventListener("click", function () {
  var name = window.prompt("New section name (e.g. Work/Shared):", "");
  if (name === null) return;
  name = name.trim();
  if (!name) { toast("Section name required.", "err"); return; }
  if (/[\[\]]/.test(name)) { toast("Section name may not contain [ ].", "err"); return; }
  model.sections.push({ name: name, projects: [] });
  render();
});

// --- Einstellungen (settings.conf) tab -----------------------------------
// One entry per settings.conf key; `type` picks how the DOM widget's value
// is read/written. Enum allow-lists are NOT re-typed here -- see
// selectAllowedValues() below, which reads them straight from each
// <select>'s own <option> elements (already generated server-side from
// SETTINGS_ENUMS, plan 15-03 Task 1), so client validation can never drift
// from the rendered dropdown.
var SETTINGS_FIELDS = [
  { key: "PERMISSION_MODE", id: "setPermissionMode", type: "select" },
  { key: "PERMISSION_MODE_FALLBACK", id: "setPermissionModeFallback", type: "select" },
  { key: "MODEL", id: "setModel", type: "text" },
  { key: "MEMORY_LIMIT_MB", id: "setMemoryLimitMb", type: "number" },
  { key: "CLAUDE_BIN", id: "setClaudeBin", type: "text" },
  { key: "EXTRA_FLAGS", id: "setExtraFlags", type: "text" },
  { key: "LIMIT_WATCHER", id: "setLimitWatcher", type: "select" },
  { key: "AUTO_TRUST", id: "setAutoTrust", type: "select" },
  { key: "SHOW_LOGO", id: "setShowLogo", type: "checkbox" },
  { key: "IDLE_WATCHDOG", id: "setIdleWatchdog", type: "select" }
];

function selectAllowedValues(id) {
  var el = document.getElementById(id);
  return Array.prototype.map.call(el.options, function (o) { return o.value; });
}

function loadSettings() {
  api("GET", "/api/settings").then(function (r) {
    SETTINGS_FIELDS.forEach(function (f) {
      var el = document.getElementById(f.id);
      var v = r.body[f.key];
      if (f.type === "checkbox") {
        el.checked = v === "true";
      } else {
        // DOM `.value` property assignment only -- never innerHTML -- so a
        // free-text value (MODEL/CLAUDE_BIN/EXTRA_FLAGS) can never be
        // reflected/executed as markup (T-15-03b, mirrors the projects tab's
        // textContent-only convention above).
        el.value = v === undefined ? "" : v;
      }
    });
  }).catch(function (e) { toast("Load settings failed: " + e, "err"); });
}

function clientValidateSettings() {
  var errs = [];
  SETTINGS_FIELDS.forEach(function (f) {
    if (f.type !== "select") return;
    var el = document.getElementById(f.id);
    var allowed = selectAllowedValues(f.id);
    if (allowed.indexOf(el.value) === -1) {
      errs.push(f.key + " must be one of " + allowed.join("/") + " (got " + el.value + ")");
    }
  });
  var mem = document.getElementById("setMemoryLimitMb").value;
  if (!/^[0-9]+$/.test(mem)) {
    errs.push("MEMORY_LIMIT_MB must be a non-negative integer (got " + mem + ")");
  }
  return { errs: errs };
}

function saveSettings() {
  // Single explicit Save button -> single validate -> single PUT (D-02) --
  // no per-field autosave/change-listener anywhere in this tab.
  var v = clientValidateSettings();
  if (v.errs.length) { toast("Cannot save: " + v.errs.join("; "), "err"); return; }
  var body = {};
  SETTINGS_FIELDS.forEach(function (f) {
    var el = document.getElementById(f.id);
    body[f.key] = f.type === "checkbox" ? (el.checked ? "true" : "false") : el.value;
  });
  api("PUT", "/api/settings", body).then(function (r) {
    if (r.status === 200 && r.body.ok) {
      var msg = "Saved. Backup: " + (r.body.backup || "(none)") +
                " — applies to newly launched sessions.";
      if (r.body.warnings && r.body.warnings.length)
        msg += "  Warnings: " + r.body.warnings.join("; ");
      toast(msg, "ok");
    } else {
      toast("Save rejected: " + (r.body.error || ("HTTP " + r.status)), "err");
    }
  }).catch(function (e) { toast("Save failed: " + e, "err"); });
}

// --- Tab switch (Organisation is always the default-visible tab, D-04) ---
function activateTab(which) {
  var isOrg = which === "org";
  document.getElementById("panelOrg").style.display = isOrg ? "" : "none";
  document.getElementById("panelSettings").style.display = isOrg ? "none" : "";
  document.getElementById("tabOrg").classList.toggle("active", isOrg);
  document.getElementById("tabSettings").classList.toggle("active", !isOrg);
  // The Organisation-only toolbar buttons live in the shared header; hide
  // them while Einstellungen is active so "Save" always means "save the
  // currently visible tab's data".
  document.getElementById("addSection").style.display = isOrg ? "" : "none";
  document.getElementById("reload").style.display = isOrg ? "" : "none";
  document.getElementById("save").style.display = isOrg ? "" : "none";
}

document.getElementById("tabOrg").addEventListener("click", function () { activateTab("org"); });
document.getElementById("tabSettings").addEventListener("click", function () { activateTab("settings"); });
document.getElementById("saveSettings").addEventListener("click", saveSettings);
document.getElementById("reloadSettings").addEventListener("click", loadSettings);

load();
loadSettings();
</script>
</body>
</html>
"""

# Expand the @@ENUM_OPTIONS:KEY@@ placeholders above into real <option> markup,
# generated from SETTINGS_ENUMS (see the SYNC comment preceding
# _settings_enum_options_html()) rather than duplicated as literal HTML.
for _enum_key in ("PERMISSION_MODE", "PERMISSION_MODE_FALLBACK", "LIMIT_WATCHER", "AUTO_TRUST", "IDLE_WATCHDOG"):
    HTML_PAGE = HTML_PAGE.replace(
        "@@ENUM_OPTIONS:%s@@" % _enum_key, _settings_enum_options_html(_enum_key)
    )
del _enum_key


# ---------------------------------------------------------------------------
# CLI entrypoint
# ---------------------------------------------------------------------------

def main(argv=None):
    parser = argparse.ArgumentParser(description="Local web UI for cccc projects.conf")
    parser.add_argument("--config", default=DEFAULT_CONFIG,
                        help="path to projects.conf (default: %s)" % DEFAULT_CONFIG)
    parser.add_argument("--settings", default=DEFAULT_SETTINGS,
                        help="path to settings.conf (default: %s)" % DEFAULT_SETTINGS)
    parser.add_argument("--port", type=int, default=8787, help="preferred port (default 8787)")
    parser.add_argument("--host", default="127.0.0.1",
                        help="bind address (default 127.0.0.1; use 0.0.0.0 to "
                             "expose on your network interfaces)")
    parser.add_argument("--no-browser", action="store_true", help="do not open a browser")
    parser.add_argument("--selftest", action="store_true",
                        help="parse+serialize the config in memory and assert round-trip equality")
    args = parser.parse_args(argv)

    if args.selftest:
        return selftest(args.config, args.settings)

    serve(args.config, args.settings, host=args.host, start_port=args.port,
          open_browser=not args.no_browser)
    return 0


if __name__ == "__main__":
    sys.exit(main())
