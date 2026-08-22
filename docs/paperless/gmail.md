# Ingesting Gmail into paperless

Most bills and receipts arrive by email and never touch a scanner, so this is the
highest-value ingestion path. The Gmail account already has a label hierarchy that
maps almost directly onto the taxonomy:

| Gmail label | messages (2026-08-22) | rule | imported so far |
|---|---|---|---|
| `_viktig/_Kvitteringer` | 773 | Kvitteringer, enabled, `maximum_age: 365` | 210 |
| `_viktig/_bestilling` | 949 | Bestillinger, enabled, `maximum_age: 30` | 16 |
| `_viktig/_faktura` | 416 | Fakturaer, **disabled — no value** | 0 documents (see below) |
| `_viktig/_billetter` | 147 | Billetter, enabled, `maximum_age: 0` | backfilling |

~2,285 messages in total. Import them in stages, not in one go — see below.

### `_faktura` contains no invoices

Settled 2026-08-22 by a clean run over the whole label: **416 of 416 messages are
eFaktura notifications** — "Melding om eFaktura fra Hafslund Strøm AS", the bank
saying an invoice is waiting in nettbank. No attachment, no invoice. 402 were
skipped as having nothing consumable, and the 14 that did produce documents were
older (2014–2018) notifications in a different format, each landing with no
correspondent and no document type. They were deleted and the rule is now disabled
permanently.

The invoices live in nettbank and never reach this mailbox, so no rule tuning
helps. The grouping is what makes it obvious — the same handful of senders,
monthly, for years:

    15 x  Melding om eFaktura fra 3036 Sameiet ...
    14 x  Melding om eFaktura fra SEB Kort/Circle K MasterCard
    14 x  Melding om eFaktura fra Hafslund Fakturaservice AS
    14 x  Melding om eFaktura fra Volkswagen Møller Bilfinans AS

Worth doing that `group by subject` on any label before concluding a rule is
broken: a label that produces nothing may simply contain nothing.

The labels deliberately no longer map to a document type. That was the original
design and it was wrong: `assign_document_type` on a mail rule *overrides* content
matching rather than seeding it, so every SAS e-ticket landing in `_Kvitteringer`
was typed `Kvittering` and the `Billett` type never got used. A Gmail label records
where you filed a mail, not what the attachment is. See the block comment above
`mail_rules` in `taxonomy.yaml`.

The mail **account** holds an app password, so it is created by hand at
`/settings/mail` and is not in Git. The **rules** contain no secrets and are
seeder-managed: they live in the `mail_rules` block of `taxonomy.yaml`, and
`./seed.py --apply` reconciles them. Editing a seeder-managed field in the web UI
is reverted on the next run — change the YAML instead.

## One-time setup

1. **Google app password.** Go directly to <https://myaccount.google.com/apppasswords>
   — Google removed the link from the Security page, so it is normal not to find it
   by browsing. Generate one for "Mail" and keep it; it is shown once.

   If that page says app passwords are unavailable, it is one of:

   - **2-Step Verification is satisfied only by passkeys or security keys.** This is
     the usual cause now, and Google documents it explicitly. App passwords require a
     "traditional" second factor to exist on the account — add an authenticator app
     or a phone number as a 2SV method and the page appears. The passkey keeps
     working; it is just no longer the *only* method.
   - **Advanced Protection Program enrolment**, which blocks app passwords outright
     and permanently. There is no workaround; use OAuth instead.
   - On a Workspace account (not this one — this is a consumer gmail.com address),
     an admin-console policy under Security → Authentication → 2-Step Verification.

   IMAP itself needs no cluster changes: the CiliumNetworkPolicy in
   `3-apps/paperless/50-networkpolicies.yaml` already allows egress on 993.

2. **Add the account** in paperless → Settings → Mail → Accounts:

   | field | value |
   |---|---|
   | IMAP server | `imap.gmail.com` |
   | IMAP port | `993` |
   | Security | SSL |
   | Username | the full Gmail address |
   | Password | the app password (not the account password) |

   Use "Test" before saving.

## Rule settings that actually matter

The defaults are wrong for this account in three specific ways. Each fails
**silently** — no error, just missing documents.

