# Changelog

All notable changes to Itogo are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

The database schema and the transfer-archive format are versioned separately from the app,
and both move forward only.

## [1.3.2] — 2026-10-07

### Fixed

- The entry line read a date with a far-off year: «dinner 2500-10-5» became a dinner on
  5 October 2500. A written year now has to be within the years a two-digit year means
  (today − 79 to today + 20); otherwise the text is no date.
- Currency names that are ordinary words — «драма», «лира», «rub», «buck» — were read as
  currencies wherever they stood. They are currencies only glued to the number or right after it;
  «RUB» in capitals still is anywhere.
- A template chip whose note held something like «100-250» entered no amount; the chip now puts
  its amount where the line reads it back.

## [1.3.1] — 2026-10-07

Fixes found by tests after 1.3.0, a tidy detailed form, merging cards and banks, and rates as
formulas.

### Added

- **Merging cards and banks.** A card can be merged with another card of its account
  (**Merge with…** in its menu): its operations, payments and cashback rules go to the kept card,
  which also takes its names. Banks can be merged too: every account of one goes under the other.
  One step of ⌘Z each; no money moves.
- An exchange rate can be typed as a formula, «95,5/1,02»; what it comes to shows beside the
  field.
- The tiles of Overview are reordered by dragging in Settings → Appearance; the arrows are gone.
- Cashback received before the bank's payout day counts, by default, for the month before:
  cashback for September that comes on 8 October is September's income.

### Changed

- The detailed form at the right of the window is laid out as one tidy column: a label above
  each field, every field the width of the column, buttons that wrap, and **Save** always at the
  bottom.
- Accounts merge only within one bank; to merge accounts of two banks, merge the banks first.
- Every card of Overview is titled by the name of its tile: «Spending forecast to the end of the
  month».

### Fixed

- **Record the difference** did nothing for a count whose difference operation, written by 1.1
  under an id of its own, had been deleted.
- The repair that gives every account a bank at each open failed, or made an empty extra bank,
  when one account was stored in two letter cases, or when an account lost its bank by hand
  after its bank had been renamed.
- A debt journal line edited so that it is no longer a payment kept the mark «no more payments
  this month».
- A debt with less left than its monthly payment asked for the whole monthly payment in the
  month's forecast and plan, in «Payments for 7 days», «Overdue payments» and **Payment…**; a due
  now asks for no more than is left of the debt.
- «No more payments this month» was offered for a payment that pays the debt off.
- A purchase for an event written for a later day lowered the budget the free sum holds back
  for the event, although its money is still on the accounts.
- A debt payment written for a later day took the debt out of the free sum and the debt's next
  payment out of the lists before its day.
- While the ↓ panel was open, a half-typed word could set a field and leave it set: «батон»
  passed through «бат» and was saved in baht, «магнитик» got the shop «Магнит» as its place,
  «авансом» made an expense income. What the line set while typing is now taken back when the
  line no longer says it; what you chose in the panel stays.
- A count beside a day-shaped price turned the price into a date: «croissants 2 pcs 3.10» was
  saved as 2 on 3 October.
