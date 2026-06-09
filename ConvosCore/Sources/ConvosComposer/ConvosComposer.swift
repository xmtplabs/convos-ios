#if canImport(UIKit)
import SwiftUI

/// Shared message composer used by the app's conversation view and the share
/// extension. Populated incrementally during the extraction from the app target.
///
/// The package carries its own copy of the design-system subset the composer
/// needs (colors/icons, spacing) so it does not depend on the app target.
public enum ConvosComposer {
    public static let version: String = "0.1.0"
}
#endif
