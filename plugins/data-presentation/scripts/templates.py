"""The template store and its save gates.

A template is refused on shape it does not recognise rather than on shapes known to be
bad: an unknown key a hand edit adds is behaviour nobody reviewed.
"""

import hashlib
import json
import os
import re
import shlex
import tempfile
from urllib.parse import parse_qsl, urlsplit

import constants
from validate import FORMS

NAME_PATTERN = r"^[a-z0-9][a-z0-9-]{0,23}$"
SOURCE_KINDS = ("tool", "command", "file")
ADAPTERS = ("amplitude-segmentation", "paths", "identity")
KINDS = ("invalid", "exists", "missing", "secret", "absolute_dates")

TOP_KEYS = ("name", "purpose", "caveats", "blocks", "created_at")
TOP_REQUIRED = ("name", "purpose", "blocks")
BLOCK_KEYS = ("source", "mapping", "present", "fingerprint")
SOURCE_KEYS = {"tool": ("kind", "tool", "args"), "command": ("kind", "command"), "file": ("kind", "path")}
PRESENT_KEYS = ("title", "units", "type", "width")
SUBDIRS = ("templates", "runs", "out")

SAFE_HEADERS = ("accept", "content-type", "user-agent")
AUTH_SCHEMES = ("bearer", "basic", "token", "bot")
CREDENTIAL_WORDS = ("token", "key", "secret", "pass", "auth")
# Matched as substrings, so --key-file and a "keyword" argument are refused too; the
# false positive is the price of not listing every credential spelling.
CREDENTIAL_NAMES = CREDENTIAL_WORDS + ("header", "cookie")
# KTD10: the shortest run of mixed letters and digits treated as a credential. Chart ids
# (8 characters) and ISO dates sit well under it; a 32-hex API key sits well over.
TOKEN_MIN = 20

EPOCH_MIN = 946684800
EPOCH_MAX = 4102444800

_ENV_REF = re.compile(r"\$(?:\{([A-Z_][A-Z0-9_]*)\}|([A-Z_][A-Z0-9_]*))")
_ALNUM_RUN = re.compile(r"[A-Za-z0-9]+")
_URL_TAIL = re.compile(r"://\S*")
_ASSIGNMENT = re.compile(r"([A-Za-z_][A-Za-z0-9_]*)=(.*)", re.S)
_HEADER_WORD = re.compile(r"([A-Za-z][A-Za-z0-9_-]*):(.*)", re.S)
_PRINTABLE_OPTION = re.compile(r"--[a-z]+(?:-[a-z]+)*")
_ISO_DATE = re.compile(r"\d{4}-\d{2}-\d{2}(?:[T ]\d{2}:\d{2}(?::\d{2}(?:\.\d+)?)?(?:Z|[+-]\d{2}:?\d{2})?)?")

# Short curl options that take a value. A cluster stops at the first of these, so the
# f in -H"Accept: fake/f" is part of the header, not the -f flag.
_CURL_SHORT_WITH_VALUE = set("HuodXAebcTFKwxErmyYzCDPQtU")
_CURL_SHORT_CREDENTIAL = {"H": "header", "u": "user", "U": "user", "b": "cookie"}
_CURL_LONG_CREDENTIAL = {
    "--header": "header",
    "--proxy-header": "header",
    "--user": "user",
    "--proxy-user": "user",
    "--oauth2-bearer": "bearer",
}
_CURL_LONG_WITH_VALUE = {
    "--data", "--data-raw", "--data-binary", "--data-urlencode", "--output", "--request",
    "--url", "--form", "--user-agent", "--referer", "--cookie", "--max-time",
    "--connect-timeout", "--retry", "--write-out", "--config", "--json",
}
_CURL_FAIL = ("--fail", "--fail-with-body")


class TemplateError(Exception):
    def __init__(self, kind, message, paths=None):
        if kind not in KINDS:
            raise ValueError(f"unknown TemplateError kind {kind!r}")
        super().__init__(message)
        self.kind = kind
        self.paths = list(paths) if paths else []


def root(home=None):
    return os.path.join(home or os.path.expanduser("~"), ".claude", "data-presentation")