| field | set to | why |
|---|---|---|
| Folder | `_viktig/_Kvitteringer` | Gmail exposes nested labels as IMAP folders with `/` as the separator. Case matters: the label is `_Kvitteringer`, capital K. |
| Maximum age | `30` at first, `0` later | **Defaults to 30 days.** Left alone, a "full import" quietly grabs only the last month. |
| Action | **Tag mail**, keyword e.g. `paperless` | See below. Do not leave this on "Mark as read". |
| Consumption scope | `.eml + attachments` **for the first run** | Many receipts are HTML-only with no attachment, so "attachments only" skips them entirely. But `.eml + attachments` produces *two* documents for a receipt that came as a PDF — the rendered email and the PDF. Use it for the staged run to learn which shape your mail actually is, then settle on `.eml only` or `attachments only` accordingly. |
| Attachment type | **Only process attachments** | The alternative includes *inline* attachments, which turns every company logo and email-signature image into its own document. |
| Exclude filenames | `*.png,*.gif,*.jpg,*.svg,Generelle_vilkar*,Angrerett*,*vilkår*,*Vilkar*` | Image junk, plus the boilerplate PDFs (generelle vilkår, angrerettskjema) that every Norwegian order confirmation carries by law. They are byte-identical every time and say nothing about the purchase. |
| Title from | Subject | The alternative is the attachment filename, which produces things like `922177724-arkiv_INVOICE_8033896133`. |
| Assign correspondent from | **None** | "Name" sounds right but falls back to the mail address when the sender has no display name — the first import produced correspondents called `noreply@posten.no` and `GastroPlanner Order`. Derive it from document content instead, via the literal match rules in the correspondents file. |
| Assign document type | **leave unset** | It is an override, not a default, and it beats every content rule you have written. See the note under the label table. |
| Stop processing | **on**, for every rule but the last | The only thing that stops one message being consumed by two rules. See below. |

### Why not "Mark as read"

Every rule action doubles as the "already handled" marker, and each one skips mail
it considers handled:

- **Mark as read** — skips mail that is *already read*, including mail you read
  yourself long before paperless existed. 405 of the 773 receipts are already read,
  so this would silently import barely half of them.
- **Flag** — maps to Gmail's star. Works, but you would end up with thousands of
  starred messages.
- **Move** — moves mail out of the label, destroying the organisation this depends on.
- **Delete** — no.
- **Tag** — an IMAP keyword, which Gmail stores as an ordinary label. Independent of
  read state, non-destructive, and visible in Gmail so you can see what was consumed.

Paperless *also* tracks processed mail by IMAP UID (Mail → Processed Mails), so
tagging is belt-and-braces. To deliberately re-import a message, delete its
Processed Mail entry.

## Staged rollout

Do not point a rule at everything on day one. A wrong setting discovered after
3,000 documents have been OCR'd is expensive to undo, and every one of them lands
in `Innboks`, burying whatever is already there.

**Check the age spread before choosing a window.** These labels are not evenly
distributed and the 30-day default can make a label look empty when it is not.
`_billetter` holds 147 messages but only 31 within a year and 2 within 30 days, so
the default window would have imported almost nothing and looked like a broken
rule. Counting first also sizes the batch against the connection ceiling:

```bash
kubectl -n paperless exec deploy/paperless -- python3 manage.py shell -c "
from paperless_mail.models import MailAccount
from paperless_mail.mail import get_mailbox, mailbox_login
from datetime import date, timedelta
a = MailAccount.objects.first()
with get_mailbox(a.imap_server, a.imap_port, a.imap_security) as M:
    mailbox_login(M, a)
    M.folder.set('_viktig/_billetter')
    msgs = list(M.fetch(mark_seen=False, headers_only=True, bulk=True))
    print('total', len(msgs))
    for d in (30, 90, 365):
        print(d, sum(1 for m in msgs if m.date and m.date.date() > date.today()-timedelta(days=d)))"
```

1. **`_Kvitteringer`, maximum age 30.** Tens of documents. Check: is the OCR
   readable, are the subjects usable as titles, did the content rules pick a
   sensible document type and correspondent, and is anything obviously duplicated?
2. Fix whatever that reveals — most likely the match rules in `taxonomy.yaml`,
   since content matching is now what assigns type and correspondent.
3. **Widen to maximum age 0** on that one rule and let the full 773 run through.
4. **Add the other three labels** as separate rules, one at a time.

Between stages, apply any rule changes to what is already imported — match rules
only run at consume time, so editing a regex does nothing to the existing archive
until you re-run the matcher:

```bash
# preview, writes nothing
kubectl -n paperless exec deploy/paperless -- \
  python3 manage.py document_retagger --tags --document_type --correspondent --suggest

# apply. --use-first resolves ties for the single-valued fields
kubectl -n paperless exec deploy/paperless -- \
  python3 manage.py document_retagger --correspondent --use-first
```

`--tags` only ever *adds* tags; it cannot remove one a bad rule already applied.
Avoid `--overwrite` unless you mean to re-evaluate the type of every document in
the archive at once.

### A bulk import can exhaust the Postgres connection pool

