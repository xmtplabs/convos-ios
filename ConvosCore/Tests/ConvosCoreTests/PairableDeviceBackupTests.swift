@testable import ConvosCore
import Foundation
import Testing
@preconcurrency import XMTPiOS

/// Covers the first-install "Pair <device>?" discovery plumbing: filtering
/// iCloud-synced backups down to pairable devices, and minting a signed
/// pairing invite from a backup's private key that survives the joiner's
/// full slug validation (decode, expiry, signature recovery).
@Suite("Pairable Device Backup")
struct PairableDeviceBackupTests {
    private func makeBackup(
        inboxId: String,
        deviceName: String? = nil,
        backedUpAt: Date? = nil
    ) throws -> KeychainIdentityBackup {
        let keys = try KeychainIdentityKeys.generate()
        let identity = KeychainIdentity(inboxId: inboxId, clientId: UUID().uuidString, keys: keys)
        if let backedUpAt {
            return KeychainIdentityBackup(identity: identity, deviceName: deviceName, backedUpAt: backedUpAt)
        }
        // A nil backedUpAt only occurs for blobs written before the
        // metadata fields existed; produce one via the decode path.
        let stamped = KeychainIdentityBackup(identity: identity, deviceName: deviceName, backedUpAt: Date())
        let encoded = try JSONEncoder().encode(stamped)
        var json = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] ?? [:]
        json.removeValue(forKey: "backedUpAt")
        let data = try JSONSerialization.data(withJSONObject: json)
        return try JSONDecoder().decode(KeychainIdentityBackup.self, from: data)
    }

    @Test("Excludes the current install's own identity")
    func excludesCurrentIdentity() throws {
        let own = try makeBackup(inboxId: "own-inbox", backedUpAt: Date())
        let other = try makeBackup(
            inboxId: "other-inbox",
            deviceName: "Other iPhone",
            backedUpAt: Date(timeIntervalSinceNow: -60)
        )

        let pairable = PairableDeviceBackup.pairableBackups(
            from: [own, other],
            excludingInboxId: "own-inbox"
        )

        #expect(pairable.map(\.inboxId) == ["other-inbox"])
        #expect(pairable.first?.deviceName == "Other iPhone")
    }

    @Test("Returns every backup when no identity exists yet")
    func returnsAllBackupsWithoutCurrentIdentity() throws {
        // A nil current inbox means the primary slot is empty - a true
        // first launch checking before silent identity registration
        // completes. That launch is the whole point of the found-device
        // prompt, so nothing may be hidden; there is no self-pair risk
        // because an own backup mirror is only written after its primary.
        let older = try makeBackup(inboxId: "inbox-a", backedUpAt: Date(timeIntervalSince1970: 1_000))
        let newer = try makeBackup(inboxId: "inbox-b", backedUpAt: Date(timeIntervalSince1970: 2_000))

        let pairable = PairableDeviceBackup.pairableBackups(
            from: [older, newer],
            excludingInboxId: nil
        )

        #expect(pairable.map(\.inboxId) == ["inbox-b", "inbox-a"])
    }

    @Test("Excludes backups written after this install's own key")
    func excludesBackupsNewerThanOwnIdentity() throws {
        // Device A installed first (t=1000), Device B second (t=2000).
        // Opening A must not offer to pair with B's newer identity;
        // opening B still offers A's older one.
        let deviceA = try makeBackup(inboxId: "inbox-a", backedUpAt: Date(timeIntervalSince1970: 1_000))
        let deviceB = try makeBackup(inboxId: "inbox-b", backedUpAt: Date(timeIntervalSince1970: 2_000))

        let pairableOnA = PairableDeviceBackup.pairableBackups(
            from: [deviceA, deviceB],
            excludingInboxId: "inbox-a"
        )
        let pairableOnB = PairableDeviceBackup.pairableBackups(
            from: [deviceA, deviceB],
            excludingInboxId: "inbox-b"
        )

        #expect(pairableOnA.isEmpty)
        #expect(pairableOnB.map(\.inboxId) == ["inbox-a"])
    }

    @Test("Keeps backups when ordering can't be established")
    func keepsBackupsWithoutOrderingInformation() throws {
        // An undated foreign backup (legacy blob) stays pairable, and a
        // missing own mirror leaves even newer backups pairable - only a
        // provable newer-than-own ordering suppresses.
        let own = try makeBackup(inboxId: "own-inbox", backedUpAt: Date(timeIntervalSince1970: 1_000))
        let undated = try makeBackup(inboxId: "undated-inbox")
        let newer = try makeBackup(inboxId: "newer-inbox", backedUpAt: Date(timeIntervalSince1970: 2_000))

        let withOwnMirror = PairableDeviceBackup.pairableBackups(
            from: [own, undated],
            excludingInboxId: "own-inbox"
        )
        let withoutOwnMirror = PairableDeviceBackup.pairableBackups(
            from: [newer],
            excludingInboxId: "own-inbox"
        )

        #expect(withOwnMirror.map(\.inboxId) == ["undated-inbox"])
        #expect(withoutOwnMirror.map(\.inboxId) == ["newer-inbox"])
    }

    @Test("Sorts newest backup first, undated backups last")
    func sortsNewestFirst() throws {
        let old = try makeBackup(inboxId: "old", backedUpAt: Date(timeIntervalSince1970: 1_000))
        let new = try makeBackup(inboxId: "new", backedUpAt: Date(timeIntervalSince1970: 2_000))
        let undated = try makeBackup(inboxId: "undated")
        #expect(undated.backedUpAt == nil)

        let pairable = PairableDeviceBackup.pairableBackups(
            from: [undated, old, new],
            excludingInboxId: "unrelated-inbox"
        )

        #expect(pairable.map(\.inboxId) == ["new", "old", "undated"])
    }
}

