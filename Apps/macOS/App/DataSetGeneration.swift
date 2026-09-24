#if DEBUG

  import AppCore
  import AppDatabase
  import Foundation

  /// A data set generated at launch: `--data-set <name>` with `--generate <months|large>`.
  /// Debug only — a Release build has no way to make one and only opens a set that is there.
  ///
  /// The folder of the set is made anew, and a fresh database in it gets the whole
  /// generated history in one transaction — its category tree first, system categories
  /// included — before the app starts on it. The start seeds no starter tree in a set
  /// (`AppEnvironment.seed`), so every system role is there once and nothing is listed twice.
  /// The Debug and Release databases are other folders and are never opened.
  enum DataSetGeneration {
    /// The seed of every generated set: the same day always gives the same history.
    static let seed: UInt64 = 20_260_918

    /// A folder that is not a data set's is never emptied (`prepare`).
    struct NotADataSetFolder: Error {}

    /// Starts the app on a set generated for today, in the interface language, lived up to
    /// this moment: nothing in it comes after the launch. Returns whether this call wrote the
    /// set (`AppEnvironment.start(preparing:)`).
    @MainActor
    @discardableResult
    static func start(
      _ environment: AppEnvironment, generation: LaunchOptions.Generation
    ) async -> Bool {
      let directory = AppPaths.dataDirectory
      let calendar = environment.calendar
      let now = Date()
      let today = calendar.day(of: now)
      let language = environment.language.resolvedCode
      return await environment.start(preparing: {
        try prepare(
          directory: directory, generation: generation, today: today, now: now,
          calendar: calendar, language: language, schema: BundleSchemaSource())
      })
    }

    /// Makes `directory` anew — only ever a folder under `Sets/` — and writes a generated
    /// history into a new database there. Returns the database, open.
    nonisolated static func prepare(
      directory: URL, generation: LaunchOptions.Generation, today: DateOnly, now: Date? = nil,
      calendar: CalendarContext, language: String, schema: any SchemaSource
    ) throws -> DatabaseStack {
      guard directory.deletingLastPathComponent().lastPathComponent == "Sets" else {
        throw NotADataSetFolder()
      }
      let manager = FileManager.default
      if manager.fileExists(atPath: directory.path) {
        try manager.removeItem(at: directory)
      }
      try manager.createDirectory(at: directory, withIntermediateDirectories: true)
      let stack = try DatabaseStack(url: AppPaths.databaseURL(in: directory), schema: schema)
      try write(
        generate(generation, today: today, now: now, calendar: calendar, language: language),
        into: stack)
      return stack
    }

    /// The history ending `today`; with `now`, only as much of today as has been lived.
    nonisolated static func generate(
      _ generation: LaunchOptions.Generation, today: DateOnly, now: Date? = nil,
      calendar: CalendarContext, language: String
    ) -> SampleDataSet {
      let generator = SampleDataGenerator(seed: seed)
      switch generation {
      case .months(let months):
        return generator.generate(
          months: months, endingOn: today, now: now, calendar: calendar, language: language)
      case .large:
        return generator.generate(
          months: SampleDataGenerator.largeSetMonths, endingOn: today, now: now,
          calendar: calendar, language: language, density: SampleDataGenerator.largeSetDensity)
      }
    }

    /// The whole set in one transaction (`HistoryBatch(sample:)`), the tree before everything
    /// filed under it, and the cashback of Analytics, which points into that tree, with it:
    /// a set never lands without it. Payments, limits and an expected income come with the
    /// history, so Planning is not empty on a set of synthetic data.
    nonisolated static func write(_ set: SampleDataSet, into stack: DatabaseStack) throws {
      try TransactionRepository(writer: stack.writer).insert(HistoryBatch(sample: set))
    }
  }

#endif