- **Plan a payment** for an expense dated ahead could save the payment in a category of the app
  («Don't remember», «Loans»), which the payment form refuses.
- «Add another one?» did not ask after **Mark as paid** in Planning.

## [1.3.0] — 2026-10-07

Banks above accounts and cards, cashback rules that belong to the account, an entry that asks for
what it needs, debt dues closed by money, reconciliations that follow every recompute, and an
Overview whose tiles you choose.

### Upgrading

- The first launch of 1.3.0 migrates the database forward, once (schema 6). The update adds a
  table of banks and columns at the end of existing tables. Every account goes under a bank of
  its name — accounts with the same name under one bank. Cashback rules that every card of an
  account repeated move up to the account; rules on «Loans» are removed, as a debt payment
  never earns cashback. No other stored value changes.
- As before, the app first writes a checked copy `finance-<date and time>-before-migration.sqlite`
  into the backups folder and into `before-migration/` of the backup folder you chose; without a
  checked copy there is no migration.
- The update is one-way: 1.2.x opens neither a migrated database nor an archive written by
  1.3.0. To go back, restore the `-before-migration` copy in 1.2.x; what was entered in 1.3.0 is
  not in it.
- The transfer archive gets `banks.csv`, and `debt_entries.csv` and `payment_methods.csv` new
  columns at the end; `formatVersion` stays 1, the schema in the manifest is 6.

### Added

- **Banks.** Settings → Accounts → **New Bank…** makes a bank, an account and a card in one step
  of ⌘Z. An account is deleted without its bank, a card without its account. In every list a bank
  with one account and one card is just the bank («Sber · Sber» is gone), an account with two
  cards shows «Bank › Card», a bank with several accounts «Bank › Account». The entry line reads
  a bank's name as its first account.
- **Cashback on the account.** Rules belong to the account; a card keeps only what differs. A
  purchase without a card counts by the account's rules. Per account: rounding (whole rubles or
  kopecks; nearest, down or up), when the bank pays («right away» or «by the 10th of next
  month», with a warning when nothing came), and cashback paid as points to another account.
  Cashback no confirmation came for is grey «≈» and part of the estimated income.
- **Entry.** Return without a category does not save — choose one, or «Don't remember»; ↓ and ↑
  go through the suggestions, then the other categories. The ↓ panel reads the line as you type.
  ↓ in the line walks the list of operations from the newest; Tab opens the panel. «Add another
  one?» for the same amount within five minutes; a date after today asks whether to record it as
  is or plan a payment or an income. **Transfer…** in the panel; date and time of a transfer in
  one field. Return saves an edited operation. Settings → Entry offers a detailed form on the
  right of the window instead of the line.
- **Debts and payments.** A debt's due is closed by money: two halves close one due, a payment
  for two closes two, and an underpaid due stays as its remainder everywhere; «No more payments
  this month» closes a due paid in part. A new debt on its payment day asks whether this month's
  payment was made. Income named after a «They owe me» debt is money back; what a person returns
  over their parts goes toward their debt. Deleting the payment that closed a debt offers to
  reopen it. Overdue payments can be skipped, one or all. An expected income can come several
  times a month. A switch for the rest of event budgets in the free sum.
- **Reconciliation.** Every recompute (⌘R and the run at launch) brings the differences of later
  counts up to date; a difference that comes to zero is removed. The history of the
  reconciliation sheet offers **Record the difference** for a count saved without it, and shows
  a remembered answer «before the count?» with **Forget**. The forecast of an account's balance
  counts the losses of reconciliations and spending for others.
- **Accounts and groups.** «Total» in the sidebar opens a screen of every account in the summary.
  The screen of a group and of «Total» lists the payments, subscriptions and expected income of
  its accounts. An account's and a group's screen says when an operation was last added there.
- **Overview tiles.** Up to 12 tiles, chosen and ordered in Settings → Appearance from 18:
  month to date, top categories, good and bad, can save, forecasts of spending, income and the
  balance to the end of the month, limits, payments for 7 days, expected income, owed to me, I
  owe, event, last reconciliation, last operation, both together, worth a look, free money.
- **Windows as tabs.** Analytics, Transactions and Reports open as tabs of the main window, so
  in full screen they stay on its space.
- **About** has a link to support the author.

### Changed

- «By person» in Analytics and Reports no longer shows «No person»: spending that names nobody
  is mine and stays only in the base of the shares.
- «Top categories» leaves «Reconciliation» out.
- People and events in the archive are offered in the Transactions filter after the live ones,
  marked «(archived)».
- Name fields in Settings → Accounts are left-aligned, so a trailing space shows as you type.
- The account sheet of Settings → Accounts is no taller than the Settings window; its form
  scrolls inside.

### Fixed

