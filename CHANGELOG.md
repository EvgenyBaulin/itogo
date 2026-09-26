# Changelog

All notable changes to Itogo are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

The database schema and the transfer-archive format are versioned separately from the app,
and both move forward only.

## [1.1.2] — 2026-09-26

Fixes to 1.1.1. The database schema and the transfer-archive format stay as 1.1.0 left them.

### Fixed

- A change made outside operations — the default currency, the currencies switched on or off,
  a Planning setting, «This is normal» on an anomaly, pinning or archiving a template — got no
  backup of its own: closing the app right after it left the newest copy without that change.
  Every change written to the database now schedules a backup.
- An account's turnover counted a refund taken back to another account in the refund's month,
  as a negative figure on that account; it now follows the purchase, like the other figures.
- «Places» and «Events» of the refund's month listed the purchase's place or event with 0 ₽;
  a refund tied to a purchase now counts only where the purchase does.
- The category model learned a purchase twice when it had a refund tied to it.
- The counters of «Model quality» were written without thousands separators («12345»).
- VoiceOver: the pin of a pinned template now says it unpins, and the «…» menu of every
  category row says whose menu it is.

## [1.1.1] — 2026-09-26

Fixes to 1.1.0. The database schema and the transfer-archive format stay as 1.1.0 left them:
the first launch migrates nothing.

### Changed

- Moments are written to the database cut down to the millisecond instead of rounded to the
  nearest one, in the same text form. What 1.1.0 wrote is kept as it is.
- A copy made before an update, a restore or an import, or a damaged file set aside, never
  takes the name of another: when the name of that second is taken, it gets the next free one.

### Fixed

- An operation, a transfer or a reconciliation entered a moment ago could be missing from a
  balance for a moment: moments are now never stored later than they happened.
- The copy made before the update could be replaced by another copy made in the same second.
- Two copies made before a restore or an import within one second replaced each other.
- Restoring the older of two copies made before the update wrote a third copy of the same data.
- A second **Restore from a Copy** in the window that says the database did not open failed
  when it came within the same second as the first.
- Deleting a transfer of an archived account created money in the total; such a transfer now
  stays until the account is brought back: its sheet refuses it, and a deletion in Transactions
  or Overview leaves it out, deletes the rest and says which transfer stays and why.
- Deleting a selection that included a transfer whose fee had been refunded deleted nothing and
  only said it could not delete, and a transfer whose fee had been closed by money back was
  deleted with that fee; both transfers now stay, with the words of their own sheet, and the
  rest of the selection is deleted.
- An account with money on it could be deleted, and its money left the total; deleting it is
  refused now, and the refusal says what can be done: transfer the balance to another account
  and archive this one — **Transfer the Balance…** is offered beside it — or reconcile it to
  zero without recording the difference and then delete it.
- A transfer fee could create a second «Fees» category after the first was archived; the
  archived one comes back instead, in the same step of undo.
- **Yes, Before the Count** moved a transfer already dated before the count to a second before
  it; the transfer keeps its own time now, as an operation does.
- A template chip saved its amount in the currency of the account whose screen was open, or of
  the account picked in the ↓ panel: a «coffee 250 ₽» chip on a tenge account saved 250 ₸.
- The preview above the entry line could name a currency other than the one the operation was
  saved in; the preview, the chips and saving now take the currency by one rule.
- Money back in another currency than the parts it closed left the surplus a fraction of a
  kopeck off (250.0020 ₽ instead of 250.00 ₽), and closed the part the money ran out on for a
  fraction of a kopeck more than the account received. The surplus is now exactly the rubles
  the parts did not take, at the rate the money came at.
- In **Set Up Your Accounts**, an account named like an archived one was told to bring the
  archived one back in Settings, which Settings refuses while a live account has that name; an
  account already in the database is now asked for another name.

### Internal

- CI runs its later steps after a failed test too, and `make check-ci` fails on a condition that
  reads a step no step of its job declares. A release checks its build number against the
  published feed, and `make release-check` checks a published release — or a candidate, before
  it is published — from the outside.

## [1.1.0] — 2026-09-26

Accounts: what you have now, where it is and in which currency — and the free sum counted from
that money instead of from a single total.

### Upgrading

