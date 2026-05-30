import Foundation

public enum SubscriptionProductIDs {
    /// Bundle ID is the literal key StoreKit uses to look up products in
    /// App Store Connect. The prod ASC app owns the `plus.*` product IDs
    /// (registered to `org.convos.ios`); every other bundle (Dev preview,
    /// Local, App Clip, PR) talks to the Dev ASC app, which owns the
    /// unprefixed `subs.monthly` / `subs.annual` IDs.
    ///
    /// We read the bundle ID directly rather than routing through
    /// `AppEnvironment.isProduction` because the bundle ID is the literal
    /// thing StoreKit checks; routing through ConfigManager + config.json
    /// + AppEnvironment adds three layers of indirection where a build
    /// misconfiguration could put the env in an inconsistent state.
    private static let isProductionBundle: Bool =
        Bundle.main.bundleIdentifier == "org.convos.ios"

    public static let plusMonthly: String = isProductionBundle
        ? "app.convos.subs.plus.monthly"
        : "app.convos.subs.monthly"

    public static let plusAnnual: String = isProductionBundle
        ? "app.convos.subs.plus.annual"
        : "app.convos.subs.annual"

    public static let all: Set<String> = [plusMonthly, plusAnnual]

    public static func tier(for productID: String) -> SubscriptionTier? {
        all.contains(productID) ? .plus : nil
    }

    public static func period(for productID: String) -> SubscriptionPeriod? {
        switch productID {
        case plusMonthly: return .monthly
        case plusAnnual: return .annual
        default: return nil
        }
    }

    public static func productID(for tier: SubscriptionTier, period: SubscriptionPeriod) -> String? {
        switch (tier, period) {
        case (.plus, .monthly): return plusMonthly
        case (.plus, .annual): return plusAnnual
        }
    }
}
