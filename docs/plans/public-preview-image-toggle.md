# Public Preview Image Toggle

## Overview

Allow users to optionally show their group photo in invite link previews. By default, images are encrypted and not visible in previews (privacy first).

## User Flow

```
Toggle OFF (default, private):
┌─────────────────────────────────────────┐
│ Upload Image                            │
│     ↓                                   │
│ Encrypt → Upload to S3                  │
│     ↓                                   │
│ Store in encryptedGroupImage (metadata) │
│     ↓                                   │
│ Invite preview: No image                │
└─────────────────────────────────────────┘

Toggle ON (public preview):
┌─────────────────────────────────────────┐
│ Upload Image                            │
│     ↓                                   │
│ ┌───────────────┬─────────────────────┐ │
│ │ Encrypt       │ Keep unencrypted    │ │
│ │     ↓         │     ↓               │ │
│ │ Upload to S3  │ Upload to S3        │ │
│ │     ↓         │     ↓               │ │
│ │ Store in      │ Store in            │ │
│ │ metadata      │ publicImageURL      │ │
│ └───────────────┴─────────────────────┘ │
│     ↓                                   │
│ Invite preview: Shows image ✓           │
└─────────────────────────────────────────┘
```

## Logging

```
Toggle OFF:
[INFO] Uploading group image (encrypted only, public preview disabled)
[INFO] Encrypted image uploaded: <s3-url>
[INFO] Public preview URL: none

Toggle ON:
[INFO] Uploading group image (encrypted + public preview)
[INFO] Encrypted image uploaded: <s3-url>
[INFO] Public preview image uploaded: <s3-url>
[INFO] Public preview URL set for invites
```

## Files to Modify

### 1. Database Model
**File:** `ConvosCore/Sources/ConvosCore/Storage/Database Models/DBConversation.swift`

```swift
// Add new fields
let publicImageURLString: String?
let includeInfoInPublicPreview: Bool  // default: false
```

### 2. Database Migration
**File:** `ConvosCore/Sources/ConvosCore/Storage/Migrations/...`

```swift
// Add columns
migrator.registerMigration("addPublicImagePreview") { db in
    try db.alter(table: "conversation") { t in
        t.add(column: "publicImageURLString", .text)
        t.add(column: "includeInfoInPublicPreview", .boolean).defaults(to: false)
    }
}
```

### 3. Image Upload Logic
**File:** `ConvosCore/Sources/ConvosCore/Storage/Writers/ConversationMetadataWriter.swift`

```swift
func updateImage(for conversationId: String, image: ConvosImage) async throws {
    // ... existing code to get group, encrypt, upload ...

    if includeInfoInPublicPreview {
        Log.info("Uploading group image (encrypted + public preview)")

        // Upload encrypted version
        let encryptedUrl = try await uploadEncrypted(image, key: groupKey)
        Log.info("Encrypted image uploaded: \(encryptedUrl)")

        // Upload unencrypted version for public preview
        let publicUrl = try await uploadUnencrypted(image)
        Log.info("Public preview image uploaded: \(publicUrl)")

        // Store both
        try await group.updateEncryptedGroupImage(encryptedRef)
        try await updatePublicImageURL(conversationId: conversationId, url: publicUrl)

        Log.info("Public preview URL set for invites")
    } else {
        Log.info("Uploading group image (encrypted only, public preview disabled)")

        // Upload encrypted version only
        let encryptedUrl = try await uploadEncrypted(image, key: groupKey)
        Log.info("Encrypted image uploaded: \(encryptedUrl)")
        Log.info("Public preview URL: none")

        try await group.updateEncryptedGroupImage(encryptedRef)
        try await clearPublicImageURL(conversationId: conversationId)
    }
}
```

### 4. Invite Generation
**File:** `ConvosCore/Sources/ConvosCore/Invites & Custom Metadata/SignedInvite+Signing.swift`

```swift
// Change from:
if let imageURL = conversation.imageURLString {
    payload.imageURL = imageURL
}

// To:
if let publicImageURL = conversation.publicImageURLString {
    payload.imageURL = publicImageURL
}
```

### 5. UI Toggle
**File:** `Convos/Conversation Detail/Settings/GroupSettingsView.swift` (or similar)

Location: Invitation section, below URL, before "Max members"

```swift
Section("Invitation") {
    // Existing: Invite URL row
    InviteURLRow(url: inviteURL)

    // NEW: Public preview toggle
    Toggle("Show group photo in preview", isOn: $includeInfoInPublicPreview)
        .onChange(of: includeInfoInPublicPreview) { _, newValue in
            Task {
                try await viewModel.updatePublicPreviewSetting(enabled: newValue)
            }
        }

    // Existing: Max members row
    MaxMembersRow(...)
}
```

## No Changes Needed

- ✅ `InvitePayload` protobuf - already has `imageURL` field (legacy non-encrypted)
- ✅ `ConversationCustomMetadata` protobuf - `encryptedGroupImage` stays for members

## Edge Cases

1. **Toggle ON → OFF**: Clear `publicImageURLString`, regenerate invite without image
2. **Toggle OFF → ON**: Upload unencrypted copy of current image, regenerate invite
3. **Change image while ON**: Upload both encrypted and unencrypted versions
4. **Change image while OFF**: Upload only encrypted version

## Privacy Note

Default is OFF (privacy first). Users must explicitly opt-in to show their group photo in public invite previews.