- The first launch of 1.1.0 migrates the database forward, once. The update only adds tables
  and columns and fills the new ones from what is there: nothing is deleted or overwritten.
  Every payment method becomes an account, every operation keeps its own, and operations that
  had none go to the main account.
- Before it migrates, the app writes a copy `finance-<date and time>-before-migration.sqlite`
  into the backups folder and checks it: the copy opens, passes `integrity_check`, and has as
  many rows in every table as the database. This copy is never pruned — the 50/90 rule of the
  backups leaves it alone and does not count it. Without a checked copy there is no migration:
  the app says why and leaves the database as it was. The migration and the steps that fill the
  new columns run in one transaction, so a failure leaves the database exactly as 1.0.0 had it;
  the next attempt uses the same copy.
- 1.0.0 cannot open a migrated database: it refuses a schema newer than its own. To go back to
  1.0.0, restore the `-before-migration` copy in it — 1.0.0 offers the copies in the window that
  says the database did not open — or put it in place by hand as the README describes. What was
  entered in 1.1.0 is not in that copy.
- After the update the app offers to set up the accounts once (see **Set Up Your Accounts**
  below).
- A transfer archive written by 1.0.0 opens in 1.1.0 and is migrated the same way. An archive
  written by 1.1.0 carries schema 4, and 1.0.0 refuses it.

### Added

- **Accounts.** Payment methods are accounts now: card, cash, account or other. An account
  holds one or more currencies — the first is its main one — and its balance is kept for each
  currency apart. There is always exactly one main account, first in every list and menu; the
  others go alphabetically or in the order you drag them into, and **Sort Alphabetically**
  brings the alphabet back. Accounts can be renamed, merged, archived and brought back, and
  deleted when nothing refers to them.
- **Account groups**, such as «Russia» and «Kazakhstan». A group can be left out of the
  summary (**Count in the overall summary** off): its money is then shown apart, with its own
  total, and stays out of the total, the free sum and Planning, while its income and spending
  still count everywhere — Overview, Analytics, Reports, limits, the forecast.
- **Accounts in the sidebar.** Under the three sections, «Accounts» lists the groups with their
  totals and the accounts with their balances; a foreign currency also shows its rubles.
  An account opens a screen of its own — the balance in every currency, its operations and
  transfers by day, **Transfer**, **Reconcile** and **Edit** — and a group shows its total and
  the history of its accounts. While an account's screen is open, a new operation goes to that
  account.
- **Transfers** between accounts, and between the currencies of one account (an exchange):
  the amount sent and the amount received as the bank shows them, with the rate they imply, and
  an optional fee recorded as an expense of its own. A transfer is a row of its own with ⇄ in
  the day lists, is neither income nor spending, and takes one step of undo.
- **What the account was charged.** An operation in a currency the account does not hold is
  charged in the account's main currency: the ↓ panel prefills the charge at the Bank of
  Russia's rates, and you can type the figure from the statement. Every operation has an
  account — the one typed or picked, otherwise the place's last one, otherwise the main one.
- **Set Up Your Accounts** on the first launch, and once after the update: quick picks of
  Russian and Kazakh banks, cash and any other name, the payment methods the database already
  has, and for each account its currencies, its group and how much is on it now. Those amounts
  are the first reconciliation. **Later** keeps the accounts as they are, the main one included
  — only a database with no account at all gets a «Main account» — and a card in Overview leads
  back to the setup.
- **Reconciliation by account and currency.** One sheet lists every account in every
  currency with the expected balance filled in; you change only the rows that differ. The
  first count of an account and currency is the starting point and compares nothing; later
  ones show the difference in that currency and can record it on that account. A move of the
  exchange rate is never a difference. An operation dated on the day of the latest count and
  entered after it asks whether it happened before the count.
- **Refunds tied to purchases.** A purchase refund is picked from recent purchases that still
  have something left to refund — the whole amount or part of it, one part of a split receipt —
  and counts in the purchase's day and month, as if the purchase had been cheaper, while the
  money reaches the account on the refund's own day. A purchase refunded in full comes to
  exactly zero. A refund without a purchase is still possible.
- **Money back in part.** Say who gives back how much: that person's oldest parts close first,
  a part covered only partly stays open with what is left, and anything above what was owed is
  income in «Surcharges», as before. A short confirmation says what closes and what stays owed;
  the part-by-part sheet is one click away, and a remainder can be written off.
  The entry line takes «money back 1700 from Anya».