def check_name(name):
    if not isinstance(name, str) or not re.fullmatch(NAME_PATTERN, name):
        raise TemplateError(
            "invalid",
            f"{name!r} is not a usable report name. A name is 1 to 24 characters of lowercase "
            "letters, digits and hyphens, and starts with a letter or digit.",
        )


def _closed(obj, allowed, where):
    if not isinstance(obj, dict):
        raise TemplateError("invalid", f"{where} must be an object.")
    for key in obj:
        if key not in allowed:
            raise TemplateError("invalid", f"{where} has a key this version does not know: {key!r}.")


def _require(obj, keys, where):
    for key in keys:
        if key not in obj:
            raise TemplateError("invalid", f"{where} is missing {key!r}.")


def _text(value, where, allow_empty=False):
    if not isinstance(value, str) or (not allow_empty and not value.strip()):
        raise TemplateError("invalid", f"{where} must be text.")


def _validate_source(source, where):
    if not isinstance(source, dict):
        raise TemplateError("invalid", f"{where} must be an object.")
    kind = source.get("kind")
    if kind not in SOURCE_KINDS:
        raise TemplateError(
            "invalid", f"{where} has kind {kind!r}. A source is one of: {', '.join(SOURCE_KINDS)}."
        )
    _closed(source, SOURCE_KEYS[kind], where)
    _require(source, SOURCE_KEYS[kind], where)
    if kind == "tool":
        _text(source["tool"], f"{where}.tool")
        if not isinstance(source["args"], dict):
            raise TemplateError("invalid", f"{where}.args must be an object.")
    elif kind == "command":
        _text(source["command"], f"{where}.command")
        if source["command"].count("{output}") != 1:
            raise TemplateError(
                "invalid",
                f"{where}.command must contain {{output}} exactly once, where the script "
                "names the file the command writes to.",
            )
    else:
        _text(source["path"], f"{where}.path")
        if not os.path.isabs(source["path"]):
            raise TemplateError("invalid", f"{where}.path must be an absolute path.")


def _validate_present(present, where):
    _closed(present, PRESENT_KEYS, where)
    for key in ("title", "units"):
        if key in present:
            _text(present[key], f"{where}.{key}", allow_empty=True)
    if "type" in present and present["type"] not in FORMS:
        raise TemplateError("invalid", f"{where}.type must be one of: {', '.join(FORMS)}.")
    if "width" in present:
        width = present["width"]
        # bool is an int subclass, so True would otherwise pass as a width of 1.
        if isinstance(width, bool) or not isinstance(width, int) or not (
            constants.MIN_WIDTH <= width <= constants.MAX_WIDTH
        ):
            raise TemplateError(
                "invalid",
                f"{where}.width must be a whole number from {constants.MIN_WIDTH} to {constants.MAX_WIDTH}.",
            )


def validate(template):
    _closed(template, TOP_KEYS, "The template")
    _require(template, TOP_REQUIRED, "The template")
    check_name(template["name"])
    _text(template["purpose"], "The template's purpose")
    if "caveats" in template:
        caveats = template["caveats"]
        if not isinstance(caveats, list) or not all(isinstance(c, str) for c in caveats):
            raise TemplateError("invalid", "caveats must be a list of text lines.")
    if "created_at" in template:
        _text(template["created_at"], "created_at")
    blocks = template["blocks"]
    if not isinstance(blocks, list) or not blocks:
        raise TemplateError("invalid", "A template needs at least one block.")
    for i, block in enumerate(blocks):
        where = f"Block {i + 1}"
        _closed(block, BLOCK_KEYS, where)
        _require(block, BLOCK_KEYS, where)
        _validate_source(block["source"], f"{where} source")
        mapping = block["mapping"]
        if not isinstance(mapping, dict) or mapping.get("adapter") not in ADAPTERS:
            raise TemplateError(
                "invalid", f"{where} mapping needs an adapter, one of: {', '.join(ADAPTERS)}."
            )
        _validate_present(block["present"], f"{where} present")
        if not isinstance(block["fingerprint"], dict):
            raise TemplateError("invalid", f"{where} fingerprint must be an object.")


