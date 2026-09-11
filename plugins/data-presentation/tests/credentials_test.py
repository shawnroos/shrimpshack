#!/usr/bin/env python3
"""The credential scan a saved source must pass (KTD10)."""

import os
import sys

SCRIPTS = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "scripts")
sys.path.insert(0, SCRIPTS)

import credentials  # noqa: E402

passed = failed = 0


def check(name, condition, detail=""):
    global passed, failed
    if condition:
        passed += 1
        print(f"  ok   - {name}")
    else:
        failed += 1
        print(f"  FAIL - {name}{(': ' + detail) if detail else ''}", file=sys.stderr)


def refusal(fn, *args, **kwargs):
    try:
        fn(*args, **kwargs)
    except credentials.CredentialError as err:
        return err
    return None


def kind_of(err):
    return err.kind if err is not None else None


def tool_block(args=None):
    return {
        "source": {
            "kind": "tool",
            "tool": "mcp__fake_analytics__get_charts",
            "args": args if args is not None else {"chartIds": ["abc1def2"], "include": "data"},
        },
    }


def secret_kind(command):
    return kind_of(refusal(credentials.scan_source, {"kind": "command", "command": command}))


def accepted(command):
    return refusal(credentials.scan_source, {"kind": "command", "command": command}) is None


GOOD_CURL = 'curl -fsS -H "Authorization: Bearer $FAKE_TOKEN" "https://api.example.test/v1/x" -o {output}'


