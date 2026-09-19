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

The file itself is the source of truth for this check, not the remote diff.
An earlier version read only the diff's `declared` entries, which cannot see a
declaration whose value already equals production - and that is precisely what
`config pull` produces, since it writes the remote's own values. The widened
file would have diffed clean and sailed through the guard on the one path the
guard exists to stop. The diff is still read, when supplied, to print what
would change.
"""
import os
import sys
import tomllib

# Everything `supabase config push` may write, as a prefix of the flattened
# TOML path. `project_id` names the target rather than configuring it, and
# `functions` is deploy configuration - outside push's scope entirely, which the
# CLI reports as api/auth/database/pooler/realtime/storage.
ALLOWED_PREFIXES = (
    ("auth", "email", "template"),
    ("functions",),
)
ALLOWED_EXACT = {("project_id",)}

CONFIG = "supabase/config.toml"


def _leaves(node, path=()):
    """Every scalar declaration in the file, as a tuple path."""
    if isinstance(node, dict):
        for key, value in node.items():
            yield from _leaves(value, path + (key,))
    else:
        yield path


def _allowed(path):
    return path in ALLOWED_EXACT or any(
        path[: len(prefix)] == prefix for prefix in ALLOWED_PREFIXES
    )


def _missing_template_files(config):
    """Declared content_paths that do not resolve from the working directory.

    The CLI reads these relative to where it runs, which is the repository root
    in the deploy workflow - not relative to config.toml. A path that resolves
    to nothing is not an error to the CLI, and `config diff` compares subjects
    only, so a push would report success and upload no template whatsoever. The
    templates were declared without the supabase/ prefix exactly once, and
    nothing in the pipeline would have said so.
    """
    templates = (
        config.get("auth", {}).get("email", {}).get("template", {})
    )
    for name, block in sorted(templates.items()):
        path = block.get("content_path") if isinstance(block, dict) else None
        if path and not os.path.isfile(path):
            yield name, path


def main() -> int:
    try:
        with open(CONFIG, "rb") as fh:
            config = tomllib.load(fh)
    except OSError as e:
        print(f"::error::could not read {CONFIG}: {e}", file=sys.stderr)
        return 1

    missing = list(_missing_template_files(config))
    for name, path in missing:
        print(
            "::error::auth.email.template.{}.content_path is {!r}, which does "
            "not exist from {}. The CLI resolves it from here and treats a "
            "missing file as nothing to upload, so the push would silently "
            "ship no template.".format(name, path, os.getcwd())
        )

    stray = sorted(p for p in _leaves(config) if not _allowed(p))
    for path in stray:
        print(
            "::error::{} declares {}, which is outside auth.email.template. "
            "Refusing to push - this would change a production auth "
            "setting.".format(CONFIG, ".".join(path))
        )

    # Supplemental: what the remote says would actually change. Absence of a
    # diff entry proves nothing (a declaration matching production produces
    # none), so this never relaxes the verdict above.
    raw = sys.stdin.read().strip() if not sys.stdin.isatty() else ""
    line = next(
        (l for l in reversed(raw.splitlines()) if l.startswith("{")), ""
    )
    if line:
        import json

        for c in json.loads(line).get("changes", []):
            if c.get("declared"):
                print("would change {}: {!r} -> {!r}".format(
                    ".".join(c["path"]), c.get("remote"), c.get("local")))

    if stray or missing:
        return 1
    print(
        "OK - {} declares only email templates, and every content_path "
        "resolves. The settings this project keeps in the dashboard are "
        "undeclared here and stay untouched.".format(CONFIG)
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
