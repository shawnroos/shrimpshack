"""The credential scan a saved source must pass.

A template never stores a credential. The scan refuses a literal value in any position
that can carry one, and refuses what it cannot read rather than guessing it is harmless.
"""

import json
import os
import re
import shlex
from urllib.parse import parse_qsl, urlsplit

KINDS = ("invalid", "secret")

SAFE_HEADERS = ("accept", "content-type", "user-agent")
AUTH_SCHEMES = ("bearer", "basic", "token", "bot")
# "sig" is left out: it reads inside "signal" and "sigma", which name ordinary data.
CREDENTIAL_WORDS = (
    "token", "key", "secret", "pass", "auth", "pwd", "cred", "session", "bearer", "jwt",
)
# Matched as substrings in URL query keys, assignments, tool argument keys and header
# words, where a camelCase or plural spelling (apiKey, tokens) must still count.
CREDENTIAL_NAMES = CREDENTIAL_WORDS + ("header", "cookie")
# A lowercase hyphenated option name is matched on whole words instead, so --sort-keys
# and --anyauth pass. Any other shape falls back to substrings (see _credential_option).
OPTION_WORDS = (
    "token", "secret", "pass", "password", "passwd", "passphrase", "auth", "authorization",
    "apikey", "header", "cookie",
)
# Only as part of a longer name (--api-key, --secret-key): a bare --key is sort's field.
OPTION_COMPOUND_WORDS = ("key",)
# A last word that names a kind of credential rather than holding one: --auth-type bearer.
OPTION_QUALIFIERS = ("type", "method", "scheme")
# Programs whose -H is a header. wget is left out: its -H is --span-hosts and takes no
# value, so reading it as a header refuses a harmless command.
HTTP_CLIENTS = ("curl", "http", "https", "xh", "xhs")
# httpie and xh read -a as --auth. curl's -a is --append and takes no value, so reading it
# as a credential refuses a harmless command.
AUTH_SHORT_CLIENTS = ("http", "https", "xh", "xhs")
# KTD10: the shortest run of mixed letters and digits treated as a credential. Chart ids
# (8 characters) and ISO dates sit well under it; a 32-hex API key sits well over.
TOKEN_MIN = 20

_ENV_REF = re.compile(r"\$(?:\{([A-Z_][A-Z0-9_]*)\}|([A-Z_][A-Z0-9_]*))")
_ALNUM_RUN = re.compile(r"[A-Za-z0-9]+")
_URL_TAIL = re.compile(r"://\S*")
_ASSIGNMENT = re.compile(r"([A-Za-z_][A-Za-z0-9_]*)=(.*)", re.S)
_HEADER_WORD = re.compile(r"([A-Za-z][A-Za-z0-9_-]*):(.*)", re.S)
_PRINTABLE_OPTION = re.compile(r"--[a-z]+(?:-[a-z]+)*")
# The template placeholder sources.py substitutes ({output}); it is not a JSON body.
_PLACEHOLDER = re.compile(r"\{[a-z_]+\}")

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


class CredentialError(Exception):
    def __init__(self, kind, message):
        if kind not in KINDS:
            raise ValueError(f"unknown CredentialError kind {kind!r}")
        super().__init__(message)
        self.kind = kind


def looks_secret(text):
    for run in _ALNUM_RUN.findall(text):
        if len(run) >= TOKEN_MIN and any(c.isalpha() for c in run) and any(c.isdigit() for c in run):
            return True
    return False


def _is_env_ref(text):
    return _ENV_REF.fullmatch(text) is not None


def _long_token(text):
    return looks_secret(_ENV_REF.sub(" ", text))


def _refuse_long_token(position):
    raise CredentialError(
        "secret",
        f"{position} holds a run of {TOKEN_MIN} or more mixed letters and digits, which looks "
        "like a credential. Put it in an environment variable and write $NAME instead.",
    )


def _refuse_literal(position):
    raise CredentialError(
        "secret",
        f"{position} holds a literal value. A template never stores a credential: put it in an "
        "environment variable and write $NAME or ${NAME} there instead.",
    )