A backfill can exhaust the pool, but **check what is actually consuming the
connections before blaming volume**. The `_faktura` backfill hit ~95 connections
against a `max_connections` of 100 and that was read as ingestion concurrency. It
was not: the same label re-run cleanly afterwards peaked at **5**. The difference
was that the first run was failing on every mail, and it was the failure/retry
churn — not the ingestion — that consumed the pool. Fixing the underlying error
removed the pressure entirely.

`max_connections` is nonetheless pinned to 200 in `10-cnpg-cluster.yaml`, because
headroom is cheap and the memory limit was raised alongside it. Just do not assume
a connection spike means you need a bigger ceiling; it more often means something
is failing in a loop. The error to look for:

    FATAL: remaining connection slots are reserved for roles with the SUPERUSER attribute

That reads like an authentication failure and is not one. The API starts returning
500s at the same time. `10-cnpg-cluster.yaml` now pins `max_connections: "200"`
(with the memory limit raised to match — 200 backends are 200 processes).

Check before and during a large import:

```bash
kubectl -n paperless exec paperless-db-1 -- psql -U postgres \
  -c "select state, count(*) from pg_stat_activity where usename='paperless' group by 1;"
```

To attribute a spike, group by `backend_start`, **not** `state_change` —
`state_change` on an idle connection is the last time it went idle, so
`max(now()-state_change)` looks like connection age and is not. That misreading
turned a one-hour spike into an apparent five-day leak during this incident:

```bash
kubectl -n paperless exec paperless-db-1 -- psql -U postgres \
  -c "select date_trunc('hour',backend_start), count(*) from pg_stat_activity
      where usename='paperless' group by 1 order by 1 desc;"
```

Paperless does not release the connections promptly once they are idle, so the
count stays high until either the app or the database restarts.

### Never trigger `mail_fetcher` by hand as root

`kubectl exec` runs as **uid 0**. Paperless's own services run as uid 1000 under
s6. So a hand-triggered fetch writes its scratch files as `root:root` mode `0600`:

    -rw-------. 1 root      root       paperless-mail-0_slo6jc.eml   <- kubectl exec
    drwx------. 2 paperless paperless  paperless-mail-03ck0syu       <- scheduled task

The fetch itself succeeds. The *consume* tasks then run as uid 1000, cannot read
what root wrote, and every one of them dies with:

    PermissionError: [Errno 13] Permission denied: '/tmp/paperless/paperless-mail-XXXXXXXX.eml'

This cost two entire backfills — 234 mails marked FAILED across `_faktura` and
`_billetter`, with zero documents produced and no obvious cause, because the error
surfaces as a celery `ChordError` in the `ProcessedMail` row and the real traceback
is only in the pod log. The same mechanism also makes `data/log/paperless.log`
unwritable once a root process has rotated it, which spams the log with secondary
`--- Logging error ---` tracebacks that distract from the real one.

**Just let the scheduled task do it** — `PAPERLESS_EMAIL_TASK_CRON` fires every 10
minutes, which is soon enough for any backfill. If you genuinely need it now:

```bash
kubectl -n paperless exec deploy/paperless -- \
  runuser -u paperless -- python3 manage.py mail_fetcher
```

`kubectl exec` has **no** `-u`/`--user` flag — the uid is fixed by the pod spec, so
dropping privileges has to happen inside the container. `runuser`, `setpriv`, `su`
and `gosu` are all present in this image.

To repair the damage afterwards:

```bash
kubectl -n paperless exec deploy/paperless -- bash -c '
  chown -R paperless:paperless /tmp/paperless
  chown paperless:paperless /usr/src/paperless/data/log/paperless.log'
```

Queued-but-unstarted consume tasks recover on their own once ownership is fixed —
93 documents landed by themselves over the following half hour, long after the
`mail_fetcher` command had exited. Two consequences worth planning for: the
recovery is asynchronous, so a document count taken right after the chown is not
final; and those late tasks write **fresh** `ProcessedMail` rows marked SUCCESS,
which will silently re-protect mails you thought you had reset. Drain or purge the
queue before cleaning up:

```bash
kubectl -n paperless exec deploy/paperless -- \
  runuser -u paperless -- celery -A paperless purge -f
```

Note the broker queue and the `documents_paperlesstask` table disagree: the table
kept 183 rows at `pending` after the broker reported only 27 messages purged.
Trust the broker.

### Resetting a rule after a failed backfill

`ProcessedMail` is the only thing standing between a rule and its whole label, so
deleting rows re-opens those mails. Check what a rule actually produced first:

