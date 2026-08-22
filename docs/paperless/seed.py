#!/usr/bin/env python3
"""Seed the paperless-ngx taxonomy from taxonomy.yaml.

Idempotent: matches existing objects by name, creates what is missing and patches
what has drifted. Safe to re-run after editing the YAML.

Dry-run is the default. Nothing is written until you pass --apply.

    export PAPERLESS_TOKEN=...            # Settings -> My Profile -> API token
    ./seed.py                             # show the plan
    ./seed.py --apply                     # write it
    ./seed.py --correspondents ~/paperless-seed/correspondents.yaml --apply

Only taxonomy objects are touched (tags, document types, custom fields, storage
paths, saved views, correspondents). Documents are never read, modified or
deleted, and nothing is ever removed — entries dropped from the YAML are left
alone in paperless rather than deleted, so a typo cannot destroy anything.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any

import yaml

DEFAULT_URL = "https://paperless.cyberhawk.no"

# Fields compared when deciding whether an existing object has drifted. Anything
# not listed is left alone, so hand-tuning something in the UI that the YAML does
# not describe survives a re-run.
COMPARE = {
    "tags": ["color", "is_inbox_tag", "matching_algorithm", "match", "parent"],
    "document_types": ["matching_algorithm", "match"],
    "correspondents": ["matching_algorithm", "match"],
    "storage_paths": ["path", "matching_algorithm", "match"],
    "custom_fields": ["data_type"],
    # show_on_dashboard / show_in_sidebar are deliberately absent. They are no
    # longer fields on SavedView: as of API v10 (the default in 3.x) they are
    # neither accepted on write nor returned on read, so including them here
    # produced a permanent no-op update loop — every run reported the same six
    # views as drifted (None -> True) and changed nothing. Their real home is
    # per-user UiSettings; see sync_view_visibility().
    "saved_views": ["sort_field", "sort_reverse", "filter_rules"],
    "mail_rules": [
        "account",
        "enabled",
        "order",
        "folder",
        "maximum_age",
        "action",
        "action_parameter",
        "consumption_scope",
        "attachment_type",
        "filter_attachment_filename_exclude",
        "assign_title_from",
        "assign_correspondent_from",
        "assign_document_type",
        "assign_tags",
        # Gmail labels are not exclusive, and the Processed Mail record is keyed
        # per (rule, uid, folder) — so it does NOT stop a second rule consuming
        # the same message. Only stop_processing does. Managed here because
        # getting it wrong silently doubles documents rather than erroring.
        "stop_processing",
    ],
}

# Keys the ui_settings GET injects server-side on every read. They are not real
# stored preferences, so they must not be written back.
UI_SETTINGS_READONLY = frozenset(
    {"trash_delay", "version", "app_title", "app_logo", "auditlog_enabled"}
)


class Paperless:
    def __init__(self, base_url: str, token: str, *, apply: bool) -> None:
        self.base = base_url.rstrip("/")
        self.token = token
        self.apply = apply
        self.created = 0
        self.updated = 0
        self.unchanged = 0

    def request(self, method: str, path: str, body: dict | None = None) -> Any:
        url = path if path.startswith("http") else f"{self.base}{path}"
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(url, data=data, method=method)
        req.add_header("Authorization", f"Token {self.token}")
        req.add_header("Accept", "application/json")
        if data:
            req.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                raw = resp.read()
                return json.loads(raw) if raw else None
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode(errors="replace")[:600]
            raise SystemExit(
                f"\n{method} {url} failed: HTTP {exc.code}\n{detail}\n"
            ) from exc
        except urllib.error.URLError as exc:
            raise SystemExit(f"\nCannot reach {url}: {exc.reason}\n") from exc

    def list_all(self, endpoint: str) -> list[dict]:
        """Page through a list endpoint and return every result."""
        out: list[dict] = []
        url = f"{self.base}/api/{endpoint}/?page_size=250"
        while url:
            page = self.request("GET", url)
            out.extend(page.get("results", []))
            url = page.get("next")
        return out

    def create(self, endpoint: str, payload: dict) -> dict | None:
        if not self.apply:
            self.created += 1
            return None
        obj = self.request("POST", f"/api/{endpoint}/", payload)
        self.created += 1
        return obj

    def patch(self, endpoint: str, obj_id: int, payload: dict) -> dict | None:
        if not self.apply:
            self.updated += 1
            return None
        obj = self.request("PATCH", f"/api/{endpoint}/{obj_id}/", payload)
        self.updated += 1
        return obj


def drift(existing: dict, desired: dict, fields: list[str]) -> dict:
    """Return the subset of `desired` that differs from `existing`."""
    out = {}
    for key in fields:
        if key not in desired:
            continue
        if existing.get(key) != desired[key]:
            out[key] = desired[key]
    return out


def sync(
    api: Paperless,
    endpoint: str,
    desired_items: list[dict],
    *,
    label: str,
) -> dict[str, int]:
    """Create-or-update each item, keyed by name. Returns a name -> id map."""
    existing = {o["name"]: o for o in api.list_all(endpoint)}
    ids: dict[str, int] = {n: o["id"] for n, o in existing.items()}
    fields = COMPARE[endpoint]

    for item in desired_items:
        name = item["name"]
        current = existing.get(name)
        if current is None:
            print(f"  + {label}: {name}")
            obj = api.create(endpoint, item)
            if obj:
                ids[name] = obj["id"]
            continue

        changes = drift(current, item, fields)
        if changes:
            summary = ", ".join(
                f"{k}: {current.get(k)!r} -> {v!r}" for k, v in changes.items()
            )
            print(f"  ~ {label}: {name}  ({summary})")
            api.patch(endpoint, current["id"], changes)
        else:
            api.unchanged += 1
    return ids


def resolve_mail_rules(
    api: Paperless, rules: list[dict], type_ids: dict, tag_ids: dict
) -> list[dict]:
    """Turn the by-name references in mail_rules into the ids the API expects.

    The mail ACCOUNT is not managed here — it holds an app password and is created
    by hand in the UI. Rules reference it by name, so a missing account is a clear
    error rather than a silently broken rule.
    """
    if not rules:
        return []
    accounts = {a["name"]: a["id"] for a in api.list_all("mail_accounts")}
    out = []
    for rule in rules:
        payload = dict(rule)
        account = payload["account"]
        if account not in accounts:
            raise SystemExit(
                f"Mail rule {payload['name']!r} references account {account!r}, "
                f"which does not exist. Known accounts: {sorted(accounts) or 'none'}. "
                "Create it in paperless under Settings -> Mail; it holds a "
                "credential and is deliberately not managed by this script."
            )
        payload["account"] = accounts[account]

        # `assign_document_type: null` is meaningful and must survive to the
        # PATCH: it is how a rule stops overriding content-based type matching.
        # Leaving the key out of the YAML instead would make drift() skip the
        # field and silently keep whatever is already live.
        doc_type = payload.get("assign_document_type")
        if doc_type is not None:
            if doc_type not in type_ids:
                raise SystemExit(
                    f"Mail rule {payload['name']!r} assigns document type "
                    f"{doc_type!r}, which is not in the taxonomy."
                )
            payload["assign_document_type"] = type_ids[doc_type]

        # Same for `assign_tags: []` — an empty list clears the rule's tags,
        # whereas an absent key leaves them alone.
        tags = payload.get("assign_tags")
        if tags:
            missing = [t for t in tags if t not in tag_ids]
            if missing:
                raise SystemExit(
                    f"Mail rule {payload['name']!r} assigns unknown tag(s): {missing}"
                )
            payload["assign_tags"] = [tag_ids[t] for t in tags]
        out.append(payload)
    return out


def sync_view_visibility(
    api: Paperless, views: list[dict], view_ids: dict[str, int]
) -> None:
    """Place saved views on the dashboard / in the sidebar.

    In paperless 3.x this is a per-user UI preference, not a property of the view:
    UiSettings.settings["saved_views"]["dashboard_views_visible_ids"] (and the
    sidebar equivalent) hold lists of saved-view ids.

    POST /api/ui_settings/ does update_or_create on the whole settings blob, so
    this reads, merges and writes back rather than posting the two keys alone —
    posting a partial object would wipe every other UI preference.
    """
    wanted_dash, wanted_side = set(), set()
    for view in views:
        vid = view_ids.get(view["name"])
        if vid is None:  # dry run: the view was never created
            continue
        if view.get("show_on_dashboard"):
            wanted_dash.add(vid)
        if view.get("show_in_sidebar"):
            wanted_side.add(vid)

    # GET returns a WRAPPER — {"user": ..., "settings": {...}, "permissions": [...]} —
    # not the preferences themselves. POST, by contrast, takes {"settings": {...}}
    # and overwrites the stored blob wholesale. Writing back what GET returned
    # verbatim therefore buries every real preference one level deep under a
    # "settings" key the frontend does not read, and leaves the user object and
    # the permission list stranded in the preferences blob. Unwrap first.
    current = (api.request("GET", "/api/ui_settings/") or {}).get("settings") or {}
    settings_blob = {k: v for k, v in current.items() if k not in UI_SETTINGS_READONLY}
    saved = dict(settings_blob.get("saved_views") or {})

    have_dash = set(saved.get("dashboard_views_visible_ids") or [])
    have_side = set(saved.get("sidebar_views_visible_ids") or [])
    if have_dash == wanted_dash and have_side == wanted_side:
        api.unchanged += 1
        return

    print(
        f"  ~ visibility: dashboard {sorted(have_dash)} -> {sorted(wanted_dash)}, "
        f"sidebar {sorted(have_side)} -> {sorted(wanted_side)}"
    )
    if not api.apply:
        api.updated += 1
        return

    saved["dashboard_views_visible_ids"] = sorted(wanted_dash)
    saved["sidebar_views_visible_ids"] = sorted(wanted_side)
    settings_blob["saved_views"] = saved
    api.request("POST", "/api/ui_settings/", {"settings": settings_blob})
    api.updated += 1


def order_tags(tags: list[dict]) -> tuple[list[dict], list[dict]]:
    """Split into (roots, children) and validate that every parent exists.

    Only one level of nesting is handled here, which is all this taxonomy uses.
    Paperless allows up to 5; going deeper would need a topological sort.
    """
    roots = [t for t in tags if not t.get("parent")]
    children = [t for t in tags if t.get("parent")]
    unknown = {c["parent"] for c in children} - {t["name"] for t in tags}
    if unknown:
        raise SystemExit(f"Tag parent(s) not defined in taxonomy: {sorted(unknown)}")
    nested_parents = {c["parent"] for c in children} & {c["name"] for c in children}
    if nested_parents:
        raise SystemExit(
            f"Tags nested more than one level deep: {sorted(nested_parents)}. "
            "seed.py handles a single level; add a topological sort for more."
        )
    return roots, children


def resolve_rule_value(
    value: Any, tag_ids: dict, type_ids: dict, *, strict: bool
) -> Any:
    """Turn @tag:Name / @document_type:Name placeholders into real ids.

    Saved view rules reference other objects by primary key, which is not knowable
    until those objects exist — hence the indirection in the YAML.

    In dry-run the referenced objects have not been created yet, so `strict` is
    off and unresolved references pass through as-is. They are still checked
    against the taxonomy for typos before we ever get here.
    """
    if not isinstance(value, str):
        return value
    for prefix, table, what in (
        ("@tag:", tag_ids, "tag"),
        ("@document_type:", type_ids, "document type"),
    ):
        if value.startswith(prefix):
            name = value[len(prefix) :]
            if name in table:
                return str(table[name])
            if strict:
                raise SystemExit(
                    f"Saved view references {what} {name!r}, which does not exist."
                )
            return f"<{what}:{name}>"
    return value


# Very common Norwegian words. As a bare token in an `any`/`all` match these
# match almost every document, because paperless splits the match on whitespace
# and searches each token as \bword\b — an unquoted "vann og avløp" becomes three
# tokens, and `og` alone tags everything. Multi-word terms must be "quoted".
STOPWORDS = {
    "og", "i", "på", "av", "til", "for", "med", "en", "et", "som", "er", "den",
    "det", "de", "har", "kan", "skal", "ved", "om", "at", "fra", "eller", "ikke",
    "over", "under", "mot", "nr", "per", "pr", "du", "vi", "jeg", "alle", "hver",
    "kr", "the", "and", "of", "to",
}

# Mirrors documents/matching.py::_split_match — quoted groups stay together.
_SPLIT_MATCH = re.compile(r'"([^"]+)"|(\S+)').findall


def lint_matches(tax: dict) -> list[str]:
    """Warn about match tokens that will fire on nearly every document."""
    problems = []
    for section in ("document_types", "tags", "correspondents"):
        for item in tax.get(section) or []:
            # Only any(1)/all(2) tokenise; literal/regex/fuzzy are matched whole.
            if item.get("matching_algorithm") not in (1, 2):
                continue
            for group in _SPLIT_MATCH(item.get("match") or ""):
                token = (group[0] or group[1]).strip()
                if token.lower() in STOPWORDS:
                    problems.append(
                        f"{item['name']!r}: bare token {token!r} is a stopword and "
                        f"will match nearly every document — quote the phrase"
                    )
    return problems


def check_no_auto_matching(tax: dict) -> None:
    """Refuse to write matching_algorithm 6 (auto).

    Hard error rather than a warning, because the failure mode is quiet and
    retrospective. Auto-matching learns from whatever is already filed, and it
    ignores anything still carrying an inbox tag — so on a young archive it
    trains on almost nothing and then labels everything with high confidence.

    Two `auto` tags added by hand in the UI on 2026-08-17 were applied to every
    document consumed over the following four days, across unrelated senders.
    Nothing warns you: the tags simply appear, and they keep appearing until the
    matching algorithm is changed and the classifier pickle is deleted.
    """
    offenders = [
        f"{section[:-1]} {item['name']!r}"
        for section in ("document_types", "tags", "correspondents", "storage_paths")
        for item in tax.get(section) or []
        if item.get("matching_algorithm") == 6
    ]
    if offenders:
        raise SystemExit(
            "matching_algorithm 6 (auto) is not allowed in this taxonomy:\n  "
            + "\n  ".join(offenders)
            + "\n\nSee the 'auto matching' section of README.md. Use 1 (any), "
            "3 (literal) or 4 (regex) instead."
        )


def check_view_references(views: list[dict], tax: dict) -> None:
    """Catch typos in @tag:/@document_type: references before touching the API."""
    known = {
        "@tag:": {t["name"] for t in tax.get("tags") or []},
        "@document_type:": {d["name"] for d in tax.get("document_types") or []},
    }
    for view in views:
        for rule in view.get("rules") or []:
            value = rule.get("value")
            if not isinstance(value, str):
                continue
            for prefix, names in known.items():
                if value.startswith(prefix) and value[len(prefix) :] not in names:
                    raise SystemExit(
                        f"Saved view {view['name']!r} references "
                        f"{value!r}, which is not defined in the taxonomy."
                    )


def main() -> int:
    here = Path(__file__).resolve().parent
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--url", default=os.environ.get("PAPERLESS_URL", DEFAULT_URL))
    ap.add_argument("--taxonomy", type=Path, default=here / "taxonomy.yaml")
    ap.add_argument(
        "--correspondents",
        type=Path,
        help="Optional correspondents YAML, kept outside this repo.",
    )
    ap.add_argument(
        "--apply",
        action="store_true",
        help="Actually write. Without this, only the plan is printed.",
    )
    args = ap.parse_args()

    token = os.environ.get("PAPERLESS_TOKEN")
    if not token:
        print(
            "PAPERLESS_TOKEN is not set.\n"
            "Generate one in paperless under Settings -> My Profile -> API token,\n"
            "then: export PAPERLESS_TOKEN=...",
            file=sys.stderr,
        )
        return 2

    tax = yaml.safe_load(args.taxonomy.read_text(encoding="utf-8")) or {}
    check_no_auto_matching(tax)
    check_view_references(tax.get("saved_views") or [], tax)

    for problem in lint_matches(tax):
        print(f"WARNING  {problem}", file=sys.stderr)

    api = Paperless(args.url, token, apply=args.apply)

    mode = "APPLY" if args.apply else "DRY RUN (nothing will be written)"
    print(f"\npaperless-ngx taxonomy seed — {args.url}  [{mode}]\n")

    # --- Document types -----------------------------------------------------
    print("Document types")
    type_ids = sync(
        api, "document_types", tax.get("document_types") or [], label="type"
    )

    # --- Tags ---------------------------------------------------------------
    # Two passes: roots first so that every child's parent id exists by the time
    # the children are written. order_tags() also validates that no child names a
    # parent that is missing from the taxonomy.
    print("\nTags")
    roots, children = order_tags(tax.get("tags") or [])
    tag_ids = sync(api, "tags", roots, label="tag")
    if children:
        tag_ids = {o["name"]: o["id"] for o in api.list_all("tags")}
        resolved = []
        for child in children:
            payload = dict(child)
            parent = payload.pop("parent")
            if parent not in tag_ids:
                if api.apply:
                    raise SystemExit(f"Parent tag {parent!r} missing after creation.")
                # Dry run: the parent was never actually created. Report the
                # child anyway rather than silently dropping it from the plan.
                print(f"  + tag: {payload['name']}  (child of {parent})")
                api.created += 1
                continue
            payload["parent"] = tag_ids[parent]
            resolved.append(payload)
        if resolved:
            tag_ids.update(sync(api, "tags", resolved, label="tag"))

    # --- Custom fields ------------------------------------------------------
    print("\nCustom fields")
    sync(api, "custom_fields", tax.get("custom_fields") or [], label="field")

    # --- Storage paths ------------------------------------------------------
    storage = tax.get("storage_paths") or []
    if storage:
        print("\nStorage paths")
        sync(api, "storage_paths", storage, label="path")

    # --- Correspondents (optional, external file) ---------------------------
    if args.correspondents:
        print("\nCorrespondents")
        data = yaml.safe_load(args.correspondents.read_text(encoding="utf-8")) or {}
        # The out-of-repo file gets the same guard; it is edited by hand too.
        check_no_auto_matching(data)
        sync(
            api,
            "correspondents",
            data.get("correspondents") or [],
            label="correspondent",
        )

    # --- Saved views --------------------------------------------------------
    print("\nSaved views")
    views = []
    for view in tax.get("saved_views") or []:
        payload = dict(view)
        rules = payload.pop("rules", []) or []
        payload["filter_rules"] = [
            {
                "rule_type": r["rule_type"],
                "value": resolve_rule_value(
                    r.get("value"), tag_ids, type_ids, strict=api.apply
                ),
            }
            for r in rules
        ]
        views.append(payload)

    # Strip the visibility flags from what goes to /api/saved_views/ — the v10
    # API ignores them. They are applied separately, against UiSettings.
    view_ids = sync(
        api,
        "saved_views",
        [
            {k: v for k, v in p.items() if k not in ("show_on_dashboard", "show_in_sidebar")}
            for p in views
        ],
        label="view",
    )
    sync_view_visibility(api, views, view_ids)

    # --- Mail rules ---------------------------------------------------------
    mail_rules = tax.get("mail_rules") or []
    if mail_rules:
        print("\nMail rules")
        if api.apply:
            sync(
                api,
                "mail_rules",
                resolve_mail_rules(api, mail_rules, type_ids, tag_ids),
                label="rule",
            )
        else:
            # Dry run: the referenced types/tags may not exist yet, so their ids
            # cannot be resolved. Report intent rather than fail on the
            # chicken-and-egg.
            for rule in mail_rules:
                state = "enabled" if rule.get("enabled") else "disabled"
                print(f"  + rule: {rule['name']}  ({rule['folder']}, {state})")
                api.created += 1

    print(
        f"\n{'Created' if api.apply else 'Would create'}: {api.created}   "
        f"{'Updated' if api.apply else 'Would update'}: {api.updated}   "
        f"Unchanged: {api.unchanged}"
    )
    if not api.apply:
        print("\nDry run only. Re-run with --apply to write these changes.\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