def main():
    # --- secrets: credential positions in a command (KTD10) ---
    check("a literal bearer token is refused",
          secret_kind('curl -f -H "Authorization: Bearer abc123def456ghi789jkl" https://api.example.test -o {output}')
          == "secret")
    check("a short literal bearer token is refused by the header rule alone",
          secret_kind('curl -f -H "Authorization: Bearer abc" https://api.example.test -o {output}') == "secret")
    check("a bearer env reference is accepted", accepted(GOOD_CURL))
    check("a braced env reference is accepted",
          accepted('curl -f -H "Authorization: Bearer ${FAKE_TOKEN}" https://api.example.test -o {output}'))
    check("a literal X-Api-Key header is refused",
          secret_kind('curl -f -H "X-Api-Key: abc123" https://api.example.test -o {output}') == "secret")
    check("an X-Api-Key env reference is accepted",
          accepted('curl -f -H "X-Api-Key: $FAKE_KEY" https://api.example.test -o {output}'))
    check("a header name is matched without regard to case",
          secret_kind('curl -f -H "x-api-key: abc123" https://api.example.test -o {output}') == "secret")
    check("an attached -H value is still a credential position",
          secret_kind('curl -f -H"X-Api-Key: abc123" https://api.example.test -o {output}') == "secret")
    check("a --header value is a credential position",
          secret_kind('curl -f --header "X-Api-Key: abc123" https://api.example.test -o {output}') == "secret")
    check("a header in a combined short flag cluster is a credential position",
          secret_kind('curl -fsSH "X-Api-Key: abc123" https://api.example.test -o {output}') == "secret")
    check("a literal Accept header is accepted",
          accepted('curl -f -H "Accept: application/json" https://api.example.test -o {output}'))
    check("a literal Content-Type and User-Agent are accepted",
          accepted('curl -f -H "Content-Type: application/json" -H "User-Agent: fake-agent" '
                   "https://api.example.test -o {output}"))
    check("URL userinfo is refused",
          secret_kind("curl -f https://user:pass@api.example.test/v1 -o {output}") == "secret")
    check("URL userinfo from env references is accepted",
          accepted("curl -f https://$FAKE_USER:$FAKE_PASS@api.example.test/v1 -o {output}"))
    check("URL userinfo is refused outside a curl command",
          secret_kind("wget -O {output} https://user:pass@api.example.test/v1") == "secret")
    check("a literal -u value is refused",
          secret_kind("curl -f -u me:pw https://api.example.test -o {output}") == "secret")
    check("a literal --user value is refused",
          secret_kind("curl -f --user me:pw https://api.example.test -o {output}") == "secret")
    check("a -u value from env references is accepted",
          accepted("curl -f -u $FAKE_USER:$FAKE_PASS https://api.example.test -o {output}"))
    check("a literal --oauth2-bearer is refused",
          secret_kind("curl -f --oauth2-bearer short https://api.example.test -o {output}") == "secret")
    check("an --oauth2-bearer env reference is accepted",
          accepted("curl -f --oauth2-bearer $FAKE_TOKEN https://api.example.test -o {output}"))
    for key in ("api_key", "token", "client_secret", "password", "auth"):
        check(f"a literal query value under {key!r} is refused",
              secret_kind(f'curl -f "https://api.example.test/v1?{key}=short&x=1" -o {{output}}') == "secret")
    check("an empty query value under a credential key is refused",
          secret_kind('curl -f "https://api.example.test/v1?token=" -o {output}') == "secret")
    check("a query value under a credential key from an env reference is accepted",
          accepted('curl -f "https://api.example.test/v1?api_key=$FAKE_KEY&start=-90d" -o {output}'))
    check("an ordinary query value is accepted",
          accepted('curl -f "https://api.example.test/v1?limit=10&m=uniques" -o {output}'))
    check("a bare $ is not a reference",
          secret_kind('curl -f -H "Authorization: Bearer $" https://api.example.test -o {output}') == "secret")
    check("an empty braced reference is not a reference",
          secret_kind('curl -f -H "Authorization: Bearer ${}" https://api.example.test -o {output}') == "secret")
    check("a lowercase $name is not a reference",
          secret_kind('curl -f -H "Authorization: Bearer $token" https://api.example.test -o {output}') == "secret")
    check("a -u flag in a later non-curl segment is not a credential position",
          accepted("curl -f https://api.example.test | sort -u > {output}"))
    check("a literal credential assignment before a command is refused",
          secret_kind("FAKE_API_KEY=abc123 curl -f https://api.example.test -o {output}") == "secret")
    check("a credential assignment from an env reference is accepted",
          accepted("FAKE_API_KEY=$FAKE_KEY curl -f https://api.example.test -o {output}"))
    err = refusal(credentials.scan_source, {
        "kind": "command", "command": 'curl -f -H "fakesecretvalue" https://api.example.test -o {output}'})
    check("a header with no name is refused without echoing it",
          kind_of(err) == "secret" and "fakesecretvalue" not in str(err), str(err))
    check("a header that is not Name: value is refused",
          secret_kind("curl -f -H @/tmp/fake-headers.txt https://api.example.test -o {output}") == "secret")
    check("sort -u on a non-curl segment is accepted",
          accepted("sort -u /tmp/fake-input.txt > {output}"))

    err = refusal(credentials.scan_source, {
        "kind": "command",
        "command": 'curl -f -H "X-Api-Key: abc123" https://api.example.test -o {output}',
    })
    check("a secret refusal never prints the literal value", err is not None and "abc123" not in str(err), str(err))
    check("a secret refusal names the position", err is not None and "X-Api-Key" in str(err), str(err))

    # --- secrets: the 20-character mixed rule, anywhere ---
    twenty = "abcdefghij0123456789"
    nineteen = "abcdefghij012345678"
    src = {"kind": "tool", "tool": "mcp__fake__q", "args": {"filter": {"note": [f"x {twenty} y"]}}}
    check("a 20-char mixed token inside tool args is refused", kind_of(refusal(credentials.scan_source, src)) == "secret")
    src = {"kind": "tool", "tool": "mcp__fake__q", "args": {"filter": {"note": [f"x {nineteen} y"]}}}
    check("a 19-char mixed token inside tool args is accepted", refusal(credentials.scan_source, src) is None)
    src = {"kind": "tool", "tool": "mcp__fake__q", "args": {"event": "abcdefghijklmnopqrstuvwxyz"}}
    check("a long all-letter value is accepted", refusal(credentials.scan_source, src) is None)
    src = {"kind": "tool", "tool": "mcp__fake__q", "args": {"event": "fake_tool_used_v2_remove_background_x"}}
    check("a long snake_case event name is accepted", refusal(credentials.scan_source, src) is None)
    src = {"kind": "tool", "tool": "mcp__fake__q", "args": {"k": "0123456789abcdef0123456789abcdef"}}
    check("a 32-hex key in tool args is refused", kind_of(refusal(credentials.scan_source, src)) == "secret")
    check("a 20-char mixed token in a command is refused",
          secret_kind(f'curl -f "https://api.example.test/v1/{twenty}" -o {{output}}') == "secret")
    check("a long env reference name is not a token",
          accepted('curl -f -H "Authorization: Bearer $FAKE_TOKEN_NAME_1234567890" https://api.example.test -o {output}'))

    # --- secrets: tool sources get no $NAME expansion, so no credential value at all ---
    def tool_refusal(args, tool="mcp__fake__q"):
        return refusal(credentials.scan_source, {"kind": "tool", "tool": tool, "args": args})

    err = tool_refusal({"command": "curl -f https://api.example.test -o /tmp/fake.json"}, tool="Bash")
    check("a Bash tool source is refused", err is not None, repr(err))
    check("the Bash refusal says to save it as a command", err is not None and "command source" in str(err), str(err))

    for label, args, secret in (
        ("a short value under api_key", {"api_key": "fakeshort"}, "fakeshort"),
        ("a nested password under auth", {"auth": {"password": "fakepw"}}, "fakepw"),
        ("any value under an auth ancestor", {"auth": {"user": "fakeuser"}}, "fakeuser"),
        ("a list under a tokens key", {"tokens": ["fakeone"]}, "fakeone"),
        ("an env reference under a key (tool args never expand it)", {"apiKey": "$FAKE_KEY"}, "$FAKE_KEY"),
        ("a number under a secret key", {"client_secret": 123456}, "123456"),
        ("a query api_key in a tool URL", {"url": "https://api.example.test/v1?api_key=fakeabc"}, "fakeabc"),
        ("userinfo in a tool URL", {"endpoint": {"base": "https://fakeuser:fakepw@api.example.test/v1"}}, "fakepw"),
        ("userinfo after a missing scheme", {"base": "see ://fakeuser:fakepw@api.example.test"}, "fakepw"),
        ("any value under a headers key", {"headers": {"X-Session": "fakesess"}}, "fakesess"),
        ("a value under a cookie key", {"cookie": "session=fakesess"}, "fakesess"),
    ):
        err = tool_refusal(args)
        check(f"tool args: {label} is refused", kind_of(err) == "secret", repr(err))
        check(f"tool args: the refusal for {label} does not echo it", err is not None and secret not in str(err), str(err))
        check(f"tool args: the refusal for {label} points at a command source",
              err is not None and "command source" in str(err), str(err))

    amplitude_args = {
        "chartIds": ["abc1def2", "ghi3jkl4"],
        "include": "data",
        "excludeIncompleteDatapoints": True,
        "groupByLimit": 10,
        "rationale": "A fake reason for the weekly pull",
        "projectId": "123456",
        "chart": "abc1def2",
        "date_range": {"relative": "Last 90 Days"},
    }
    check("the real Amplitude argument shape is accepted", tool_refusal(amplitude_args) is None,
          str(tool_refusal(amplitude_args)))
    check("an ordinary tool URL is accepted",
          tool_refusal({"url": "https://api.example.test/v1?limit=10&m=uniques"}) is None)
    check("a true/false under a credential key is accepted", tool_refusal({"useAuth": True}) is None)

    # --- secrets: credential options in any program, not only curl ---
    for label, command, secret in (
        ("wget --header with a literal bearer",
         'wget --header "Authorization: Bearer fakeabc" -O {output} https://api.example.test', "fakeabc"),
        ("gh api -H with a literal key", 'gh api -H "X-Api-Key: fakeabc" /repos/x > {output}', "fakeabc"),
        ("gh api -H with a literal header of any name", 'gh api -H "X-Session: fakeabc" /repos/x > {output}',
         "fakeabc"),
        ("gh api -H with no header name", "gh api -H fakesecretvalue /repos/x > {output}", "fakesecretvalue"),
        ("an attached -H in any program", 'gh api -H"X-Session: fakeabc" /repos/x > {output}', "fakeabc"),
        ("an httpie Authorization:value word", "http GET https://api.example.test Authorization:fakeabc > {output}",
         "fakeabc"),
        ("an httpie X-Api-Key:value word", "http https://api.example.test X-Api-Key:fakeabc > {output}", "fakeabc"),
        ("curl -b with a literal cookie", 'curl -f -b "session=fakeabc" https://api.example.test -o {output}',
         "fakeabc"),
        ("curl --cookie with a literal cookie", 'curl -f --cookie "session=fakeabc" https://api.example.test -o {output}',
         "fakeabc"),
        ("a curl cluster ending in b", 'curl -fsSb "session=fakeabc" https://api.example.test -o {output}', "fakeabc"),
        ("an attached --token=value", "fetchtool --token=fakeabc https://api.example.test > {output}", "fakeabc"),
        ("a spaced --password value", "fetchtool --password fakeabc https://api.example.test > {output}", "fakeabc"),
        ("an --api-key value", "fetchtool --api-key fakeabc > {output}", "fakeabc"),
        ("an --auth value", "http --auth fakeuser:fakeabc https://api.example.test > {output}", "fakeabc"),
        ("a --cookie value in any program", "fetchtool --cookie session=fakeabc > {output}", "fakeabc"),
        ("an option with no value to read", "fetchtool -o {output} --token", None),
        ("an option name glued to its value", "fetchtool --api-keyfake123 > {output}", "fake123"),
    ):
        err = refusal(credentials.scan_source, {"kind": "command", "command": command})
        check(f"{label} is refused", kind_of(err) == "secret", repr(err))
        if secret:
            check(f"the refusal for {label} does not echo it", err is not None and secret not in str(err), str(err))
    err = refusal(credentials.scan_source, {"kind": "command", "command": "fetchtool --token=fakeabc > {output}"})
    check("an option refusal names the option", err is not None and "--token" in str(err), str(err))
    check("an option refusal says to use an environment variable",
          err is not None and "environment variable" in str(err), str(err))
    check("curl -fsS -H with a bearer env reference is still accepted",
          accepted('curl -fsS -H "Authorization: Bearer $TOKEN" https://api.example.test -o {output}'))
    check("wget --header with a bearer env reference is accepted",
          accepted('wget --header "Authorization: Bearer $FAKE_TOKEN" -O {output} https://api.example.test'))
    check("an httpie header from an env reference is accepted",
          accepted("http https://api.example.test X-Api-Key:$FAKE_KEY > {output}"))
    check("--token=$NAME is accepted", accepted("fetchtool --token=$FAKE_TOKEN > {output}"))
    check("--password ${NAME} is accepted", accepted("fetchtool --password ${FAKE_PASS} > {output}"))
    check("curl -b from an env reference is accepted",
          accepted('curl -f -b "$FAKE_COOKIE" https://api.example.test -o {output}'))
    check("gh api -H with a safe Accept header is accepted",
          accepted('gh api -H "Accept: application/json" /repos/x > {output}'))
    check("URL userinfo after a missing scheme is refused in a command",
          secret_kind("wget -O {output} ://fakeuser:fakepw@api.example.test") == "secret")
    check("a URL is not read as a header word", accepted("wget -O {output} https://api.example.test/v1"))
    check("an ordinary long option is accepted", accepted("fetchtool --limit 10 --format json > {output}"))

    # --- the -f rule ---
    err = refusal(credentials.scan_source, {
        "kind": "command", "command": 'curl -H "Authorization: Bearer $FAKE_TOKEN" https://api.example.test -o {output}'})
    check("a curl command without -f is refused", kind_of(err) == "invalid", repr(kind_of(err)))
    check("the -f refusal says so", err is not None and "-f" in str(err), str(err))
    check("-fsS is accepted", accepted("curl -fsS https://api.example.test -o {output}"))
    check("--fail is accepted", accepted("curl --fail https://api.example.test -o {output}"))
    check("-sf is accepted", accepted("curl -sf https://api.example.test -o {output}"))
    check("an f inside an -H value is not -f",
          kind_of(refusal(credentials.scan_source, {
              "kind": "command", "command": 'curl -H"Accept: fake/f" https://api.example.test -o {output}'}))
          == "invalid")
    check("a curl called by path still needs -f",
          kind_of(refusal(credentials.scan_source, {
              "kind": "command", "command": "/usr/bin/curl https://api.example.test -o {output}"})) == "invalid")
    check("a second curl in a pipeline still needs -f",
          kind_of(refusal(credentials.scan_source, {
              "kind": "command",
              "command": "curl -f https://api.example.test/a | curl https://api.example.test/b -o {output}"}))
          == "invalid")
    check("an unbalanced quote is refused as invalid",
          kind_of(refusal(credentials.scan_source, {"kind": "command", "command": 'curl -f "https://x {output}'}))
          == "invalid")

    # --- env_names ---
    names = credentials.env_names({"kind": "command", "command":
                                 'curl -f -H "Authorization: Bearer $FAKE_TOKEN" '
                                 '"https://api.example.test?k=${FAKE_KEY}" -u $FAKE_TOKEN:$FAKE_PASS -o {output}'})
    check("env_names lists each reference once, in order", names == ["FAKE_TOKEN", "FAKE_KEY", "FAKE_PASS"], repr(names))
    check("env_names of a tool source is empty", credentials.env_names(tool_block()["source"]) == [])
    check("env_names ignores a bare $", credentials.env_names({"kind": "command", "command": "echo $ > {output}"}) == [])

    # --- harmless flags that share a word or a letter with a credential option ---
    for label, command in (
        ("jq --sort-keys", "jq --sort-keys . /tmp/fake-input.json > {output}"),
        ("sort --key with a spaced value", "sort --key 2 /tmp/fake-input.txt > {output}"),
        ("sort --key=value", "sort --key=2,2n /tmp/fake-input.txt > {output}"),
        ("grep -H", "grep -H fakepattern /tmp/fake-input.txt > {output}"),
        ("find -H", "find -H /tmp/fake-dir -name fake.json > {output}"),
        ("wget -H, which spans hosts and takes no value", "wget -H -O {output} https://api.example.test"),
        ("grep -H after a curl stage", "curl -f https://api.example.test | grep -H fakepattern > {output}"),
        ("grep -H naming an HTTP client as its pattern", "grep -H http /tmp/fake-input.txt > {output}"),
        ("curl --anyauth", "curl -f --anyauth -u $FAKE_USER:$FAKE_PASS https://api.example.test -o {output}"),
        ("httpie --auth-type with a spaced value",
         "http --auth-type bearer --auth $FAKE_TOKEN https://api.example.test > {output}"),
        ("httpie --auth-type=value", "http --auth-type=bearer --auth=$FAKE_TOKEN https://api.example.test > {output}"),
        ("--max-tokens", "fetchtool --max-tokens 100 > {output}"),
    ):
        err = refusal(credentials.scan_source, {"kind": "command", "command": command})
        check(f"{label} is accepted", err is None, repr(err))

    # --- the credential options the narrower rule must still catch ---
    for label, command in (
        ("--api-key", "fetchtool --api-key fakeabc > {output}"),
        ("--token=", "fetchtool --token=fakeabc > {output}"),
        ("--password", "fetchtool --password fakeabc > {output}"),
        ("--auth", "http --auth fakeuser:fakeabc https://api.example.test > {output}"),
        ("--cookie", "fetchtool --cookie session=fakeabc > {output}"),
        ("--access-token", "fetchtool --access-token fakeabc > {output}"),
        ("--secret-key", "fetchtool --secret-key=fakeabc > {output}"),
        ("--secret-value, whose last word is no qualifier", "fetchtool --secret-value fakeabc > {output}"),
        ("--apiKey, a camelCase name", "fetchtool --apiKey fakeabc > {output}"),
        ("--api_key, an underscored name", "fetchtool --api_key fakeabc > {output}"),
        ("--authToken, a camelCase name", "fetchtool --authToken fakeabc > {output}"),
        ("curl -H", 'curl -f -H "X-Session: fakeabc" https://api.example.test -o {output}'),
        ("curl --user", "curl -f --user fakeuser:fakeabc https://api.example.test -o {output}"),
        ("wget --header", 'wget --header "X-Session: fakeabc" -O {output} https://api.example.test'),
        ("gh api -H", 'gh api -H "X-Session: fakeabc" /repos/x > {output}'),
        ("a curl called through env with -H", 'env curl -f -H "X-Session: fakeabc" https://api.example.test -o {output}'),
        ("xh -H", 'xh -H "X-Session: fakeabc" https://api.example.test > {output}'),
    ):
        check(f"{label} is still refused", secret_kind(command) == "secret", repr(secret_kind(command)))

    # --- looks_secret: the bare mixed-run rule a source value can be screened with ---
    check("looks_secret flags a 20-char mixed run", credentials.looks_secret(f"x {twenty} y"))
    check("looks_secret passes a 19-char mixed run", not credentials.looks_secret(f"x {nineteen} y"))
    check("looks_secret passes a long all-letter run", not credentials.looks_secret("abcdefghijklmnopqrstuvwxyz"))
    check("looks_secret gives a $NAME no exemption", credentials.looks_secret("$ABCDEFGHIJ0123456789"))
    check("the command scan does exempt that $NAME",
          accepted('curl -f -H "Authorization: Bearer $ABCDEFGHIJ0123456789" https://api.example.test -o {output}'))

    print(f"credentials_test: {passed} passed, {failed} failed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
