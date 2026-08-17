# Ingesting Gmail into paperless

Most bills and receipts arrive by email and never touch a scanner, so this is the
highest-value ingestion path. The Gmail account already has a label hierarchy that
maps almost directly onto the taxonomy:

| Gmail label | messages (2026-08-17) | maps to |
|---|---|---|
| `_viktig/_Kvitteringer` | 769 | document type `Kvittering` |
| `_viktig/_bestilling` | 945 | document type `Ordrebekreftelse` |
| `_viktig/_faktura` | 416 | document type `Faktura` |
| `_viktig/_billetter` | 146 | document type `Billett` + tag `Reise` |

~2,276 messages in total. Import them in stages, not in one go — see below.

Mail accounts and rules live in the paperless database and are configured through
the web UI at `/settings/mail`. They are **not** in Git, the same as correspondents.

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
| Exclude filenames | `*.png,*.gif,*.jpg,*.svg` | Belt and braces against image junk, and harmless if the above is set correctly. |
| Title from | Subject | The alternative is the attachment filename, which produces things like `922177724-arkiv_INVOICE_8033896133`. |
| Assign correspondent from | Name | Uses the sender's display name and creates correspondents automatically. |
| Assign document type | per the table above | |

### Why not "Mark as read"

Every rule action doubles as the "already handled" marker, and each one skips mail
it considers handled:

- **Mark as read** — skips mail that is *already read*, including mail you read
  yourself long before paperless existed. 405 of the 769 receipts are already read,
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

1. **`_Kvitteringer`, maximum age 30.** Tens of documents. Check: is the OCR
   readable, are the subjects usable as titles, are the auto-created correspondents
   sane, did the `Kvittering` type stick?
2. Fix whatever that reveals — most likely correspondent naming, since sender
   display names are inconsistent ("Elkjøp" vs "Elkjøp Nordic AS via nettbutikk").
3. **Widen to maximum age 0** on that one rule and let the 769 run through.
4. **Add the other three labels** as separate rules, one at a time.

Watch the first big run: OCR is CPU-only on this cluster, `PAPERLESS_TASK_WORKERS`
is 2, and the media volume is 50 Gi. Check `kubectl -n paperless exec deploy/paperless
-- df -h /usr/src/paperless/media` before and after step 3.

Fetch frequency is `PAPERLESS_EMAIL_TASK_CRON`, default every 10 minutes.

## Gmail-specific gotchas

- **Never point a rule at `[Gmail]/All Mail`.** It contains the entire mailbox,
  including spam and sent items.
- A Gmail message carrying two labels appears in both IMAP folders. If you later add
  rules for several labels, a message labelled both `_faktura` and `_Kvitteringer`
  is a candidate for both rules — paperless processes rules in `order`, and the
  Processed Mail record stops the second one, so the *lowest order number wins*.
  Set the order deliberately.
- Labels with æ/ø/å become modified UTF-7 over IMAP and are worth avoiding as rule
  folders. The four labels here are ASCII, so this is not currently an issue.