@Suite("iCloud Device Backups Snapshot")
struct ICloudDeviceBackupsSnapshotTests {
    private func makeBackup(
        inboxId: String,
        deviceName: String? = nil,
        backedUpAt: Date? = nil
    ) throws -> KeychainIdentityBackup {
        let keys = try KeychainIdentityKeys.generate()
        let identity = KeychainIdentity(inboxId: inboxId, clientId: UUID().uuidString, keys: keys)
        if let backedUpAt {
            return KeychainIdentityBackup(identity: identity, deviceName: deviceName, backedUpAt: backedUpAt)
        }
        let stamped = KeychainIdentityBackup(identity: identity, deviceName: deviceName, backedUpAt: Date())
        let encoded = try JSONEncoder().encode(stamped)
        var json = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] ?? [:]
        json.removeValue(forKey: "backedUpAt")
        let data = try JSONSerialization.data(withJSONObject: json)
        return try JSONDecoder().decode(KeychainIdentityBackup.self, from: data)
    }

    @Test("Current identity holding the oldest key is the main device")
    func currentDeviceIsMainWhenOldest() throws {
        let own = try makeBackup(inboxId: "own", backedUpAt: Date(timeIntervalSince1970: 1_000))
        let other = try makeBackup(inboxId: "other", backedUpAt: Date(timeIntervalSince1970: 2_000))

        let snapshot = ICloudDeviceBackupsSnapshot.snapshot(from: [other, own], currentInboxId: "own")

        #expect(snapshot.currentDevice?.inboxId == "own")
        #expect(snapshot.otherDevices.map(\.inboxId) == ["other"])
        #expect(snapshot.mainDeviceInboxId == "own")
        #expect(snapshot.currentDeviceIsMain)
    }

    @Test("Unlike the prompt filter, newer-than-own backups are listed, oldest first, and the oldest is main")
    func listsAllOthersUnfiltered() throws {
        let own = try makeBackup(inboxId: "own", backedUpAt: Date(timeIntervalSince1970: 2_000))
        let older = try makeBackup(inboxId: "older", deviceName: "Old iPhone", backedUpAt: Date(timeIntervalSince1970: 1_000))
        let newer = try makeBackup(inboxId: "newer", backedUpAt: Date(timeIntervalSince1970: 3_000))

        let snapshot = ICloudDeviceBackupsSnapshot.snapshot(from: [newer, own, older], currentInboxId: "own")

        #expect(snapshot.otherDevices.map(\.inboxId) == ["older", "newer"])
        #expect(snapshot.mainDeviceInboxId == "older")
        #expect(!snapshot.currentDeviceIsMain)
    }

    @Test("Undated keys never claim the main designation, and no dated key means no main")
    func undatedKeysDontClaimMain() throws {
        let own = try makeBackup(inboxId: "own", backedUpAt: Date(timeIntervalSince1970: 1_000))
        let undated = try makeBackup(inboxId: "undated")

        let withDatedOwn = ICloudDeviceBackupsSnapshot.snapshot(from: [own, undated], currentInboxId: "own")
        #expect(withDatedOwn.mainDeviceInboxId == "own")

        let allUndated = ICloudDeviceBackupsSnapshot.snapshot(from: [undated], currentInboxId: "own")
        #expect(allUndated.mainDeviceInboxId == nil)
        #expect(!allUndated.currentDeviceIsMain)
    }

    @Test("No identity yet leaves the current device nil and lists everything")
    func nilIdentityListsEverything() throws {
        let first = try makeBackup(inboxId: "a", backedUpAt: Date(timeIntervalSince1970: 1_000))

        let snapshot = ICloudDeviceBackupsSnapshot.snapshot(from: [first], currentInboxId: nil)

        #expect(snapshot.currentDevice == nil)
        #expect(snapshot.otherDevices.map(\.inboxId) == ["a"])
        #expect(!snapshot.currentDeviceIsMain)
    }
}

