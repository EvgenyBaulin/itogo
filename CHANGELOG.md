# Changelog

All notable changes to Itogo are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

The database schema and the transfer-archive format are versioned separately from the app,
and both move forward only.

## [Unreleased]

### Changed

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

### Fixed

- «Buy on credit» could be set on income or a refund and opened an instalment debt.
- Editing a payment due on the 31st moved it to the 30th for good when its next date fell on a
  shorter month.
- The currency caption of a payment method in Settings showed an internal key.

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
