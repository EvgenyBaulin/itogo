import CoreKit
import Foundation

/// Why a transfer cannot be saved as it is.
public enum TransferIssue: Hashable, Sendable {
  public enum Side: Hashable, Sendable {
    case from
    case to
  }

  /// From one account and currency to the very same.
  case sameKey
  /// The account does not hold the currency named on that side.
  case currencyNotHeld(Side)
  /// An account of the transfer is in the archive, or is not there at all.
  case archivedAccount
  /// In one currency the money sent is the money received; a cut the bank takes is a fee.
  case amountsDiffer
  /// Nothing, or less than nothing, sent or received.
  case notPositive
}

/// Where the fee of a transfer goes.
public enum FeeCategoryChoice: Hashable, Sendable {
  case existing(UUID)
  /// No such category yet: one is made, named by `nameKey` in the interface language, under
  /// `parent` when there is one, rated `quality`.
  case create(nameKey: String, parent: UUID?, quality: Quality)
}

/// Money moved between accounts, or between two currencies of one account. A transfer is
/// neither income nor spending; its fee is an ordinary expense from the account the money
/// left, which points back at the transfer (`transfer:<id>:fee`), and the two are one step of
/// ⌘Z.
public enum TransferRules {
  /// The key of the category remembered for fees is `AccountSettings.transferFeeCategoryKey`;
  /// a new one is named by this key of the strings.
  public static let feeCategoryNameKey = "category.fees"

  /// The first thing wrong with the transfer, or `nil`.
  public static func validate(_ transfer: Transfer, accounts: [PaymentMethod]) -> TransferIssue? {
    guard transfer.fromAmountE4.raw > 0, transfer.toAmountE4.raw > 0 else { return .notPositive }
    guard transfer.from != transfer.to else { return .sameKey }
    let byId = Dictionary(accounts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    guard let from = byId[transfer.fromAccountId], let to = byId[transfer.toAccountId],
      !from.archived, !to.archived
    else { return .archivedAccount }
    guard from.holds(transfer.fromCurrency) else { return .currencyNotHeld(.from) }
    guard to.holds(transfer.toCurrency) else { return .currencyNotHeld(.to) }
    if !transfer.isExchange, transfer.fromAmountE4 != transfer.toAmountE4 { return .amountsDiffer }
    return nil
  }

  /// The fee of the transfer: an expense of `fee` in the currency the money left in, from the
  /// account it left, at the moment of the transfer, in `categoryId`, rated as that category
  /// is. The app gives the operation the key `feeKey(of:)`.
  public static func feeDraft(
    transfer: Transfer, fee: AmountE4, categoryId: UUID, tree: CategoryTree
  ) -> TransactionDraft {
    var draft = TransactionDraft(
      kind: .expense, occurredAt: transfer.occurredAt, currency: transfer.fromCurrency,
      amount: fee, paymentMethodId: transfer.fromAccountId)
    draft.normalizeSinglePart()
    draft.parts[0].categoryId = categoryId
    draft.parts[0].categorySource = .system
    let decision = QualityResolver.resolve(categoryId: categoryId, categories: tree)
    draft.parts[0].quality = decision.quality
    draft.parts[0].qualitySource = decision.source
    return draft
  }

  /// The key the fee of a transfer keeps in `external_id`.
  public static func feeKey(of transferId: UUID) -> String {
    OperationLink.transferFee(transferId).externalId
  }

  /// The category the fees go to, the first that applies:
  ///
  /// 1. the one remembered (`transfers.feeCategory`), while it is a live expense category of
  ///    the owner's;
  /// 2. a live expense category named «Комиссии» or "Fees", in any case — one under «Прочее» /
  ///    "Other" first;
  /// 3. a new one, under «Прочее» / "Other" when there is such a category, rated bad.
  ///
  /// The app remembers the id in the same change that writes the first fee.
  public static func feeCategory(
    categories: [CoreKit.Category], remembered: UUID?
  ) -> FeeCategoryChoice {
    let tree = CategoryTree(categories)
    func isLive(_ category: CoreKit.Category) -> Bool {
      !category.archived && !(tree.parent(of: category.id)?.archived ?? false)
        && category.kind == .expense && tree.systemRole(of: category.id) == nil
    }
    if let remembered, let category = tree[remembered], isLive(category) {
      return .existing(remembered)
    }
    let others = categories.filter { $0.parentId == nil && isLive($0) && named($0, otherNames) }
      .sorted(by: byOrder)
    let fees = categories.filter { isLive($0) && named($0, feeNames) }.sorted { left, right in
      let leftUnderOther = others.contains { $0.id == left.parentId }
      let rightUnderOther = others.contains { $0.id == right.parentId }
      if leftUnderOther != rightUnderOther { return leftUnderOther }
      return byOrder(left, right)
    }
    if let found = fees.first { return .existing(found.id) }
    return .create(nameKey: feeCategoryNameKey, parent: others.first?.id, quality: .bad)
  }

  private static let feeNames: Set<String> = ["комиссии", "fees"]
  private static let otherNames: Set<String> = ["прочее", "other"]

  private static func named(_ category: CoreKit.Category, _ names: Set<String>) -> Bool {
    names.contains(category.name.trimmingCharacters(in: .whitespaces).lowercased())
  }

  private static func byOrder(_ left: CoreKit.Category, _ right: CoreKit.Category) -> Bool {
    if left.sort != right.sort { return left.sort < right.sort }
    return left.id.uuidString < right.id.uuidString
  }
}
