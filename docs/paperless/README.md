# paperless-ngx — taxonomy baseline

A starting taxonomy for `paperless.cyberhawk.no`, plus an idempotent seeder.
Deployment lives in `GitOps/clusters/cyberhawk-talos-k8s/3-apps/paperless/`.

| File | What it is |
|---|---|
| `taxonomy.yaml` | Document types, tags, custom fields, saved views. Generic, no personal data. |
| `correspondents.example.yaml` | Placeholders. The real list lives outside this repo. |
| `seed.py` | Creates/updates the above over the REST API. Dry-run by default. |

## Running it

```bash
export PAPERLESS_TOKEN=...        # paperless -> Settings -> My Profile -> API token
cd docs/paperless

./seed.py                          # show the plan, write nothing
./seed.py --apply                  # write it
./seed.py --correspondents ~/paperless-seed/correspondents.yaml --apply
```

Generate the token while logged in as the account you want to own these objects —
paperless assigns ownership from the token, so seeding as `admin` and then working
as `jochristian@cyberhawk.no` leaves you editing another user's objects.

Re-running is safe. The seeder matches on name, creates what is missing, patches
only the fields `taxonomy.yaml` actually specifies, and **never deletes anything** —
removing an entry from the YAML leaves it untouched in paperless. That means a
typo can add clutter but cannot destroy your filing. Anything you tune in the UI
that the YAML does not mention survives a re-run.

### Saved view visibility is a user preference, not a view property

`show_on_dashboard` / `show_in_sidebar` in `taxonomy.yaml` do not map to fields on
the saved view. Paperless 3.x removed them from the model; API v10 (the default)
neither accepts nor returns them, so sending them is silently ignored. They now
live per-user in
`UiSettings.settings.saved_views.{dashboard,sidebar}_views_visible_ids`, and
`seed.py` applies them there in a separate step.

Two consequences: the placement is **per user**, so a second paperless user gets
the views but not your dashboard layout; and `POST /api/ui_settings/` replaces the
entire settings blob, so the seeder reads-merges-writes rather than posting the two
keys alone. Posting a partial object would wipe every other UI preference you have.

## Why it is shaped this way

**Few, broad document types (13).** Upstream guidance is ~10–15 doing the heavy
lifting alongside correspondents, not 50 narrow ones. "Strømfaktura" is not a type;
it is a `Faktura` carrying the `Strøm` tag. Narrow types fragment into categories
with one document each, and every new bill provokes a naming decision.

**Tags are nested (v2.19+), two levels.** Adding `Strøm` automatically adds its
parent `Bolig`, so you get the rollup without extra clicks. Depth limit is 5;
`seed.py` handles one level and says so loudly if you exceed it.

**Nothing uses `auto` matching.** The docs are explicit about the preconditions:
auto-matching ignores any document still carrying an inbox tag, needs a meaningful
number of positive *and negative* examples, and cannot learn subjective tags like
TODO at all. On an empty install it would confidently mislabel nearly everything,
and — worse — it learns from whatever you let through, so early mistakes compound.
Everything here starts on `any` or `literal`. Revisit at ~100 filed documents.

**No storage paths.** `PAPERLESS_FILENAME_FORMAT` already lays the media tree out
as `{{ created_year }}/{{ correspondent }}/{{ created }}_{{ title }}`, which is what
makes a restore from restic browsable without the database. A storage path
*overrides* that format for the documents it matches, so adding them piecemeal
gives you a media tree with two competing layouts.

**A retention tag axis.** `Oppbevaring > Permanent / 5 år / 1 år` is the one thing
correspondent-and-type does not capture: how long this needs to exist. Paperless
never deletes anything on its own, so these are purely a filter for your own
periodic cleanout. No match rules — nothing in a document's text says how long to
keep it. (Rule of thumb, not legal advice: 5 years is the usual window for
tax-relevant documentation; Permanent is for what is painful to reissue —
vitnemål, skjøte, testament, fødselsattest.)

**Correspondents are not seeded from this repo.** Partly privacy — this repo is
public, and the list names your bank, employer and doctor. Partly that they are
genuinely better grown than seeded: you only want entries for entities you
actually hear from, and twenty guesses gives you twenty correspondents with zero
documents and a match rule you never tuned.

## This is an archive, not a task system

Worth stating plainly, because it decides what belongs here. Bills are paid
elsewhere — AvtaleGiro, nettbank, eFaktura. Paperless exists so a document can be
found again in three years, not so it can remind you of anything.

Consequences, all of them deliberate:

- **No `TODO` tag** and no due-date tracking. A `Forfallsdato` custom field was in
  the first draft and has been removed: a due date only has value while the bill is
  unpaid, which is a job this system does not do.