- Transactions: selecting operations while the inspector was wider or narrower than its usual
  width — after a drag of its divider — could send the window into a layout loop that ended the
  app. The selection bar now floats over the table and no longer changes its layout.
- Moving a balance off an archived account dates the transfer after the latest count of the
  account it goes to, so it never makes up a difference there.

## [1.2.0] — 2026-09-28

Cards and cashback inside accounts, a first reconciliation that is the truth and later
differences that follow the books, and a free sum that no longer spends goal money or forgets an
overdue payment.

### Upgrading

- The first launch of 1.2.0 migrates the database forward, once (schema 5). The update only
  adds: tables for cards and cashback rules, and columns at the end of seven tables. Every live
  account of the kind card gets a card named like it, and the monthly plan of every goal that
  has one starts in the month of the update. No old value changes, and the update itself
  recomputes no reconciliation difference.
- As in 1.1.0, the app first writes a copy `finance-<date and time>-before-migration.sqlite`
  into the backups folder and checks it, and without a checked copy there is no migration. The
  copy now also goes to the backup folder you chose, into its subfolder `before-migration/`,
  which the copy rotation of no version ever touches.
- The update is one-way: 1.1.x opens neither a migrated database nor an archive written by
  1.2.0. To go back, restore the `-before-migration` copy in 1.1.x; what was entered in 1.2.0 is
  not in it.
- Right after the first open, 1.2.0 brings the differences of later reconciliations up to date
  with the operations entered into their windows afterwards, so the «Reconciliation» figures of
  past months in Analytics may change. A difference operation whose amount was retyped by hand
  goes back to the difference.
- A «Reconciliation» income written by a first real count — a count after nothing but the zero
  balances 1.1 wrote for empty fields in **Set Up Your Accounts**, or the first one-total count
  of 1.0.0 — stays exactly as it was, and ignores operations entered into its window, until you
  choose on the **Last reconciliation** card in Overview: **This was the first count — make it
  the starting point** (the income goes, the balance stays; ⌘Z brings it back) or **It is a real
  difference**. The next count of an account 1.1 set up with an empty field is its starting
  point by default.
- 1.1 took a due date that passed unpaid before a reconciliation as paid inside it. 1.2.0 counts
  such a due date as money not yet gone and asks about it at launch: **Taken before the
  reconciliation** closes it when the bank had already taken the money.
- A stored amount formula that the new reading of «1,500k» no longer turns into its amount loses
  the formula; the amount stays.

### Added

- **Cards inside an account.** An account can hold physical and virtual cards. The money and
  the balance stay with the account; a card says what paid. A new account of the kind card or
  account gets a card named like it. Cards are added, renamed, archived, brought back and — while
  nothing names them — deleted on the account screen and in Settings → Accounts, where each
  account lists its cards. The entry line knows a card by its name and its other names — «coffee
  350 black» goes to that card and its account — and the ↓ panel lists each account's cards under
  it; a place brings the card that paid there last, and a refund the card of its purchase. The
  Account column of Transactions shows «Bank · Black», and its filter takes an account with all
  its cards, or one card. Scheduled payments and **Mark as paid** can name a card too, and
  merging accounts moves their cards.
- **Cashback.** Rules on a card, or on an account without cards: «category, subcategory or
  everything else — N %», **always** or **only in a month** — for the bank's categories of that
  month (**Same as Last Month** copies them). A month rule beats an always rule, a subcategory
  beats its category, and «Everything else» applies when nothing else does; a percent keeps up
  to four decimals. The ↓ panel of a purchase shows the cashback to expect («≈ 35.00») and the
  rule that gives it; type an exact amount or a percent over it for this operation, and
  **Remember** turns the percent into a rule — always, or only this month — in a step of undo of
  its own. Expected cashback is an expectation and never income; received cashback is income in
  the cashback category, as before. The two stand side by side: on the account screen for this
  month, and in Analytics — **Turnover and cashback**, card by card, and the new **Cashback by
  month**.
