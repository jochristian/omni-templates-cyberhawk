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
    "saved_views": [
        "show_on_dashboard",
        "show_in_sidebar",
        "sort_field",
        "sort_reverse",
        "filter_rules",
    ],
}


class Paperless:
    def __init__(self, base_url: str, token: str, *, apply: bool) -> None:
        self.base = base_url.rstrip("/")
        self.token = token
        self.apply = apply
        self.created = 0
        self.updated = 0
        self.unchanged = 0

    def _request(self, method: str, path: str, body: dict | None = None) -> Any:
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
            page = self._request("GET", url)
            out.extend(page.get("results", []))
            url = page.get("next")
        return out

    def create(self, endpoint: str, payload: dict) -> dict | None:
        if not self.apply:
            self.created += 1
            return None
        obj = self._request("POST", f"/api/{endpoint}/", payload)
        self.created += 1
        return obj

    def patch(self, endpoint: str, obj_id: int, payload: dict) -> dict | None:
        if not self.apply:
            self.updated += 1
            return None
        obj = self._request("PATCH", f"/api/{endpoint}/{obj_id}/", payload)
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
    check_view_references(tax.get("saved_views") or [], tax)
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
    sync(api, "saved_views", views, label="view")

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