def _is_env_ref(text):
    return _ENV_REF.fullmatch(text) is not None


def _long_token(text):
    for run in _ALNUM_RUN.findall(_ENV_REF.sub(" ", text)):
        if len(run) >= TOKEN_MIN and any(c.isalpha() for c in run) and any(c.isdigit() for c in run):
            return True
    return False


def _refuse_literal(position):
    raise TemplateError(
        "secret",
        f"{position} holds a literal value. A template never stores a credential: put it in an "
        "environment variable and write $NAME or ${NAME} there instead.",
    )


def _check_header(header):
    name, sep, value = header.partition(":")
    name = name.strip()
    if not sep or not name:
        raise TemplateError(
            "secret",
            "A header must be written as 'Name: value' so it can be checked for a credential.",
        )
    if name.lower() in SAFE_HEADERS:
        return
    words = value.split()
    if len(words) == 1 and _is_env_ref(words[0]):
        return
    if len(words) == 2 and words[0].lower() in AUTH_SCHEMES and _is_env_ref(words[1]):
        return
    _refuse_literal(f"The {name} header")


def _credential_name(name):
    name = name.lower()
    return any(word in name for word in CREDENTIAL_NAMES)


def _check_user(value, position):
    if not all(_is_env_ref(part) for part in value.split(":")):
        _refuse_literal(position)


def _check_credential(kind, value, position):
    if kind == "header":
        _check_header(value)
    elif kind == "user":
        _check_user(value, position)
    elif not _is_env_ref(value):
        _refuse_literal(position)


def _urls(text):
    # The scheme plays no part in the check, and a fixed one catches "://" after an odd or
    # missing scheme that a scheme pattern would pass over.
    return ["x" + tail for tail in _URL_TAIL.findall(text)]


def _check_url(url):
    parts = urlsplit(url)
    userinfo, at, _host = parts.netloc.rpartition("@")
    if at:
        _check_user(userinfo, "The URL's user and password")
    for key, value in parse_qsl(parts.query, keep_blank_values=True):
        if any(word in key.lower() for word in CREDENTIAL_WORDS) and not _is_env_ref(value):
            _refuse_literal(f"The URL query value for {key!r}")


def _check_curl(words):
    failing = False
    i = 0
    while i < len(words):
        word = words[i]
        i += 1
        if word.startswith("--"):
            option, eq, attached = word.partition("=")
            if option in _CURL_FAIL:
                failing = True
            elif option in _CURL_LONG_CREDENTIAL or option in _CURL_LONG_WITH_VALUE:
                if not eq and i < len(words):
                    attached = words[i]
                    i += 1
                if option in _CURL_LONG_CREDENTIAL:
                    _check_credential(_CURL_LONG_CREDENTIAL[option], attached, f"The {option} value")
        elif word.startswith("-") and len(word) > 1:
            for j, letter in enumerate(word[1:], start=1):
                if letter == "f":
                    failing = True
                if letter in _CURL_SHORT_WITH_VALUE:
                    value = word[j + 1:]
                    if not value and i < len(words):
                        value = words[i]
                        i += 1
                    if letter in _CURL_SHORT_CREDENTIAL:
                        _check_credential(_CURL_SHORT_CREDENTIAL[letter], value, f"The -{letter} value")
                    break
    if not failing:
        raise TemplateError(
            "invalid",
            "A saved curl command must use -f (or --fail), so an HTTP error fails the command "
            "instead of saving an error page as data.",
        )


def _check_options(words):
    i = 0
    while i < len(words):
        word = words[i]
        i += 1
        if word.startswith("--"):
            option, eq, value = word.partition("=")
            if not _credential_name(option):
                continue
            if not eq:
                value = words[i] if i < len(words) else ""
                i += 1
            if "header" in option.lower():
                _check_header(value)
            elif not _is_env_ref(value):
                # Without an = the option and a glued-on value are one word, so only a
                # name that cannot be carrying a value is safe to print.
                _refuse_literal(
                    f"The {option} value" if _PRINTABLE_OPTION.fullmatch(option) else "A credential option"
                )
        elif word.startswith("-H"):
            value = word[2:]
            if not value:
                value = words[i] if i < len(words) else ""
                i += 1
            _check_header(value)
        else:
            header = _HEADER_WORD.fullmatch(word)
            if header and _credential_name(header.group(1)):
                _check_header(word)


