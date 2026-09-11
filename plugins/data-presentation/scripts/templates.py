"""The template store and its save gates.

A template is refused on shape it does not recognise rather than on shapes known to be
bad: an unknown key a hand edit adds is behaviour nobody reviewed.
"""

import hashlib
import json
import os
import re
import tempfile

import constants
import credentials
from canon import canonical_json
from mapping import ADAPTERS
from validate import FORMS

NAME_PATTERN = r"^[a-z0-9][a-z0-9-]{0,23}$"
SOURCE_KINDS = ("tool", "command", "file")
KINDS = ("invalid", "exists", "missing", "secret", "absolute_dates")

TOP_KEYS = ("name", "purpose", "caveats", "blocks", "created_at")
TOP_REQUIRED = ("name", "purpose", "blocks")
BLOCK_KEYS = ("source", "mapping", "present", "fingerprint")
SOURCE_KEYS = {"tool": ("kind", "tool", "args"), "command": ("kind", "command"), "file": ("kind", "path")}
PRESENT_KEYS = ("title", "units", "type", "width")
SUBDIRS = ("templates", "runs", "out")

EPOCH_MIN = 946684800
EPOCH_MAX = 4102444800

_ISO_DATE = re.compile(r"\d{4}-\d{2}-\d{2}(?:[T ]\d{2}:\d{2}(?::\d{2}(?:\.\d+)?)?(?:Z|[+-]\d{2}:?\d{2})?)?")


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
    return hashlib.sha256(canonical_json(body).encode("utf-8")).hexdigest()


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


def _atomic_write(path, data, replace=True):
    fd, tmp = tempfile.mkstemp(prefix=".tmp-", suffix=".json", dir=os.path.dirname(path))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            os.fchmod(fh.fileno(), 0o600)
            json.dump(data, fh, indent=2, sort_keys=True, ensure_ascii=False)
            fh.write("\n")
            fh.flush()
            os.fsync(fh.fileno())
        if replace:
            os.replace(tmp, path)
        else:
            # link refuses a name that exists, so two sessions creating one name cannot
            # both pass the way an exists check followed by replace can.
            os.link(tmp, path)
            os.unlink(tmp)
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
    try:
        for block in template["blocks"]:
            credentials.scan_source(block["source"])
    except credentials.CredentialError as err:
        raise TemplateError(err.kind, str(err)) from None
    path = _path("templates", template["name"], home)
    taken = TemplateError(
        "exists",
        f"A report named {template['name']!r} already exists. Replacing it needs an explicit "
        "replace request.",
    )
    if not replace and exists(template["name"], home):
        raise taken
    ensure_dirs(home)
    try:
        _atomic_write(path, template, replace=replace)
    except FileExistsError:
        raise taken from None


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


def exists(name, home=None):
    return os.path.exists(_path("templates", name, home))


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
    taken = TemplateError("exists", f"A report named {new!r} already exists.")
    if exists(new, home):
        raise taken
    template["name"] = new
    ensure_dirs(home)
    try:
        _atomic_write(new_path, template, replace=False)
    except FileExistsError:
        raise taken from None
    if os.path.exists(old_run):
        os.replace(old_run, new_run)
    elif os.path.exists(new_run):
        os.unlink(new_run)
    os.unlink(old_path)


def load_run(name, home=None):
    path = _path("runs", name, home)
    if not os.path.exists(path):
        return None
    return _read_json(path, f"{name!r} run record")


def write_run(name, record, home=None):
    path = _path("runs", name, home)
    ensure_dirs(home)
    _atomic_write(path, record)