- **Default currency** in Settings → Currencies: the currency of everything new — the entry
  line, templates, scheduled payments, expected income, debts, goals, money back. A currency
  typed in the line comes first, then the chosen account's. Totals, limits and reports stay in
  rubles.
- **Goals in any currency.** Progress is counted in the goal's currency; a contribution in
  another currency counts at the rate of its own day.
- **Limits running out.** Planning shows the first limits in one order — over, then close,
  then by the share spent — as many as Settings → Planning says (five by default, or all), and
  **All limits (N)…** opens the rest; the Overview card uses the same order. Click an amount to
  change it in place. Settings → Categories has a limit field in every row that can take one.
- **References.** People, places, accounts and events that nothing refers to can be deleted,
  several at a time; one in use can be merged into another or archived. Every archive —
  references, categories, goals, templates, account groups — can be shown, and its rows brought
  back. Adding an archived name brings it back instead of making a second one. Aliases are
  «Other names», edited as a list.
- **Planning.** A planned one-off expense is a scheduled payment of frequency «Once»: it is
  reminded, counted in the seven-day card, what the cards have to hold and the forecast, and
  paid off with an operation. Event budgets are set right in the Events block. The money
  somebody gives back for a payment made for them can be in another currency; the card shows
  both amounts.

### Changed

- **The free sum starts from the money you have now**: the balances of the accounts in the
  summary, each from its latest reconciliation plus every real movement since, in rubles at
  today's rate. A grey line below subtracts what is still ahead until a date you choose (the
  end of the month by default, up to twelve months ahead): scheduled payments and
  subscriptions not yet paid, what is due on the debts you owe, the money already put into
  goals and the rest of the goal plans, and what is left of event budgets. The daily figure is
  counted from that line. Expected income is shown as still expected and never added. Without
  a reconciliation the block asks for the first one. **Goal money sits on accounts in the
  summary** in Settings → Planning keeps goal savings from being subtracted when that money is
  on an account outside the summary.
- **Fields follow the kind of operation.** Income has no «for whom», place, event, «paid for
  someone» or «on credit»; its account is «To account», an expense's «From account». What 1.0.0
  stored in those fields of income stays in the database and is ignored.
- **«Payment method» is «Account»** everywhere: the ↓ panel, the editor, Transactions,
  Planning, Debts, Analytics («Accounts»), Reports and Settings. The CSV columns keep their
  names.
- **Updates.** The toolbar button and the View-menu item are now **Check for Updates…**: when
  there is no new version Sparkle says so and the app keeps running instead of restarting.
- **Restarting** after a language change, a backup restore or an archive import no longer
  leaves a second icon in the Dock: the new copy opens only after the old one has quit.
- **Appearance.** The accent colours are a row of colour circles. Switching the theme back to
  «System» now changes every window, including Settings. The Settings window can be resized.
- **Categories.** The list is flat, with no header sticking to the top while scrolling; system
  categories can be renamed.
- **Scheduled payments.** One frequency menu (weekly, every 2 weeks, monthly, every 2 months,
  quarterly, every half year, yearly, once, other…), «On the last day of the month» for
  payments, expected income and the debt payment day.
- **Wording.** «Для кого» is «На кого» in Russian; the person who gives money back is «От кого».
- **Numbers.** Every number is written the same way in both languages: comma for thousands, dot
  for the fraction — «1,234.56 ₽», «33.3 %». Typed amounts follow one rule: «1,500» is one
  thousand five hundred, «1500,5» and «1.5» have a fraction; rates keep reading «83,125» as
  83.125. Amount fields rewrite what was typed into that form when you leave them.
- **Data formats.** The export writes 21 CSV files: `account_groups`, `transfers` and
  `reconciliation_balances` join the list, and new columns are appended at the end of
  `transactions`, `transaction_parts`, `payment_methods`, `templates`, `goals`, `debt_entries`
  and `reconciliations`. Archives carry `schemaVersion` 4; `formatVersion` stays 1. The README
  appendix describes accounts, reconciliations and the keys in `external_id`.
