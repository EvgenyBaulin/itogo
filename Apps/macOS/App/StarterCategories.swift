import CoreKit
import CoreSample
import Foundation

/// The starter categories from the specification, created in the interface language on
/// first launch. They can be renamed afterwards; the real ones arrive with the import.
///
/// The list itself is the core's `SampleCatalog` — the one the synthetic data sets and the
/// screenshots are built from — so first launch and the samples can never drift apart.
public enum StarterCategories {
  /// The catalog in the given language, numbered by one running `sort` over the whole
  /// list, as first launch has always numbered it.
  public static func tree(language code: String) -> [CoreKit.Category] {
    SampleCatalog.makeCategories(language: code).enumerated().map { index, category in
      var numbered = category
      numbered.sort = index
      return numbered
    }
  }
}
