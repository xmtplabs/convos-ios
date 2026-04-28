import ConvosConnections
import Foundation

/// Stateless orchestrator that bridges the `CapabilityRequest` wire type and the
/// `CapabilityResolver`. The picker view calls `computeLayout` on appear, holds the
/// user's tentative selection, and calls `commit` / `deny` / `cancel` when the user
/// taps a button.
///
/// All three exit paths return a `CapabilityRequestResult` ready to send back to the
/// conversation; only `commit` mutates resolver state.
public struct CapabilityRequestHandler: Sendable {
    public init() {}

    /// Snapshot the registry + resolver state for this request and decide which card
    /// variant to render.
    public func computeLayout(
        request: CapabilityRequest,
        registry: any CapabilityProviderRegistry,
        resolver: any CapabilityResolver,
        conversationId: String
    ) async -> CapabilityPickerLayout {
        let providersForSubject = await registry.providers(for: request.subject)
        let summaries = await Self.summarize(
            providers: providersForSubject,
            requestedCapability: request.capability
        )
        // Linked AND supports the requested verb. A provider that's linked but doesn't
        // implement the verb (e.g. Strava is read-only and the agent asks for
        // writeCreate) shouldn't be eligible for default-approve / pre-selection.
        let linkedSummaries = summaries.filter { $0.linked && $0.supportsCapability }

        // Look at existing resolutions on this subject so we can short-circuit to the
        // verb-consent card when the answer is already implied by a previous verb's
        // resolution.
        let existingResolutions = await Self.resolutionsForSubject(
            subject: request.subject,
            conversationId: conversationId,
            resolver: resolver
        )

        // 1) Verb-consent shortcut. If the same subject already has a resolution for
        // some other verb, and the new verb hasn't been resolved yet, default to the
        // existing provider(s). For non-federating subjects this is mechanical — the
        // user picked one, all subsequent verbs route there. For federating subjects on
        // a write verb, fall back to the *first* (alphabetical) provider in the read
        // resolution; the card is still single-select because writes never federate.
        if let consent = verbConsentLayout(
            request: request,
            summaries: summaries,
            existingResolutions: existingResolutions
        ) {
            return consent
        }

        // 2) Variant 1, 2a, 2b, or 3 by linked-provider count + federation rules.
        let allowsFederationOnRead = request.subject.allowsReadFederation && request.capability == .read

        if linkedSummaries.isEmpty {
            return CapabilityPickerLayout(
                request: request,
                variant: .connectAndApprove,
                providers: summaries.filter(\.supportsCapability),
                defaultSelection: []
            )
        }

        if linkedSummaries.count == 1, let only = linkedSummaries.first {
            return CapabilityPickerLayout(
                request: request,
                variant: .confirm,
                providers: summaries,
                defaultSelection: [only.id]
            )
        }

        let variant: CapabilityPickerLayout.Variant = allowsFederationOnRead ? .multiSelect : .singleSelect
        let defaultSelection = honorPreferredProviders(
            request: request,
            linked: linkedSummaries,
            allowFederation: allowsFederationOnRead
        )
        return CapabilityPickerLayout(
            request: request,
            variant: variant,
            providers: summaries,
            defaultSelection: defaultSelection
        )
    }

    /// User tapped Approve. Validates the selection against the cardinality rules,
    /// persists it through the resolver, and returns the `.approved` result envelope.
    public func commit(
        request: CapabilityRequest,
        approvedProviderIds: Set<ProviderID>,
        resolver: any CapabilityResolver,
        conversationId: String
    ) async throws -> CapabilityRequestResult {
        try await resolver.setResolution(
            approvedProviderIds,
            subject: request.subject,
            capability: request.capability,
            conversationId: conversationId
        )
        return CapabilityRequestResult(
            requestId: request.requestId,
            status: .approved,
            subject: request.subject,
            capability: request.capability,
            providers: approvedProviderIds.sorted(by: { $0.rawValue < $1.rawValue })
        )
    }

    /// User tapped Deny. No resolver mutation.
    public func deny(request: CapabilityRequest) -> CapabilityRequestResult {
        CapabilityRequestResult(
            requestId: request.requestId,
            status: .denied,
            subject: request.subject,
            capability: request.capability
        )
    }

    /// Card was dismissed without an explicit choice (app backgrounded, etc.). No
    /// resolver mutation.
    public func cancel(request: CapabilityRequest) -> CapabilityRequestResult {
        CapabilityRequestResult(
            requestId: request.requestId,
            status: .cancelled,
            subject: request.subject,
            capability: request.capability
        )
    }

    // MARK: - Internals