- **Payments and Subscriptions on the account screen**: the scheduled payments paid from the
  account or from its cards, each opening for editing, and **Add Payment…**.
- **The end-of-month balance forecast.** The account screen forecasts each currency's balance at
  the end of the month — the balance now, what is already entered for later days, expected
  income, unpaid payments and debt payments, and day-to-day spending by the account's share —
  with an interval. Analytics → Forecast lists every account's balance at the end of the month,
  the accounts out of the summary apart.
- An expected income can name the account the money comes to («To account»); left empty, it is
  the account of the last income received for it, else the main one.
- **Overdue payments.** At every launch, while a scheduled payment or a debt has an unpaid due
  date in the past, Reminders open with **Overdue payments**: **Mark as paid** records it,
  **Taken before the reconciliation** — offered when the account was reconciled after the due
  date — closes it without an operation and without taking the money off twice, and **Later**
  asks again at the next launch. Until then the free sum counts that money as not yet gone, and
  **Review…** under it opens the list.
- **A scheduled payment can belong to an event.** Its due dates up to the event's end are part
  of the event's budget, so the free sum takes them off once, and the operation that pays it
  carries the event.
- **Foreign-currency goals** can be valued at the rates of the contributions instead of today's
  rate (Settings → Planning).
- **Deleting a debt or a credit** (**Delete…** on its row). It leaves Debts, the reminders, the
  free sum, the forecast and the entry line; the operations that paid it stay and count as they
  did, and the money of its journal stays in the balances. The confirmation says what stays, and
  ⌘Z brings it back.
- **Settings → Entry**: the order of the ↓ panel's fields — drag a field up or down, **Reset**
  for the standard order. Tab follows it, the entry panel and the editor share it, and it
  travels in the transfer archive.
- Return saves from anywhere in the open ↓ panel, once per keystroke; in an open menu Return
  picks the item.
- `250x2` in the entry line multiplies, when the line holds no other amount; a size beside a
  price («board 20x30 1500») stays in the note.
- **Overview**: «Last entry» says when the last operation or transfer was written, and
  «Payments in 7 days» shows about how much a payment in another currency is in the default
  currency at today's rate («≈ 269 ₽»), or «no rate».
- A transfer has a time, not only a date; a time you chose is never asked about the
  reconciliation.
- **Don't ask again for this reconciliation** in every question «Was this before the
  reconciliation?» — of the entry line, the editor, transfers and payments: the answer is used
  silently until the account is reconciled again.
- Negative balances — what a credit card owes the bank — can be typed with a minus wherever a
  balance is typed, and count as negative money in the total and the free sum. **Transfer the
  Balance…** of a card below zero covers the debt from the main account.
- «Worth a second look» offers to move the money 1.1 left on archived accounts, and says «Spent
  a goal's money? Press «Withdraw»» when the goals hold more than the accounts in the summary.

### Changed

- **The first reconciliation of an account and currency is its starting point, never income
  or spending.** Operations dated before it are history: they count in their months and do not
  move the balance. This also holds for the first real count after a zero balance that 1.1 wrote
  for an empty field: in the reconciliation sheet such a row shows **Starting point** switched
  on, with both outcomes in exact money — untick it only if that zero was real; a row left empty
  stays unreconciled.
- **Later reconciliation differences are live.** Add, edit or delete an operation or a transfer
  dated inside a count's window — or let the bank's final rate reprice a foreign purchase there,
  or record money back into it — and its «Reconciliation» difference follows in the same step of
  undo: a purchase entered afterwards makes a missing difference smaller, an income entered
  afterwards makes an extra one smaller, at zero the difference operation goes, and a change of
  sign turns income into spending. «Income by source» no longer shows the same money twice. ⌘Z
  brings a difference back as you left it — its category, comment and rating. The money, day,
  account and debt of a difference operation cannot be edited, it never moves into «Goals» or a
  category of the app, even in a bulk change, and deleting it keeps the count without recording
  its difference.
