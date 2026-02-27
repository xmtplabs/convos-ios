// ConvosInvites - Full invite system with XMTP SDK integration
//
// This module provides high-level APIs for creating and processing
// XMTP group invites, built on top of ConvosInvitesCore.
//
// ## Components
//
// - `InviteCoordinator`: High-level API for invite management
// - `JoinRequestProcessor`: Process incoming DM join requests
// - `InviteTagStorage`: Read/write invite tags in group appData
// - `InviteJoinErrorCodec`: Custom content type for join error feedback
//
// ## Usage
//
// ```swift
// import ConvosInvites
// import XMTPiOS
//
// // Create coordinator
// let coordinator = InviteCoordinator(
//     client: xmtpClient,
//     privateKeyProvider: { inboxId in
//         // Return the private key for this inbox
//         return try keychain.getPrivateKey(for: inboxId)
//     }
// )
//
// // Create an invite
// let invite = try await coordinator.createInvite(
//     for: group,
//     options: InviteOptions(name: "My Group", expiresAfter: .hours(24))
// )
//
// // Process join requests
// coordinator.delegate = self
// try await coordinator.startProcessingJoinRequests()
// ```

@_exported import ConvosInvitesCore