- **README** is in Russian.
- For building from source: `make demo` opens the Debug build on a year of demo data drawn
  from a new random seed each time — accounts in several currencies and a group outside the
  summary, transfers with fees in rubles and in dollars, currency exchanges, counts, an account
  merged into another and kept in the archive, refunds tied to purchases, money partly given
  back, a payment due once, a goal in dollars, event budgets. It prints the seed:
  `make demo SEED=<n>` makes the same data again on the same day and in the same interface
  language.

### Fixed

- A scheduled payment paid with an ordinary operation instead of «Mark as paid» was counted
  twice — in the free sum, what the cards have to hold, the reminders and the forecast. A
  matching expense (same category and currency, within 10 % and five days) now counts as the
  payment; you can link it for good or say it is something else.
- Archiving or merging the default payment method could leave none.
- «Buy on credit» could be set on income or a refund and opened an instalment debt.
- Editing a payment due on the 31st moved it to the 30th for good when its next date fell on a
  shorter month.
- The currency caption of a payment method in Settings showed an internal key.
- A number too long to hold was silently read as zero; it is refused now.
- A template chip wrote its amount as «1500.5».

## [1.0.0] — 2026-09-25

The first public version.

### Added

- **Entry.** One line with expressions, in English and Russian at once; the ↓ panel with every
  field; split receipts; paying for somebody else and getting it back; refunds; buying on
  credit; templates; ten currencies at the Bank of Russia's rates; editing and deleting with
  one step of undo.
- **Planning.** Scheduled payments and subscriptions, including those paid for others and what
  each card has to hold; expected income; limits by category, by bad spending and by «for
  whom»; events with budgets; goals; how much is free to spend; suggestions; reconciliation.
- **Debts.** A journal of entries and groups, kinds, shares, payments by the accounting rules,
  transfers, totals and reminders.
- **Analytics and reports.** The month and the year, quality of spending, paid for others, for
  whom, places, events, payment methods, the forecast with its interval, the anomalies and the
  measured quality of the category model. Monthly and yearly tables with shares, exported as
  CSV that `pandas.read_csv` reads with no parameters.
- **Your data on your Mac.** SQLite in the app's container, backups with a mirror of your
  choosing, restore, one encrypted archive that carries everything to another Mac.
- **Two languages**, light and dark, Liquid Glass in the navigation and nowhere else.
- **Updates** through Sparkle in the Direct build, and nothing of the sort in the App Store
  build — which is checked by looking inside the bundle that was built.
- **No telemetry.** The journal carries no amounts, no names and no category titles.
- Appearance: light, dark or the system's, and the accent colour of the app, in Settings.
- Analytics: «By subscriptions for others» is computed from the charges «Mark as paid» wrote,
  instead of announcing a later milestone.
- A gear in the toolbar of the main window: a way into the settings that can be seen without
  opening a menu.
- Categories can be deleted, and the archived ones can be listed and brought back.
- Every picker in the entry panel, the edit sheet and the inspector ends with “Add…”, which
  opens a sheet to create a category, person, place, event or payment method and selects it;
  the “+” buttons beside place and person are gone.

### Changed

- «+» and ⌘N open the entry form instead of focusing a line that already had the focus.
- The difference a reconciliation records goes to a «Reconciliation» category of its own
  rather than into «Don't remember».
- A tag `vX.Y.Z` carries a release all the way: the workflow runs the tests of the application
  too, creates the GitHub release and puts the entry into the feed on Pages. The tag has to
  match `project.yml`, and the build number has to grow past the release before, or the
  release stops. A release published by hand on GitHub creates its tag as well; the workflow
  sees it published and builds nothing.
- A build from source is a separate app, `io.github.EvgenyBaulin.itogo.debug`, with its own
  data, settings and backups and a «DEBUG» band on its icon; it never touches the copy in
  /Applications. `make install` installs the latest published release instead of a local
  build.

### Fixed

- The entry for the update feed carried its `length` twice — once from the script, once from
  Sparkle's `sign_update` — and a feed with it would not have parsed at all. Entries are now
  read back inside the feed before they are written.
- The window of Transactions no longer dies on a double click. The selection bar measured
  itself inside the column the popovers hang on, and the anchor of those popovers read that
  measurement, so every frame of the bar's entrance asked the column to lay out again.