def _check_header(header):
    name, sep, value = header.partition(":")
    name = name.strip()
    if not sep or not name:
        raise CredentialError(
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


def _env_value(text):
    # What _check_header accepts as a value that holds no literal: a reference on its own,
    # or a scheme and a reference.
    words = text.split()
    if len(words) == 1:
        return _is_env_ref(words[0])
    return len(words) == 2 and words[0].lower() in AUTH_SCHEMES and _is_env_ref(words[1])


def _assignment_names(text, expand):
    # A request body joins its assignments with &, so each one is checked on its own.
    names = []
    for part in text.split("&"):
        assignment = _ASSIGNMENT.fullmatch(part)
        if not assignment or not any(w in assignment.group(1).lower() for w in CREDENTIAL_WORDS):
            continue
        if expand and _is_env_ref(assignment.group(2)):
            continue
        names.append(assignment.group(1))
    return names


BODY_FLAGS = ("-d", "--data", "--data-raw", "--data-binary", "--data-urlencode", "--json")


def _body_text(word):
    """The request body a word carries, when it is one: -d{...}, --data={...}, or nothing."""
    for flag in BODY_FLAGS:
        if word.startswith(flag + "="):
            return word[len(flag) + 1:]
        if flag.startswith("--"):
            continue
        if word.startswith(flag) and len(word) > len(flag):
            return word[len(flag):]
    return None


def _json_body(text, position):
    try:
        return json.loads(text)
    except ValueError:
        raise CredentialError(
            "invalid",
            f"{position} starts like JSON but cannot be read as JSON, so it cannot be checked "
            "for a credential. Write it as JSON, or keep it out of a saved source.",
        ) from None


def _json_credential_paths(text, position, expand):
    """The paths in a JSON body that sit under a name marking a credential."""
    paths = []
    for keys, leaf in _leaves(_json_body(text, position), ()):
        if isinstance(leaf, bool) or leaf is None:
            continue
        if not any(isinstance(k, str) and _credential_name(k) for k in keys):
            continue
        if expand and isinstance(leaf, str) and _env_value(leaf):
            continue
        paths.append(".".join(str(k) for k in keys))
    return paths


def _credential_option(option):
    if not _PRINTABLE_OPTION.fullmatch(option):
        # Digits, capitals or underscores: the name may be glued to its value
        # (--api-keyfake123), so whole words cannot be trusted.
        return _credential_name(option)
    words = option[2:].split("-")
    if len(words) > 1 and words[-1] in OPTION_QUALIFIERS:
        return False
    return any(w in OPTION_WORDS or (w in OPTION_COMPOUND_WORDS and len(words) > 1) for w in words)


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
        raise CredentialError(
            "invalid",
            "A saved curl command must use -f (or --fail), so an HTTP error fails the command "
            "instead of saving an error page as data.",
        )


def _http_client_start(words):
    for k, word in enumerate(words):
        program = os.path.basename(word)
        if program in HTTP_CLIENTS:
            return k + 1, program
        if program == "gh" and k + 1 < len(words) and words[k + 1] == "api":
            return k + 2, program
    return None, None


def _check_options(words):
    header_from, client = _http_client_start(words)
    i = 0
    while i < len(words):
        word = words[i]
        i += 1
        if word.startswith("--"):
            option, eq, value = word.partition("=")
            client_auth = option == "--auth" and header_from is not None and i > header_from
            if not client_auth and not _credential_option(option):
                continue
            if not eq:
                value = words[i] if i < len(words) else ""
                i += 1
            if client_auth:
                _check_user(value, "The --auth value")
            elif "header" in option.lower():
                _check_header(value)
            elif not _is_env_ref(value):
                # Without an = the option and a glued-on value are one word, so only a
                # name that cannot be carrying a value is safe to print.
                _refuse_literal(
                    f"The {option} value" if _PRINTABLE_OPTION.fullmatch(option) else "A credential option"
                )
        elif word.startswith("-H") and header_from is not None and i > header_from:
            value = word[2:]
            if not value:
                value = words[i] if i < len(words) else ""
                i += 1
            _check_header(value)
        elif word.startswith("-a") and client in AUTH_SHORT_CLIENTS and i > header_from:
            value = word[2:]
            if not value:
                value = words[i] if i < len(words) else ""
                i += 1
            _check_user(value, "The -a value")
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
        raise CredentialError("invalid", f"The command cannot be read: {err}.") from None
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
        _refuse_long_token("The command")
    for words in _segments(command):
        body_next = False
        for word in words:
            # The raw text breaks a run at every quote, so a token split across adjacent
            # quotes is only whole once the word is dequoted.
            if _long_token(word):
                _refuse_long_token("A word of the command")
            for name in _assignment_names(word, expand=True):
                _refuse_literal(f"The {name} assignment")
            body = _body_text(word) if not body_next else word
            # Only a request body is read as JSON. Any braced word would also catch a jq
            # filter or a shell group, which carry no credential the option scan misses.
            if body is not None and body[:1] in ("{", "[") and not _PLACEHOLDER.fullmatch(body):
                for path in _json_credential_paths(body, "A word of the command", expand=True):
                    _refuse_literal(f"The JSON body value at {path}")
            body_next = word in BODY_FLAGS
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
    raise CredentialError(
        "secret",
        f"The tool argument {path} {what}. A tool argument is sent exactly as written, with no "
        "$NAME expansion, so a template can never hold a credential there: fetch this data with "
        "a command source that reads the credential from an environment variable.",
    )


def _scan_tool(source):
    if str(source.get("tool", "")).strip().lower() == "bash":
        raise CredentialError(
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
        for name in _assignment_names(leaf, expand=False):
            _refuse_tool_arg(path, f"holds a {name} assignment")
        if leaf[:1] in ("{", "["):
            for json_path in _json_credential_paths(leaf, f"The tool argument {path}", expand=False):
                _refuse_tool_arg(path, f"holds JSON with a value at {json_path} under a name that marks a credential")
        header = _HEADER_WORD.fullmatch(leaf)
        if header and _credential_name(header.group(1)):
            _refuse_tool_arg(path, f"holds a {header.group(1)} header, which carries a credential")
        for url in _urls(leaf):
            try:
                _check_url(url)
            except CredentialError:
                _refuse_tool_arg(path, "holds a URL with a credential in its user part or query")


def scan_source(source):
    if not isinstance(source, dict):
        raise CredentialError("invalid", "A source must be an object.")
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
