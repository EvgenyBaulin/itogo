import Foundation

/// Money amount stored as an integer number of 1/10000 units — the `*_e4` columns of the
/// schema. Every calculation goes through `Decimal`; `Double` is never used for money.
public struct AmountE4: Hashable, Sendable, Comparable, Codable {
  /// Number of stored units in one whole currency unit (one ruble, one dollar…).
  public static let unitsPerWhole: Int64 = 10_000
  public static let zero = AmountE4(raw: 0)

  /// The largest amount one operation may be typed with, either sign: a trillion whole
  /// units. No personal operation in any currency the Bank of Russia quotes comes near it,
  /// and more than nine hundred of them still add up inside what `Int64` stored units can
  /// hold — so the total of a day, a month or a split of such amounts stays an exact number.
  public static let inputLimit = AmountE4(raw: 1_000_000_000_000 * unitsPerWhole)

  public var raw: Int64

  public init(raw: Int64) {
    self.raw = raw
  }

  public init(whole: Int64) {
    let (value, overflow) = whole.multipliedReportingOverflow(by: Self.unitsPerWhole)
    precondition(!overflow, "amount out of range")
    self.raw = value
  }

  /// Converts a decimal amount into stored units, rounding half away from zero.
  public init(decimal: Decimal) throws {
    let scaled = decimal * Decimal(Self.unitsPerWhole)
    self.raw = try DecimalMath.int64(rounding: scaled)
  }

  public var decimal: Decimal {
    Decimal(raw) / Decimal(Self.unitsPerWhole)
  }

  public var isZero: Bool { raw == 0 }
  public var isNegative: Bool { raw < 0 }
  public var magnitude: AmountE4 {
    AmountE4(raw: raw.magnitude > UInt64(Int64.max) ? Int64.max : abs(raw))
  }

  public static func < (lhs: AmountE4, rhs: AmountE4) -> Bool { lhs.raw < rhs.raw }

  // The arithmetic of money never traps. What is stored may hold any `Int64` — an archive,
  // a CSV, a row saved before `inputLimit` existed — and the ledger adds it up on every
  // open, so plain `Int64` operators would turn one such day into a crash at every launch.
  // A result that leaves the range stops at its edge instead; `adding(_:)`
  // is still there for input that has to be refused rather than clamped.

  public static func + (lhs: AmountE4, rhs: AmountE4) -> AmountE4 {
    let (value, overflow) = lhs.raw.addingReportingOverflow(rhs.raw)
    guard overflow else { return AmountE4(raw: value) }
    return AmountE4(raw: rhs.raw < 0 ? .min : .max)
  }

  public static func - (lhs: AmountE4, rhs: AmountE4) -> AmountE4 {
    let (value, overflow) = lhs.raw.subtractingReportingOverflow(rhs.raw)
    guard overflow else { return AmountE4(raw: value) }
    return AmountE4(raw: rhs.raw < 0 ? .max : .min)
  }

  public static prefix func - (value: AmountE4) -> AmountE4 {
    AmountE4(raw: value.raw == .min ? .max : -value.raw)
  }

  public static func += (lhs: inout AmountE4, rhs: AmountE4) {
    lhs = lhs + rhs
  }

  /// Overflow-safe addition for untrusted input (imports, archives).
  public func adding(_ other: AmountE4) -> AmountE4? {
    let (value, overflow) = raw.addingReportingOverflow(other.raw)
    return overflow ? nil : AmountE4(raw: value)
  }

  /// Sums parts without losing a unit: plain integer addition, no intermediate rounding.
  /// A total beyond the range stops at its edge, like `+`.
  public static func sum(_ amounts: some Sequence<AmountE4>) -> AmountE4 {
    amounts.reduce(AmountE4.zero, +)
  }

  // Encoded as a plain integer of stored units: that is what the *_e4 columns, the CSV
  // exports and the archive all carry.
  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    self.raw = try container.decode(Int64.self)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(raw)
  }

  /// Shares of this amount in proportion to `weights`, each weight measured against `whole`
  /// — the rule for the rubles of the parts of an operation: every share but the
  /// last is rounded half away from zero, and the last takes what is left, so the shares add
  /// up to the amount exactly and rounding never loses a unit.
  ///
  /// This is the one place the rule lives: a draft being saved and a provisional rate being
  /// refined must give the parts the same rubles for the same operation. With a zero
  /// `whole` there is nothing to be proportional to, and every share is zero.
  public func allocated(
    proportionallyTo weights: [AmountE4], outOf whole: AmountE4
  )
    -> [AmountE4]
  {
    guard !weights.isEmpty else { return [] }
    guard !whole.isZero else { return weights.map { _ in .zero } }
    var shares: [AmountE4] = []
    shares.reserveCapacity(weights.count)
    var distributed = AmountE4.zero
    for weight in weights.dropLast() {
      let exact = Decimal(weight.raw) * Decimal(raw) / Decimal(whole.raw)
      // Only weights that do not add up to `whole` (mixed signs, a stored row out of balance)
      // ask for more than `Int64` units hold. Such a share stops at the edge like every sum of
      // money instead of becoming zero and leaving it all to the last part.
      let rounded = try? DecimalMath.int64(rounding: exact)
      let share = AmountE4(raw: rounded ?? (exact < 0 ? .min : .max))
      shares.append(share)
      distributed += share
    }
    shares.append(self - distributed)
    return shares
  }

  /// Splits an amount into `count` shares that add up exactly to the original.
  /// Remainder units are handed out one by one to the first shares.
  public func split(into count: Int) -> [AmountE4] {
    guard count > 0 else { return [] }
    let base = raw / Int64(count)
    let remainder = raw % Int64(count)
    let step: Int64 = remainder < 0 ? -1 : 1
    var shares = Array(repeating: AmountE4(raw: base), count: count)
    for index in 0..<Int(abs(remainder)) {
      shares[index].raw += step
    }
    return shares
  }
}