- The reconciliation sheet saves with a single **Save** when nothing differs; its history says
  which differences were saved without an operation and where starting balances came from.
- An operation dated on a day with several reconciliations of its account is asked about each
  of them in turn.
- An empty «Balance now» in **Set Up Your Accounts** or for a new account means «don't know»: no
  zero balance is written, the account stays unreconciled, and its first count becomes the
  starting point. A typed 0 is 0.
- **Merging accounts is no longer a reconciliation.** The merged account keeps the moment of its
  own latest count, operations after it move money, and the merge pays no due date. The merge
  sheet shows what the merged account holds now.
- **An archived account stays at zero.** An edit or a deletion that would leave money on it, and
  archiving an account that still holds money, ask which live account takes the money and record
  a transfer now, in the same step of undo. Changes that move no money are always allowed — the
  note of such an account's transfer too.
- **Set Up Your Accounts** names the account whose other name clashes with a name. An account
  can no longer be named like a card of another account.
- **The free sum.** «Can spend now» is the money on the accounts in the summary minus what is
  already put into goals (while «Goal money sits on accounts in the summary» is on): goal money
  is no longer spendable. The grey line takes off the part of the goal plans not yet paid in, and
  a contribution over this month's plan counts towards the following months; the goal form says
  the month its plan starts from. An unpaid overdue due date is taken off even when it falls
  before the account's reconciliation; one on the day of the reconciliation waits until it is
  paid, and **Mark as paid** of a due date before a later reconciliation asks whether the money
  left before the count — for a loan as for a scheduled payment.
- A payment closes the earliest unpaid due date — of a debt, and of a scheduled payment within
  its window; **Something else** excludes an operation from every due date of the payment. The
  Debts card marks a payment that is overdue, and **Payment…** is dated now.
- A scheduled payment on an archived account is taken from the main account and says «the
  account is archived — move the payment to another one».
- The first month of accounting no longer counts in the income median when it did not start on
  the 1st.
- The hint of «Keep back the monthly goal plans in «Free to spend»» says what it does: planned
  contributions not yet made by the chosen date are not free money.
- **Money back.** Money returned over what is left of a debt owed to me closes the debt, and the
  rest is income in «Surcharges» — from the entry line, the money-back sheets and the debt's
  **Payment…** alike. Every surplus of money back is income, except fractions of a kopeck. Both
  money-back sheets ask the currency the money came in and the account it came to; for another
  currency they show the rate the part actually cost you, and changing it reprices the purchase.
  When the bank has not published the day's rate yet, the part-by-part sheet asks for the rate
  instead of guessing it. A debt kept in another currency is repaid at a rate of its own. After a
  Bank of Russia refinement, a part the money covers is closed and any surplus is income.
  Recording money back is one step of undo instead of clearing the history.
- Editing a purchase's rate or amount rewrites the rubles of its refunds. A refund's amount
  without a currency code is read in the currency of the chosen purchase, on any screen.
- «Possible duplicate» compares the purchases' own checks, without refunds; a purchase refunded
  in full is never a duplicate.
- «1,500k» is 1,500: a comma before k is a decimal point.
- An impossible date in the line — «31.09», «29.02» of a common year — is refused with the
  reason: «31.09 — there is no such date».
- When the line does not tell the category or the subcategory, Enter opens the ↓ panel on that
  field and marks it instead of saving; the next Return saves as it stands.
- Overview lists each day's operations and transfers in one list by time, newest first; the
  symbol of each row tells its kind, and VoiceOver reads it.
- A place, a person or an event in the archive is no longer offered in entry and the pickers but
  stays in its operations, Analytics and Reports; an archived place also stays in the
  Transactions filter, after the live ones. A place in use can be archived too, and Settings →
  Reference books says what the archive does.
- A new goal with the name of an archived one is not saved: **Bring back** the old one or
  **Delete the old one…** — its contributions stay spending, its subcategory goes to the archive,
  and ⌘Z takes it back. An archived goal can also be deleted from its row in Planning.