- **No scheduled workflows.** Paperless can fire a workflow N days before a date
  field. Do not wire one up here; it would turn the archive into a second, worse
  inbox competing with the one that actually pays things.
- **One dashboard view**, the ingest queue. The front page answers "is there
  anything left to file?" and nothing else.
- **`Purringer` is sidebar-only.** As a retrieval filter it earns its place; on the
  dashboard it would be an alarm.
- **Retention tags matter more, not less.** `Oppbevaring` is the archive's own
  lifecycle, and the only axis correspondent-and-type does not capture.

`Innboks` survives all this because it is not a task marker — it is the difference
between "arrived" and "checked and filed". It also does real work: auto-matching
ignores anything still carrying an inbox tag, so the queue is what keeps the
classifier learning from reviewed documents only.

## The filing loop

Seeding the taxonomy is the easy half. The habit is what keeps it findable.

1. New documents arrive tagged `Innboks` automatically.
2. Periodically, work the inbox: check the auto-assigned correspondent and type,
   fix what is wrong, set a title **you would actually search for** (not the
   filename — scanners and billing portals produce things like
   `922177724-arkiv_INVOICE_8032452057`), **verify the date** (paperless guesses it
   from OCR and gets it wrong on bad scans), add a retention tag, remove `Innboks`.
3. Keep the inbox from becoming a pile. Past a few dozen it stops being a queue,
   and the auto-matcher has nothing clean to learn from.

`Uten korrespondent`, `Uten dokumenttype` and `Uten tagger` are the hygiene views
and should trend toward empty. The first two matter most: correspondent and
document type are the axes you will actually search on years later, so a document
missing either is one you will struggle to find again.

Once a year, filter on `Oppbevaring > 1 år` and delete what has aged out. Nothing
does this for you — paperless never deletes on its own, which is the correct
default for an archive.

## Duplicate detection can lose a race

Paperless rejects a re-upload whose checksum already exists, but the check is not
atomic: with `PAPERLESS_TASK_WORKERS: 2`, two byte-identical files consumed at the
same moment can both pass it and both be stored. Seen on the first bulk upload —
two invoices landed twice, identical checksums and identical original filenames.

Worth running occasionally, and after any bulk import:

```sql
select checksum, count(*), string_agg(id::text, ',' order by id)
from documents_document group by checksum having count(*) > 1;
```

Delete the extras **through the UI or API, never in the database** — paperless has
to remove the stored original and the archive rendition alongside the row. UI
deletes go to the trash and are recoverable for `trash_delay` days (30 here).

## Next steps, roughly in order of payoff

- **Tune the match rules.** The strings in `taxonomy.yaml` are educated guesses at
  Norwegian invoice vocabulary. After the first ~50 documents, check what
  auto-assigned wrongly and adjust. This is where the real value is.

  Two traps, both found by the very first real document:

  **Quote multi-word terms.** `any`/`all` split the match on whitespace and search
  each token as `\bword\b`, so an unquoted `vann og avløp` becomes three tokens —
  and the bare `og` matches essentially every Norwegian document. Write
  `"vann og avløp"`. `seed.py` warns on bare stopword tokens before it writes
  anything, but it only knows the words in its `STOPWORDS` set.

  **Not everything arrives in Norwegian.** Travel documents especially: an SAS
  e-ticket is issued entirely in English, and a foreign transit statement may be in
  a third language. `Reise` and `Billett` are therefore bilingual regexes. A
  Norwegian-only word list silently never matches these, and they land in
  `Uten dokumenttype` looking like an oversight rather than a gap.

  **Beware boilerplate vocabulary.** Norwegian invoices carry payment terms like
  "Ved purring beregnes gebyr kr 35,00", so matching the bare word `purring` tags
  ordinary invoices as reminders. Match the inkasso-stage words instead. The same
  logic applies to any word that appears in the small print rather than the
  subject of the document.
- **Mail rules** (`/settings/mail`). Most bills arrive by email and never touch a
  scanner. Bigger practical win than anything scanner-related.
- **ASN + physical binder.** If you keep paper: write an ascending number on each
  sheet before scanning, file by that number only, and never sort the binder any
  other way. Retrieval is then always search → read ASN → grab.
- **Consumption workflows, if anything.** Not *scheduled* ones — see the archive
  note above. A "consumption started" workflow can assign an owner or a tag based
  on which folder a file arrived in, which is useful if you ever ingest from more
  than one source. Reminder-style triggers are out of scope by design.
- **Built-in AI.** 3.x ships its own LLM features (`PAPERLESS_AI_*`): suggestions,
  RAG-backed similar documents, and document chat, with an `ollama` or
  `openai-like` backend. Off by default. This overlaps almost entirely with the
  separate paperless-ai container — evaluate the built-in one first. Note that a
  hosted backend means every document's text leaves the network, and there is no
  Ollama and no GPU node in this cluster today.