```bash
kubectl -n paperless exec paperless-db-1 -- psql -U postgres -d paperless -c "
select r.name, p.status, count(*) from paperless_mail_processedmail p
join paperless_mail_mailrule r on r.id=p.rule_id group by 1,2 order by 1,3 desc;"
```

- **SUCCESS = 0** for the rule → safe to delete *all* its rows and start the label
  over; there is nothing to duplicate.
- **SUCCESS > 0** → delete only `status='FAILED'`, or you will re-import documents
  you already have. Paperless dedupes on checksum, but `.eml` bodies differ subtly
  between fetches, so do not rely on it.

Classify the failures before deciding — do not read one row and generalise:

```bash
kubectl -n paperless exec paperless-db-1 -- psql -U postgres -d paperless -c "
select r.name,
       case when p.error like '%remaining connection slots%' then 'db_connection_limit'
            when p.error like '%PermissionError%' then 'permission_denied'
            else 'other' end as kind, count(*)
from paperless_mail_processedmail p join paperless_mail_mailrule r on r.id=p.rule_id
where p.status='FAILED' group by 1,2 order by 1,3 desc;"
```

### Retrying mails that failed to consume

A `ProcessedMail` row marks a message as handled regardless of whether it produced
a document, so a failed mail is never retried on its own. Delete the failed rows
and the next fetch picks them up:

```bash
kubectl -n paperless exec deploy/paperless -- python3 manage.py shell -c "
from paperless_mail.models import ProcessedMail
qs = ProcessedMail.objects.filter(rule__name='Fakturaer', status='FAILED')
print('deleting', qs.count()); qs.delete()"
```

Do not clear `PROCESSED_WO_CONSUMPTION` rows the same way — that status is usually
correct rather than a failure. Most of `_viktig/_faktura` is eFaktura
*notifications* ("Melding om eFaktura fra Hafslund Strøm AS"), which announce that
an invoice is waiting in nettbank and carry no attachment. 181 of the first 209
mails were these. Skipping them is right; consuming them would add 181 documents
containing no invoice.

Watch the first big run: OCR is CPU-only on this cluster, `PAPERLESS_TASK_WORKERS`
is 2, and the media volume is 50 Gi. Check `kubectl -n paperless exec deploy/paperless
-- df -h /usr/src/paperless/media` before and after step 3.

Fetch frequency is `PAPERLESS_EMAIL_TASK_CRON`, default every 10 minutes. To run a
fetch immediately instead of waiting for it:

```bash
kubectl -n paperless exec deploy/paperless -- python3 manage.py mail_fetcher
```

Note the name — it is `mail_fetcher`, not `mail_fetch`. The wrong name exits 1 with
"Unknown command", which is easy to miss if you are watching the document count
rather than the command output, because the scheduled fetch keeps trickling
documents in regardless and it looks like your run did something.

`mail_fetcher` only queues the consume tasks; OCR then runs asynchronously on the
celery workers, so the document count keeps climbing long after the command exits.

## Gmail-specific gotchas

- **Never point a rule at `[Gmail]/All Mail`.** It contains the entire mailbox,
  including spam and sent items.
- **A Gmail message carrying two labels is consumed once per matching rule.** It
  appears in both IMAP folders, and — contrary to what this file said until
  2026-08-22 — the Processed Mail record does **not** stop the second rule. That
  record is keyed per `(rule, uid, folder)`, so a second rule has its own key and
  imports the message again.

  Observed on 2026-08-19/20: one Google Play receipt and one Folketeateret order
  confirmation, each labelled both `_Kvitteringer` and `_bestilling`, produced two
  sets of documents. Ordering the rules did nothing to prevent it.

  The fix is `stop_processing` on every rule but the last, which is what makes
  "lowest order number wins" actually true. Combined with `consumption_scope: 3`
  (`.eml` + attachments), the un-fixed version is expensive: one Altibox mail
  became **six** documents.

- **Gmail can re-offer a message you already consumed.** Applying the `paperless`
  label — which is what `action: 5` does — can change the message's UID within a
  label's mailbox, and the Processed Mail key includes that UID. The same Altibox
  mail was consumed by the same rule at 12:20 and again at 12:30. Worth watching
  the first few consumes after any rule change; `Mail → Processed Mails` shows two
  rows with the same subject when it happens.

- **Check for duplicates after every bulk import**, before enabling the next rule.
  The checksum query in `README.md` catches byte-identical pairs; near-duplicates
  from the two mechanisms above are not byte-identical and need an eye on
  `Sist lagt til`.
- Labels with æ/ø/å become modified UTF-7 over IMAP and are worth avoiding as rule
  folders. The four labels here are ASCII, so this is not currently an issue.