- No limit can be set on «Reconciliation» or anything under it; a limit set there in 1.1 still
  counts and can be deleted.
- A transfer fee whose «Fees» sits under an archived parent brings the parent back with it, in
  the same step of undo, and the transfer sheet says when «Fees» is coming back from the archive.
- The report grouped by account is saved as `…-by-account.csv`.
- VoiceOver says whose «…» menu it is on every row of Accounts and Templates.
- The old one-total reconciliation of 1.0.0 is signed «one total, before accounts» on the «Last
  reconciliation» card.
- Undoing a deletion gives the operation back the time it was last changed, so the last manual
  rating of a description stays the one you gave last; undoing the deletion of money back no
  longer marks the purchases it had closed as just changed.
- The average receipt of a place is net of refunds.
- **Data formats.** The export and the transfer archive carry 23 files: `cards` and
  `cashback_rules` join the list, and new columns are appended at the end of `transactions`,
  `scheduled_payments`, `expected_income`, `goals`, `debts`, `reconciliations` and
  `reconciliation_balances`. Archives carry `schemaVersion` 5; `formatVersion` stays 1, and
  `settings.json` also carries the order of the ↓ panel's fields. The README appendix describes
  cards, cashback rules and live reconciliations.

### Fixed

- «Bad» could not be given to an expense while creating it: the quality was the one field of
  the ↓ panel that the keyboard could not set, and a category the model filled in gave the
  operation no quality — a fine filed under «Fines» was saved as «Neutral». The quality is now a
  menu like every other field, and it follows the category the model chose.
- An event could not last one day (26.09–26.09) or two; the end only has to be on or after the
  start, and the date fields always show the event's own days.
- A purchase on credit made on its payment day owed its first payment that same day, a month
  before the instalments start; its first payment is now due a month after the purchase.
- `make migration-dry-run` said only «NSError» when it could not read the file; it now prints
  the error's domain and code, never a path, and says when Full Disk Access for Terminal is the
  likely cause.

### Known limitations

- The first open of 1.2.0 recomputes the differences of later reconciliations whose windows got
  operations entered afterwards, so «Reconciliation» figures of past months may change; an old
  first-count income stays in «Income by source» until you choose on the «Last reconciliation»
  card.
- A loan entered with its original start date but without its earlier payments has an unpaid
  due date for every month before them, and each launch asks about them; **Taken before the
  reconciliation** closes those that fall before a reconciliation of the account.
- Merges made in 1.1 keep their anchor at the merge moment, so **Taken before the
  reconciliation** and «before the reconciliation?» of such an account read the merge moment.
- Money returned over the parts while the same person also owes on a debt is income in
  «Surcharges»; it does not go towards the debt — record that as a debt payment yourself.
- Only money back is split between a debt owed to me and «Surcharges»; an income that names such
  a debt still repays it with its whole amount, as in 1.1.
- Qualities that 1.1 saved without the category the model chose are not repaired; re-rate them
  in Settings → Categories or with a bulk change.
- The day-to-day pace of the account forecast leaves out reconciliation losses and parts paid
  for others, so it is optimistic for cash.
- Money repaid on a deleted «Owed to me» debt is income.
- Adding a second card to an account moves the expected cashback of its earlier operations that
  name no card from the first card's rules to the account's own.

### Internal

- The database's readers are opened again after a migration, so a read right after the update
  sees the columns it added.
- `make sample` and `make demo` show what is new: cards and a virtual one, cashback rules of
  both kinds with a typed amount, a hotel inside a New Year budget, a goal paid ahead of its
  plan, an expected salary on an account, an archived place, a one-day event, a credit card
  below zero and a later count whose difference follows an operation entered after it; the demo
  also has one overdue payment.
- `make test-core`, `make test-db` and `make bench` take `SPM_SCRATCH=<folder>` for a SwiftPM
  build folder of their own; `make migration-dry-run` expects the cards the update gives the
  card accounts.

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
