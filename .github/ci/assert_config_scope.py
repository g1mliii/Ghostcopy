#!/usr/bin/env python3
"""Fail the deploy if supabase/config.toml declares anything but email templates.

`supabase config push` writes exactly the properties config.toml declares and
leaves the rest alone, which is the only reason it is safe to run against a
project whose auth is configured in the dashboard - anonymous sign-ins, Google
OAuth, Resend SMTP, site_url and the ghostcopy:// redirect allow-list are all
undeclared here and so are never touched.

That safety lasts exactly as long as nobody widens the file. `supabase config
pull` would write ~20 of those settings into it in one go, and a partial
[auth.email.smtp] block (say, one missing `pass`) invalidates SMTP and stops
every auth email with nothing surfacing the failure. In CI there is no TTY, so
push's confirmation prompt defaults to yes and would apply all of it silently.
The CLI's own help says to diff first for this reason; this is that check.

Reads `supabase config diff --output-format json` on stdin.
"""
import json
import sys

ALLOWED = ["auth", "email", "template"]


def main() -> int:
    raw = sys.stdin.read().strip()
    if not raw:
        print("::error::no diff output to check", file=sys.stderr)
        return 1

    # The CLI prints human-readable preamble lines before the JSON object.
    line = next((l for l in reversed(raw.splitlines()) if l.startswith("{")), "")
    if not line:
        print("::error::could not find JSON in diff output", file=sys.stderr)
        print(raw, file=sys.stderr)
        return 1

    changes = json.loads(line).get("changes", [])

    # Only declared properties are written by a push; the rest are reported
    # purely so you can see what the dashboard holds.
    declared = [c for c in changes if c.get("declared")]
    for c in declared:
        print("declares {}: {!r} -> {!r}".format(
            ".".join(c["path"]), c.get("local"), c.get("remote")))

    stray = [c for c in declared if c["path"][:3] != ALLOWED]
    if stray:
        for c in stray:
            print("::error::config.toml declares {}, which is outside "
                  "auth.email.template. Refusing to push - this would change a "
                  "production auth setting.".format(".".join(c["path"])))
        return 1

    if not declared:
        print("OK - nothing outside auth.email.template is declared, and the "
              "subjects already match. The push uploads template bodies only "
              "(diff cannot see HTML changes).")
    else:
        print("OK - all {} declared changes are email templates.".format(
            len(declared)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