def _segments(command):
    lexer = shlex.shlex(command, posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    # A # in a URL fragment would otherwise end the command and hide the rest from the scan.
    lexer.commenters = ""
    try:
        tokens = list(lexer)
    except ValueError as err:
        raise TemplateError("invalid", f"The command cannot be read: {err}.") from None
    segments, current = [], []
    for token in tokens:
        if token and all(c in "();<>|&" for c in token):
            segments.append(current)
            current = []
        else:
            current.append(token)
    segments.append(current)
    return [s for s in segments if s]


def _scan_command(command):
    if _long_token(command):
        raise TemplateError(
            "secret",
            f"The command holds a run of {TOKEN_MIN} or more mixed letters and digits, which looks "
            "like a credential. Put it in an environment variable and write $NAME instead.",
        )
    for words in _segments(command):
        for word in words:
            assignment = _ASSIGNMENT.fullmatch(word)
            if assignment and any(w in assignment.group(1).lower() for w in CREDENTIAL_WORDS):
                if not _is_env_ref(assignment.group(2)):
                    _refuse_literal(f"The {assignment.group(1)} assignment")
            for url in _urls(word):
                _check_url(url)
        _check_options(words)
        for k, word in enumerate(words):
            if os.path.basename(word) == "curl":
                _check_curl(words[k + 1:])


def _leaves(value, keys):
    if isinstance(value, dict):
        for key, child in value.items():
            yield from _leaves(child, keys + (str(key),))
    elif isinstance(value, list):
        for index, child in enumerate(value):
            yield from _leaves(child, keys + (index,))
    else:
        yield keys, value


def _refuse_tool_arg(path, what):
    raise TemplateError(
        "secret",
        f"The tool argument {path} {what}. A tool argument is sent exactly as written, with no "
        "$NAME expansion, so a template can never hold a credential there: fetch this data with "
        "a command source that reads the credential from an environment variable.",
    )


def _scan_tool(source):
    if str(source.get("tool", "")).strip().lower() == "bash":
        raise TemplateError(
            "invalid",
            "A Bash call is saved as a command source, not a tool source, so it gets the command "
            "checks: the credential scan and the -f rule.",
        )
    for keys, leaf in _leaves(source.get("args", {}), ()):
        path = ".".join(str(k) for k in ("args",) + keys)
        if isinstance(leaf, bool) or leaf is None:
            continue
        if any(isinstance(k, str) and _credential_name(k) for k in keys):
            _refuse_tool_arg(path, "sits under a name that marks a credential")
        if not isinstance(leaf, str):
            continue
        if _long_token(leaf):
            _refuse_tool_arg(
                path, f"holds a run of {TOKEN_MIN} or more mixed letters and digits, which looks like a credential"
            )
        for url in _urls(leaf):
            try:
                _check_url(url)
            except TemplateError:
                _refuse_tool_arg(path, "holds a URL with a credential in its user part or query")


def secret_scan(source):
    if not isinstance(source, dict):
        raise TemplateError("invalid", "A source must be an object.")
    kind = source.get("kind")
    if kind == "command":
        _scan_command(source.get("command", ""))
    elif kind == "tool":
        _scan_tool(source)


def env_names(source):
    if not isinstance(source, dict) or source.get("kind") != "command":
        return []
    names = []
    for braced, bare in _ENV_REF.findall(source.get("command", "")):
        name = braced or bare
        if name not in names:
            names.append(name)
    return names


def _looks_absolute(value):
    if isinstance(value, (int, float)):
        return EPOCH_MIN <= value <= EPOCH_MAX or EPOCH_MIN * 1000 <= value <= EPOCH_MAX * 1000
    if isinstance(value, str):
        return _ISO_DATE.fullmatch(value.strip()) is not None
    return False


def absolute_dates(args):
    found = []

    def walk(value, path):
        if isinstance(value, dict):
            for key, child in value.items():
                if key == "relative":
                    continue
                walk(child, f"{path}.{key}" if path else str(key))
        elif isinstance(value, list):
            for index, child in enumerate(value):
                walk(child, f"{path}.{index}" if path else str(index))
        elif _looks_absolute(value):
            found.append(path)

    walk(args, "")
    return found


def template_hash(template):
    # name is excluded as well as created_at: rename carries the run record (R17), and a
    # record whose hash differs from its template is treated as absent (KTD6).
    body = {k: v for k, v in template.items() if k not in ("created_at", "name")}
    canonical = json.dumps(body, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()


def ensure_dirs(home=None):
    base = root(home)
    for sub in SUBDIRS:
        os.makedirs(os.path.join(base, sub), mode=0o700, exist_ok=True)
    # makedirs applies its mode only to the leaf and through the umask, so set it outright.
    os.chmod(base, 0o700)
    for sub in SUBDIRS:
        os.chmod(os.path.join(base, sub), 0o700)
    return base


def _path(sub, name, home):
    check_name(name)
    return os.path.join(root(home), sub, name + ".json")


def _atomic_write(path, data):
    fd, tmp = tempfile.mkstemp(prefix=".tmp-", suffix=".json", dir=os.path.dirname(path))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            os.fchmod(fh.fileno(), 0o600)
            json.dump(data, fh, indent=2, sort_keys=True, ensure_ascii=False)
            fh.write("\n")
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass
        raise


def _read_json(path, what):
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except json.JSONDecodeError as err:
        raise TemplateError("invalid", f"The {what} file cannot be read as JSON: {err}.") from None


def save(template, replace=False, home=None):
    validate(template)
    for block in template["blocks"]:
        secret_scan(block["source"])
    path = _path("templates", template["name"], home)
    if not replace and os.path.exists(path):
        raise TemplateError(
            "exists",
            f"A report named {template['name']!r} already exists. Replacing it needs an explicit "
            "replace request.",
        )
    ensure_dirs(home)
    _atomic_write(path, template)


def load(name, home=None):
    path = _path("templates", name, home)
    if not os.path.exists(path):
        raise TemplateError("missing", f"There is no saved report named {name!r}.")
    template = _read_json(path, f"{name!r} report")
    validate(template)
    if template["name"] != name:
        raise TemplateError(
            "invalid", f"The file for {name!r} names itself {template['name']!r}; it was edited by hand."
        )
    return template


def list_templates(home=None):
    folder = os.path.join(root(home), "templates")
    if not os.path.isdir(folder):
        return []
    found = []
    for entry in sorted(os.listdir(folder)):
        stem, ext = os.path.splitext(entry)
        if ext != ".json" or not re.fullmatch(NAME_PATTERN, stem):
            continue
        try:
            purpose = load(stem, home)["purpose"]
        except TemplateError as err:
            purpose = f"This report cannot be read: {err}"
        found.append((stem, purpose))
    return found


def delete(name, home=None):
    path = _path("templates", name, home)
    run_path = _path("runs", name, home)
    if not os.path.exists(path):
        raise TemplateError("missing", f"There is no saved report named {name!r}.")
    os.unlink(path)
    if os.path.exists(run_path):
        os.unlink(run_path)


def rename(old, new, home=None):
    old_path = _path("templates", old, home)
    new_path = _path("templates", new, home)
    old_run = _path("runs", old, home)
    new_run = _path("runs", new, home)
    template = load(old, home)
    if os.path.exists(new_path):
        raise TemplateError("exists", f"A report named {new!r} already exists.")
    template["name"] = new
    ensure_dirs(home)
    _atomic_write(new_path, template)
    if os.path.exists(old_run):
        os.replace(old_run, new_run)
    elif os.path.exists(new_run):
        os.unlink(new_run)
    os.unlink(old_path)


def load_run(name, home=None):
    path = _path("runs", name, home)
    if not os.path.exists(path):
        return None
    record = _read_json(path, f"{name!r} run record")
    if not isinstance(record, dict):
        raise TemplateError("invalid", f"The run record for {name!r} is not an object.")
    return record


def write_run(name, record, home=None):
    path = _path("runs", name, home)
    ensure_dirs(home)
    _atomic_write(path, record)