    private static func summarize(
        providers: [any CapabilityProvider],
        requestedCapability: ConnectionCapability
    ) async -> [CapabilityPickerLayout.ProviderSummary] {
        var out: [CapabilityPickerLayout.ProviderSummary] = []
        for provider in providers {
            let linked = await provider.linkedByUser
            out.append(
                CapabilityPickerLayout.ProviderSummary(
                    id: provider.id,
                    displayName: provider.displayName,
                    iconName: provider.iconName,
                    subject: provider.subject,
                    linked: linked,
                    supportsCapability: provider.capabilities.contains(requestedCapability),
                    subjectNounPhrase: provider.subjectNounPhrase
                )
            )
        }
        out.sort(by: { $0.id.rawValue < $1.id.rawValue })
        return out
    }

    private static func resolutionsForSubject(
        subject: CapabilitySubject,
        conversationId: String,
        resolver: any CapabilityResolver
    ) async -> [ConnectionCapability: Set<ProviderID>] {
        var result: [ConnectionCapability: Set<ProviderID>] = [:]
        for verb in ConnectionCapability.allCases {
            let providers = await resolver.resolution(
                subject: subject,
                capability: verb,
                conversationId: conversationId
            )
            if !providers.isEmpty {
                result[verb] = providers
            }
        }
        return result
    }

    private func verbConsentLayout(
        request: CapabilityRequest,
        summaries: [CapabilityPickerLayout.ProviderSummary],
        existingResolutions: [ConnectionCapability: Set<ProviderID>]
    ) -> CapabilityPickerLayout? {
        // The new verb already has a resolution → no card needed at all; caller
        // shouldn't have invoked this path. Defensive nil — picker layer treats nil
        // as "no shortcut, fall through to the regular variant logic."
        if existingResolutions[request.capability] != nil { return nil }

        // No other verb resolved → no shortcut.
        let otherResolutions = existingResolutions.filter { $0.key != request.capability }
        guard !otherResolutions.isEmpty else { return nil }

        // Federation-aware default: writes default to a single provider (writes never
        // federate), reads on federating subjects can default to a set.
        let defaultSet: Set<ProviderID> = {
            if request.capability.isWrite {
                // Writes — pick a single provider. Prefer the union of write-verb
                // resolutions for stability, falling back to the smallest-id read
                // resolution member (deterministic).
                let writeUnion = otherResolutions
                    .filter { $0.key.isWrite }
                    .values
                    .reduce(Set<ProviderID>()) { $0.union($1) }
                if let pick = writeUnion.min(by: { $0.rawValue < $1.rawValue }) {
                    return [pick]
                }
                let readUnion = otherResolutions[.read] ?? []
                if let pick = readUnion.min(by: { $0.rawValue < $1.rawValue }) {
                    return [pick]
                }
                return []
            }
            // Read on a federating subject — union all other-verb resolutions and use
            // them all as the default.
            if request.subject.allowsReadFederation {
                return otherResolutions.values.reduce(Set<ProviderID>()) { $0.union($1) }
            }
            // Read on a non-federating subject — single provider, take whichever is
            // currently resolved (writes are by definition single, so this is well-
            // defined when only one provider is involved across verbs).
            let union = otherResolutions.values.reduce(Set<ProviderID>()) { $0.union($1) }
            if let pick = union.min(by: { $0.rawValue < $1.rawValue }) {
                return [pick]
            }
            return []
        }()

        // If the default set is empty (e.g. all other-verb resolutions referenced
        // providers that have since been unregistered), fall through to the regular
        // variant logic — the verb-consent shortcut needs a real default to be useful.
        guard !defaultSet.isEmpty else { return nil }

        // Filter the picker's provider list to only those in the default set AND
        // that support the requested verb. Fallback paths in this method can pull a
        // read-only provider into `defaultSet` when the new verb is a write — without
        // the `supportsCapability` filter the card would offer a row that can't
        // actually fulfill the request. If `relevant` ends up empty, fall back to the
        // standard variant logic so we don't render a card with `providers: []` and a
        // non-empty `defaultSelection`.
        let relevant = summaries.filter { defaultSet.contains($0.id) && $0.supportsCapability }
        guard !relevant.isEmpty else { return nil }
        return CapabilityPickerLayout(
            request: request,
            variant: .verbConsent,
            providers: relevant,
            defaultSelection: defaultSet
        )
    }

    private func honorPreferredProviders(
        request: CapabilityRequest,
        linked: [CapabilityPickerLayout.ProviderSummary],
        allowFederation: Bool
    ) -> Set<ProviderID> {
        guard let preferred = request.preferredProviders, !preferred.isEmpty else { return [] }
        let linkedIds = Set(linked.map(\.id))
        let satisfiable = preferred.filter { linkedIds.contains($0) }
        guard !satisfiable.isEmpty else { return [] }
        if !allowFederation {
            // Single-select picker: take the first preferred that's linked.
            if let first = satisfiable.first {
                return [first]
            }
            return []
        }
        return Set(satisfiable)
    }
}