@Suite("Pairing Invite Signing")
struct PairingInviteSigningTests {
    @Test("Signed invite round-trips through full slug validation")
    func signedInviteRoundTripsAndVerifies() async throws {
        let privateKey = try PrivateKey.generate()
        let expiresAt = Date().addingTimeInterval(300)

        let invite = try await PairingInvite.signed(
            initiatorInboxId: "backup-inbox",
            privateKey: privateKey,
            expiresAt: expiresAt
        )
        let slug = try invite.toURLSafeSlug()
        // fromURLSafeSlug runs the same checks the joiner runs on a
        // scanned QR slug: schema, nonce, expiry, signature recovery.
        let decoded = try PairingInvite.fromURLSafeSlug(slug)

        #expect(decoded.initiatorInboxId == "backup-inbox")
        #expect(decoded.initiatorAddress.lowercased() == privateKey.walletAddress.lowercased())
        #expect(decoded.expiresAt == Int64(expiresAt.timeIntervalSince1970))
    }

    @Test("Expired signed invite is rejected")
    func expiredSignedInviteIsRejected() async throws {
        let privateKey = try PrivateKey.generate()
        let invite = try await PairingInvite.signed(
            initiatorInboxId: "backup-inbox",
            privateKey: privateKey,
            expiresAt: Date().addingTimeInterval(-60)
        )
        let slug = try invite.toURLSafeSlug()

        do {
            _ = try PairingInvite.fromURLSafeSlug(slug)
            Issue.record("Expected an expired invite to be rejected")
        } catch let error as PairingInviteError {
            guard case .expired = error else {
                Issue.record("Expected .expired, got \(error)")
                return
            }
        }
    }

    @Test("Tampered invite fails signature verification")
    func tamperedInviteFailsSignature() async throws {
        let privateKey = try PrivateKey.generate()
        let invite = try await PairingInvite.signed(
            initiatorInboxId: "backup-inbox",
            privateKey: privateKey,
            expiresAt: Date().addingTimeInterval(300)
        )
        // Swap the inboxId while keeping the original signature - the
        // recovered address no longer matches the signed payload.
        let tampered = PairingInvite(
            initiatorInboxId: "attacker-inbox",
            initiatorAddress: invite.initiatorAddress,
            nonce: invite.nonce,
            issuedAt: invite.issuedAt,
            expiresAt: invite.expiresAt,
            signature: invite.signature
        )
        let slug = try tampered.toURLSafeSlug()

        do {
            _ = try PairingInvite.fromURLSafeSlug(slug)
            Issue.record("Expected a tampered invite to be rejected")
        } catch let error as PairingInviteError {
            guard case .signatureInvalid = error else {
                Issue.record("Expected .signatureInvalid, got \(error)")
                return
            }
        }
    }
}
