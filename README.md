# Itogo

**По-русски.** Итого — нативное приложение для учёта личных финансов на macOS: одна строка
ввода («кофе 250», «такси (1000+600)/2»), планирование, долги, аналитика и отчёты. Все данные
остаются на вашем Mac: в сеть приложение ходит только за курсами Банка России и за
обновлениями, телеметрии нет. Интерфейс — на русском и английском, по языку системы.

Установка: скачайте `Itogo-<версия>.zip` из [Releases](https://github.com/EvgenyBaulin/itogo/releases),
распакуйте и перенесите `Itogo.app` в «Программы». Приложение подписано собственным
сертификатом автора и не нотаризовано: при первом запуске откройте «Системные настройки» →
«Конфиденциальность и безопасность» → «Всё равно открыть». Дальше обновления приходят сами.
Нужна macOS 26 или новее.

---

A native macOS app for personal finance: type a line, get a ledger, a plan and the numbers —
and nothing leaves your Mac.

[![Build](https://github.com/EvgenyBaulin/itogo/actions/workflows/build.yml/badge.svg)](https://github.com/EvgenyBaulin/itogo/actions/workflows/build.yml)
[![Core on Linux](https://github.com/EvgenyBaulin/itogo/actions/workflows/core-linux.yml/badge.svg)](https://github.com/EvgenyBaulin/itogo/actions/workflows/core-linux.yml)

## Features

- **One line of input.** Type `coffee 250` or `такси (1000+600)/2` and press Enter. Amounts
  can be expressions; English and Russian are understood at the same time, whatever the
  language of the interface. The ↓ panel shows every field of the operation when the line is
  not enough.
- **Add from any list.** Every picker of the entry panel, the edit sheet and the inspector ends
  with «Add…»: a sheet creates the category, person, place, event or payment method and selects
  it at once.
- **Operations in parts.** One receipt can be split between categories, marked as paid for
  somebody else and got back later, tied to an event, a place, a payment method or a goal.
  Refunds, purchases on credit and templates are part of the same line.
- **Currencies.** Ten currencies at the Bank of Russia's rates.
- **Planning.** Scheduled payments and subscriptions (including those paid for others, and what
  each card has to hold), expected income, limits by category, by «bad» spending and by «for
  whom», events with budgets, goals, how much is free to spend, suggestions and reconciliation
  with the real balance.
- **Debts.** A journal of who owes whom, with shares, payments, transfers, totals and
  reminders.
- **Analytics and reports.** The month and the year, the quality of spending, spending for
  others, places, events and payment methods, a forecast with its interval, anomalies, and the
  measured quality of the category model that learns from your own choices. Monthly and yearly
  tables with shares, exported as CSV.
- **Honest money.** Amounts are integers in units of 1/10000, every calculation goes through
  `Decimal`, and floating point never touches money.
- **Two languages, two appearances.** Russian on a Russian Mac, English on any other; Settings
  can force either. Light, dark or the system's, with an accent colour of your choice. Liquid
  Glass in the navigation layer and nowhere else.
- **Your data, your machine.** SQLite in the app's container, a backup after every change, a
  mirror folder of your choosing, restore in two clicks, and one archive file that moves
  everything to another Mac.

## Privacy and the network

Itogo talks to exactly three places, and only for these reasons:

| Host | Why |
| ---- | --- |
| `www.cbr.ru` | the Bank of Russia's exchange rates for a day |
| `www.cbr-xml-daily.ru` | a mirror of the same rates, used when the bank does not answer |
| `EvgenyBaulin.github.io`, `github.com` | the update feed and the archives of new versions |

There is no telemetry, no analytics SDK and no account. The app's own journal (for a problem
report you choose to send) holds identifiers, counts and error types — never amounts, notes,
people, places or category names; a test fails if one ever gets in. The App Store build carries
no updater at all and talks to the Bank of Russia only.

## Requirements

- macOS 26 (Tahoe) or newer: the interface is built on the Liquid Glass APIs.

## Installation

1. Download `Itogo-<version>.zip` from the
   [latest release](https://github.com/EvgenyBaulin/itogo/releases/latest).
2. Unzip it and move `Itogo.app` to **/Applications**. Do not run it from Downloads: macOS runs
   an app from there out of a read-only copy, and the updater cannot replace it.
3. Open it. The release is signed with the author's own certificate — not a Developer ID — and
   is not notarized, so the first launch is blocked. Then open **System Settings → Privacy &
   Security** and press **Open Anyway** next to the message about Itogo. Once is enough.

   Or, from Terminal, remove the quarantine flag before the first launch:

   ```sh
   xattr -dr com.apple.quarantine /Applications/Itogo.app
   ```

## Updates

Itogo updates itself with [Sparkle](https://sparkle-project.org). Once a day it reads
<https://EvgenyBaulin.github.io/itogo/appcast.xml>, downloads a new version in the background and
installs it when you quit. **Check for Updates…** — in the View menu and in the toolbar of the
main window — checks at once: a new version is offered in Sparkle's window, and when there is none
Sparkle says so and the app keeps running. Automatic updates can be turned off in Settings; then a
new version arrives only through that command.

Every archive is signed with an EdDSA key, and the app refuses an update whose signature does not
match the public key it carries. Nothing about your Mac is sent with the check.

## Your data

Everything lives in the app's sandbox container:

```text
~/Library/Containers/io.github.EvgenyBaulin.itogo/Data/Library/Application Support/Itogo/Release/
  finance.sqlite     the database (with -wal and -shm beside it while the app runs)
  backups/           automatic copies of the database
  models/            the category model, trained again from your data when missing
  Logs/              the app's journal: 5 files of 2 MB, rotated
```

### Backups

- A copy is taken **after every change**, a few seconds later, so a series of edits gives one
  copy. It is made with SQLite's backup API, checked with `PRAGMA integrity_check` and only then
  given its name; a copy cut short never looks like a good one.
- Names carry the local time and its offset from UTC: `finance-2026-09-24T101500+0300.sqlite`.
  A copy taken right before a restore or an import ends in `-before-restore` or
  `-before-import`.
- The **last 50 copies and one per day for 90 days** are kept; older ones are removed, in
  `backups/` and in the mirror folder alike (only files named like our copies).
- **Settings → Backups → Choose folder…** adds a mirror folder — iCloud Drive is a good place.
  The live database never goes to iCloud, only the copies.
- **Settings → Backups → Restore…** puts any copy back. The current state is copied first, the
  chosen file is checked, and the app restarts on it.
- By hand, if the app will not open: quit it, put the copy in place as `finance.sqlite` and
  delete `finance.sqlite-wal` and `finance.sqlite-shm` beside it.

### Export to CSV

**File → Export** (or the Export button of the main window) writes 18 CSV files into a folder
you choose: operations, their parts, reimbursements, people, payment methods, places, events,
categories, templates, scheduled payments, subscription prices, expected income, limits,
goals, debts, debt entries, reconciliations and rates. UTF-8 with a header row, amounts as
decimal strings with a dot, dates in ISO 8601. The app warns first: the files hold names and
amounts.

Every file opens with `pandas.read_csv(path)` and no parameters. One caveat: pandas reads words
such as `N/A`, `NA`, `None` or `null` as missing values, so a place or a card literally called
«N/A» comes back empty. To keep such names:

```python
pandas.read_csv(path, keep_default_na=False, na_values=[""])
```

### Moving to another Mac

1. **File → Export Archive…** writes one `Itogo-<date>.itogoarchive` file. A password is
   optional; without one, everything inside is readable, and the app says so. The archive is
   opened and checked again right after it is written.
2. Carry it over by AirDrop, a USB stick or any cloud.
3. On the new Mac, install Itogo, open it once, then **File → Import Archive…** — or double-click
   the file. The current data is backed up, then replaced; the app restarts.
4. Choose the backup mirror folder again: folder bookmarks never travel with an archive.

Check afterwards: the number of operations, this month's totals on Overview, the people, places,
events and payment methods, the language, the appearance and the enabled currencies.

## Appendix: data formats, version 1

The archive is meant to be read by any implementation — a future Windows version included.

**Container.** A zip file without compression (method «stored», no zip64), UTF-8 names with
flag `0x0800`, entries in a fixed order, so the same data gives the same file:

```text
manifest.json          what the archive is, with checksums
data/database.sqlite   a consistent snapshot of the database (SQLite backup API)
data/csv/<table>.csv   the 18 tables as in the CSV export
settings.json          portable settings
```

**manifest.json** has seven required fields: `formatVersion` (1), `appVersion` (the short version
of the app that wrote it, for people only), `schemaVersion` (the number of migrations applied —
3 today; an older one is migrated, a newer one refused), `createdAt` (`YYYY-MM-DD`), `platform`,
`rowCounts` (records per table, checked against the CSV files on import) and `checksums`
(lowercase hex SHA-256 of every file except the manifest itself). The snapshot, the CSV files and
the counts are taken in one read transaction.

**settings.json** is a flat string-to-string dictionary: `language` (`system`, `en`, `ru`),
`theme.scheme` (`system`, `light`, `dark`), `theme.accent` and `currencies` (enabled codes
separated by commas). A reader skips any key or value it does not know; new keys do not change
`formatVersion`.

**CSV names.** The database keeps amounts as integers in 1/10000 in columns named `*_e4`. The CSV
files hold decimal strings instead, so the suffix goes: `amount_e4` → `amount`, `amount_rub_e4`
→ `amount_rub`. `rates.csv` keeps `rub_per_unit` as the bank publishes it — rubles for `nominal`
units, so the rate of one unit is `rub_per_unit / nominal`.

**Encryption** (optional). An encrypted archive is `header ‖ ciphertext ‖ tag`, where the
ciphertext is the whole zip container and the tag is AES-GCM's 16 bytes. The header is 48 bytes,
numbers little-endian:

| Offset | Size | Field |
| ------ | ---- | ----- |
| 0 | 8 | magic `ITGOARC1` (ASCII) |
| 8 | 2 | header version, 1 |
| 10 | 2 | key derivation: 1 = PBKDF2-HMAC-SHA256 |
| 12 | 2 | cipher: 1 = AES-256-GCM |
| 14 | 2 | reserved, zero |
| 16 | 4 | PBKDF2 iterations (600 000 by default; 1 to 50 000 000 accepted) |
| 20 | 16 | salt |
| 36 | 12 | nonce |

The key is `PBKDF2-HMAC-SHA256(password, salt, iterations)`, 32 bytes, from the UTF-8 bytes of the
password in Unicode NFC. A wrong password and a damaged file are told apart by nothing: the tag
does not match in both cases. Test vectors for SHA-256 (RFC 6234), HMAC-SHA-256 (RFC 4231),
PBKDF2-HMAC-SHA256 and CRC-32 are in
[`Packages/AppCore/Tests/CoreArchiveTests`](Packages/AppCore/Tests/CoreArchiveTests).

Not in the archive: the category model (it is trained again), folder bookmarks, paths of this
Mac and window positions.

## Building from source

You need macOS 26 or newer with **Xcode 27**, and [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`, or `scripts/install-xcodegen.sh <dir>` for the exact version CI uses). The Xcode
project is generated from `project.yml` and is not stored in git.

```sh
make              # generate the project, build Debug, run it
make test-core    # tests of the pure-Swift core — the fast loop
make test         # tests of the application
make verify       # format, lint, every test, both builds, and the checks CI runs
make sample       # the app on six months of synthetic data, in a folder of its own
make sample-large # the same with about 20 000 operations over two years
make pyenv        # a venv with pandas, so the CSV tests read the tables back for real
```

The Debug build is a separate app: its bundle id is `io.github.EvgenyBaulin.itogo.debug`, it has
its own container, settings and backups, a red «DEBUG» band on its icon, and «DEBUG» in the title
of its window. It never touches the copy in /Applications. Build products live outside the
repository, in `~/Library/Developer/Itogo/`; `Build.nosync` is a link there.

Optional: `scripts/make-signing-identity.sh` creates a self-signed «Itogo Local Signing»
certificate in your login keychain. With it, Debug builds keep one signature from build to build,
so the permissions macOS gives the UI tests survive a rebuild; without it everything is signed
ad hoc. `make hooks` points git at the repository's hooks.

## Layout

| Path | What is inside |
| ---- | -------------- |
| `Schema/` | SQL migrations, shared by every platform; they only ever go forward |
| `Packages/AppCore/` | the calculation core: money, expressions, the input parser, rates, accounting, analytics, planning, the category model, the archive format, synthetic data. Pure Swift and Foundation; builds and is tested on Linux |
| `Packages/AppDatabase/` | the GRDB storage layer: migrations, records, repositories |
| `Apps/macOS/App/` | the entry point, scenes, menus and launch options |
| `Apps/macOS/Features/` | entry, transactions, overview, analytics, reports, planning, reconciliation, debts, settings |
| `Apps/macOS/Platform/` | database, backups, export, archive, rates, updates, the calculation pipeline, logging |
| `Apps/macOS/Shared/` | the design system, localization, charts |
| `Apps/macOS/Resources/` | Info.plist, entitlements, String Catalogs, the icons |
| `Apps/macOS/Tests/`, `Apps/macOS/UITests/` | application tests and UI tests |
| `scripts/` | the checks of `make verify`, the release scripts, the git hooks |

## Releasing

For the maintainer; every step runs on the maintainer's Mac.

1. In `project.yml`, raise `CURRENT_PROJECT_VERSION` — **Sparkle compares this number**, not the
   short version — and set `MARKETING_VERSION`. Add a section `## [X.Y.Z] — <date>` to
   `CHANGELOG.md`.
2. `make verify` must end with `verify: green`.
3. `make release-local` builds Release with the public key from `sparkle-public-key.txt`, checks
   the bundle id, the key and the version inside what was built, packages `Itogo-X.Y.Z.zip` and
   signs it with Sparkle's `sign_update` and the private key in the login keychain. It writes
   the feed entry `appcast-entry-X.Y.Z.xml` next to the archive. `ARGS=--dry-run` checks
   everything and builds nothing.
4. `gh release create vX.Y.Z <archive> --title "Itogo X.Y.Z"` with the CHANGELOG section as notes.
5. Put the entry into `appcast.xml` on the branch `gh-pages` with
   `scripts/release-entry.sh into <appcast.xml> X.Y.Z <build> <length> <signature>`, push it, and
   check that the live feed serves the new length and signature.

The private EdDSA key never enters the repository; lose it, and installed copies can never be
updated again, so keep a copy in a password manager. `.github/workflows/release.yml` is a spare
path that does the same from a pushed tag:

- it needs two repository secrets, `SPARKLE_PRIVATE_KEY` (the private key as
  `generate_keys -x` prints it) and `SPARKLE_PUBLIC_KEY`;
- a release already published by hand makes it stop at its first job.

## Acknowledgements

- [GRDB.swift](https://github.com/groue/GRDB.swift) by Gwendal Roué — MIT License.
- [Sparkle](https://github.com/sparkle-project/Sparkle) — MIT License.

## License

[MIT](LICENSE) © 2026 Evgeny Baulin
