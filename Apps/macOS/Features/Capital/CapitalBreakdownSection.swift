import AppCore
import SwiftUI

/// «Из чего складывается»: «Что есть» and «Что должен» side by side — below each other in a
/// narrow window —, in blocks, every row with its share of its column. A row that adds nothing
/// says why in words and a symbol: «Не сверен», «Нет курса», «Нет оценки». A click on a row
/// opens what it is: the account's screen, the debt in «Долги», the editor of the asset.
struct CapitalBreakdownSection: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  let model: CapitalViewModel
  let open: (CapitalLine.Source) -> Void

  var body: some View {
    ComputedBlock(
      title: CapitalText.t("capital.breakdown.title", environment),
      state: compute.states.data.flatMap { _, at in
        model.isEmpty ? .notEnoughData : .ready(model, at: at)
      },
      emptyReason: CapitalText.t("capital.empty", environment),
      retry: { compute.retry(ComputeStep.data) }
    ) { model in
      VStack(alignment: .leading, spacing: 12) {
        warnings(model)
        ViewThatFits(in: .horizontal) {
          HStack(alignment: .top, spacing: 24) {
            column("capital.have", total: model.have, groups: model.haveGroups)
              .frame(minWidth: 280, maxWidth: .infinity, alignment: .topLeading)
            column("capital.owe", total: model.owe, groups: model.oweGroups)
              .frame(minWidth: 280, maxWidth: .infinity, alignment: .topLeading)
          }
          VStack(alignment: .leading, spacing: 16) {
            column("capital.have", total: model.have, groups: model.haveGroups)
            column("capital.owe", total: model.owe, groups: model.oweGroups)
          }
        }
      }
    }
  }

  @ViewBuilder
  private func warnings(_ model: CapitalViewModel) -> some View {
    ForEach(model.warnings, id: \.self) { warning in
      Label {
        Text(
          verbatim: CapitalText.format(
            Self.warningKey(warning.issue), environment,
            warning.names.joined(separator: ", ")))
      } icon: {
        Image(systemName: Self.issueSymbol(warning.issue))
      }
      .font(.callout)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
    }
    ForEach(model.countedTwice, id: \.self) { name in
      Label {
        Text(verbatim: CapitalText.format("capital.countedTwice", environment, name))
      } icon: {
        Image(systemName: "exclamationmark.triangle")
      }
      .font(.callout)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func column(
    _ titleKey: String, total: AmountE4, groups: [CapitalViewModel.Group]
  ) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .firstTextBaseline) {
        Text(verbatim: CapitalText.t(titleKey, environment))
          .font(.headline)
        Spacer(minLength: 8)
        Text(verbatim: environment.money.rounded(total))
          .font(.headline.monospacedDigit())
      }
      .accessibilityElement(children: .combine)
      .accessibilityAddTraits(.isHeader)
      if groups.isEmpty {
        Text(verbatim: CapitalText.t("capital.nothing", environment))
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      ForEach(groups) { group in
        VStack(alignment: .leading, spacing: 4) {
          HStack(alignment: .firstTextBaseline) {
            Text(verbatim: title(of: group))
              .font(.subheadline.weight(.semibold))
            Spacer(minLength: 8)
            Text(verbatim: environment.money.rounded(group.totalRub))
              .font(.subheadline.monospacedDigit())
              .foregroundStyle(.secondary)
          }
          .accessibilityElement(children: .combine)
          ForEach(group.rows) { row in
            Button {
              open(row.line.source)
            } label: {
              rowView(row)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("capital.row.\(row.id)")
          }
        }
      }
    }
  }

  private func rowView(_ row: CapitalViewModel.Row) -> some View {
    let line = row.line
    return VStack(alignment: .leading, spacing: 2) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(verbatim: line.name)
          .lineLimit(1)
        if let issue = line.issue {
          Label {
            Text(verbatim: CapitalText.t(Self.issueKey(issue), environment))
          } icon: {
            Image(systemName: Self.issueSymbol(issue))
          }
          .font(.caption)
          .foregroundStyle(.secondary)
        }
        Spacer(minLength: 8)
        if let share = row.shareBp {
          Text(verbatim: environment.money.percent(basisPoints: share))
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        Text(verbatim: amountText(line))
          .monospacedDigit()
      }
      if let interest = line.interestRub, !interest.isZero {
        Text(
          verbatim: CapitalText.format(
            "capital.interest", environment, environment.money.rounded(interest))
        )
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
      }
      if let accrued = line.accruedNotCountedRub, !accrued.isZero {
        Text(
          verbatim: CapitalText.format(
            "capital.accrued", environment, environment.money.rounded(accrued))
        )
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
      }
    }
    .padding(.vertical, 2)
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
  }

  /// The rubles of a row; for money in another currency its own figure too: «$1,200 · 96,000 ₽».
  private func amountText(_ line: CapitalLine) -> String {
    guard let rub = line.amountRub else {
      return line.amount.map { environment.money.rounded($0, currency: line.currency) } ?? "—"
    }
    guard line.currency != .rub, let amount = line.amount else {
      return environment.money.rounded(rub)
    }
    return environment.money.rounded(amount, currency: line.currency) + " · "
      + environment.money.rounded(rub)
  }

  private func title(of group: CapitalViewModel.Group) -> String {
    switch group.kind {
    case .accounts: CapitalText.t("capital.group.accounts", environment)
    case .deposits: CapitalText.t("capital.group.deposits", environment)
    case .outOfSummary:
      group.accountGroupName.map {
        CapitalText.format("capital.group.outOfSummaryNamed", environment, $0)
      } ?? CapitalText.t("capital.group.outOfSummary", environment)
    case .assets:
      CapitalText.format(
        "capital.group.assetsOf", environment,
        CapitalText.t(CapitalText.kindKey(group.assetKind ?? .other), environment))
    case .owedToMe: CapitalText.t("capital.group.owedToMe", environment)
    case .iOwe: CapitalText.t("capital.group.iOwe", environment)
    }
  }

  static func issueKey(_ issue: CapitalLine.Issue) -> String {
    switch issue {
    case .unanchored: "capital.issue.unanchored"
    case .withoutRate: "capital.issue.withoutRate"
    case .unvalued: "capital.issue.unvalued"
    }
  }

  static func warningKey(_ issue: CapitalLine.Issue) -> String {
    switch issue {
    case .unanchored: "capital.warning.unanchored"
    case .withoutRate: "capital.warning.withoutRate"
    case .unvalued: "capital.warning.unvalued"
    }
  }

  static func issueSymbol(_ issue: CapitalLine.Issue) -> String {
    switch issue {
    case .unanchored: "questionmark.circle"
    case .withoutRate: "hourglass"
    case .unvalued: "tag.slash"
    }
  }
}
