# Feature: Photo Sending and Receiving

> **Status**: Requirements & Technical Design
> **Author**: PRD Writer Agent, Swift Architect
> **Created**: 2026-01-13
> **Updated**: 2026-01-13
>
> This document combines product requirements with technical architecture.

---

## Overview

Enable users to send and receive photos in conversations with an immersive, privacy-first approach. Photos display edge-to-edge on iPhone (not in message bubbles) and in traditional bubbles on iPad, require explicit consent to view in new conversations, and are impermanent by design. This feature prioritizes user safety and privacy while creating a more engaging visual messaging experience.

---

## Problem Statement

Current messaging apps have three primary issues with photo sharing:

1. **Lack of immersion**: Photos appear in small message bubbles, making the viewing experience less engaging compared to social media apps
2. **Unwanted content exposure**: Images from strangers or spammers appear automatically, exposing users to potentially harmful or offensive content without consent
3. **Privacy and permanence concerns**: Photos stored on centralized servers can be leaked, accessed by third parties, or used for AI training without user knowledge

Users need a way to share photos that is both immersive and safe, with strong privacy guarantees that align with XMTP's end-to-end encryption principles.

---

## Goals

- [ ] Enable users to send a single photo from their Photo Library in conversations (using selective permissions)
- [ ] Display photos edge-to-edge for an immersive viewing experience on iPhone
- [ ] Display photos in traditional bubbles with max-size on iPad
- [ ] Protect users from unwanted image content with tap-to-reveal for new conversations
- [ ] Ensure photos are never stored unencrypted on server
- [ ] Support background upload with progress reporting
- [ ] Auto-delete photos from XMTP network storage after 30 days (handled by backend)
- [ ] Cache photos locally until conversation is deleted
- [ ] Provide users with control over their photo viewing preferences (local, per-conversation)
- [ ] Allow users to save photos to Camera Roll

## Non-Goals

- Not supporting in-app camera capture in this phase (future feature)
- Not supporting multiple photos per message in this phase (will use XMTP multi-attachment content type later)
- Not supporting video sending/receiving (separate future feature)
- Not supporting GIFs or animated images in this iteration
- Not implementing photo editing capabilities
- Not building a photo gallery/album feature outside of conversations
- Not supporting photo forwarding between conversations
- Not implementing photo filters or effects
- Not supporting automatic cloud backup of photos
- Not implementing special screenshot detection or treatment
- Not implementing iOS client-side 30-day auto-deletion (handled by backend)

---

## User Stories

### As a new user receiving photos, I want to control when I see images so that I'm protected from unwanted content

Acceptance criteria:
- [ ] First photo in a new conversation appears blurred with a tap-to-reveal overlay
- [ ] Tapping the blurred photo reveals it permanently for that conversation
- [ ] After revealing first photo, user is prompted to set preference: auto-reveal or continue tap-to-reveal for subsequent photos in this conversation
- [ ] User preference is saved per conversation
- [ ] Blurred state is visually distinct and communicates it's safe to tap

### As a user sending photos, I want to quickly share images from my library so that I can enhance my conversations

Acceptance criteria:
- [x] Photo Library button is always visible next to message input field
- [x] Tapping button opens iOS photo picker using selective permissions (no permission request needed)
- [x] User can select a single photo
- [x] Selected photo appears in composer area as thumbnail preview
- [x] User can remove photo from composer before sending (tap X to delete)
- [x] Tapping send button uploads and sends the photo
- [x] Photos appear edge-to-edge in my conversation view after sending
- [x] Photos are compressed to under 1MB while maintaining quality for large iPhone/iPad screens
- [x] Photos are converted to JPEG format for compatibility

### As a user viewing photos, I want an immersive viewing experience so that I can appreciate shared images

Acceptance criteria:
- [ ] Photos display full bleed (edge-to-edge, full width) in conversation view on iPhone
- [ ] Photos display in traditional message bubbles with max-size on iPad
- [ ] Photo dimensions optimized for viewing on iPhone and iPad screens
- [ ] Long press on photo shows native iOS context menu with "Save to Photo Library" option

### As a privacy-conscious user, I want my photos to be impermanent so that I control my digital footprint

Acceptance criteria:
- [ ] Photos are protected by iOS Data Protection (encrypted at rest by the OS)
- [ ] Photos are not automatically saved to Camera Roll after receiving
- [ ] User can manually save received photos to Camera Roll with explicit action
- [ ] Photos are cached locally until conversation is deleted
- [ ] Photos are automatically deleted from remote storage (backend-managed expiration)
- [ ] EXIF metadata (location, camera info, timestamps) is stripped before upload

### As a user with limited storage, I want photos to be cleaned up automatically so that I don't run out of space

Acceptance criteria:
- [ ] Photo cache storage is monitored
- [ ] Photos from deleted conversations are removed immediately from local storage
- [ ] Storage cleanup happens in background without affecting performance
- [ ] User can view approximate storage used by photos in settings
- [ ] Soft limit of 500MB per inbox with user warning if exceeded

---

## Technical Design

### Executive Summary

**Phase 1 Scope:**
- Photo picker only (no in-app camera)
- Single photo per message (multi-photo support deferred)
- Background upload with iOS background modes
- Full bleed photos on iPhone, traditional bubbles on iPad
- Backend handles media expiration (iOS caches until conversation deleted)

**Key Technical Decisions:**
1. Use **PHPickerViewController** for selective permissions (no photo library permission needed)
2. Implement **background upload** using iOS background tasks with progress reporting
3. Convert all photos to **JPEG format** for compatibility (also strips EXIF metadata for privacy)
4. Target **under 1MB** file size while maintaining quality on large screens (iPhone Pro Max, iPad)
5. **10MB hard limit** enforced client-side
6. Use existing **Convos S3 infrastructure** for photo storage
7. **Local photo preferences only** (not synced across devices)
8. **Simple caching:** Photos cached locally until conversation is deleted
9. **XMTP handles encryption:** SDK manages all encryption for remote storage; no app-level crypto needed
10. **iOS Data Protection:** Local cache is protected by OS-level encryption at rest (no age-based cleanup)

---

### Module Organization

#### ConvosCore (Business Logic Layer)

**Services:**
- `PhotoAttachmentService` - Orchestrates upload/download with XMTP RemoteAttachment
- `PhotoStorageManager` - Local cache management (iOS Data Protection handles security)
- `PhotoCleanupService` - Background cleanup (conversation deletion, storage limits)
- `BackgroundUploadManager` - Manages background upload tasks with iOS background modes

**Repositories:**
- `PhotoMetadataRepository` - GRDB queries for photo metadata
- `PhotoPreferencesRepository` - GRDB queries for reveal preferences (local only)

**Writers:**
- `PhotoMetadataWriter` - Photo metadata mutations
- `PhotoPreferencesWriter` - Preference mutations

**Models:**
- `PhotoMetadata` - Database model
- `PhotoPreferences` - Per-conversation reveal settings

#### ConvosCoreiOS (iOS Platform Layer)

**Services:**
- `IOSPhotoPickerProvider` - PHPickerViewController wrapper (selective permissions)
- `IOSPhotoCompressor` - JPEG conversion and compression (target: under 1MB)
- `IOSPhotoSaver` - Save to Camera Roll

#### Main App (Views/ViewModels)

**Views:**
- `PhotoMessageView` - Full bleed (edge-to-edge) on iPhone, traditional bubble on iPad
- `PhotoBlurOverlayView` - Tap-to-reveal blur effect
- `RevealMediaInfoSheet` - Info sheet shown on first photo reveal
- `PhotoInputButton` - Photo library button for input bar
- `ComposerAttachmentArea` - Generic container for pending attachments (extensible for future types)
- `PhotoAttachmentView` - Photo thumbnail with delete button

**Protocols:**
- `ComposerAttachment` - Protocol for attachment types in composer (photo, future: links, invites, etc.)

**ViewModels:**
- `ConversationViewModel` - Extended with photo sending state

---

### Upload Architecture

#### Upload Flow

```
User selects photo from PHPicker
    ↓
Show photo thumbnail in composer
    ↓
[User taps Send button]
    ↓
Compress to JPEG (target: <1MB, max: 10MB, strip EXIF)
    ↓
XMTP SDK encrypts photo data (generates secret, salt, nonce)
    ↓
Upload encrypted data to S3
    ↓
Send XMTP message with RemoteAttachment
    ↓
Clear composer, show message in conversation
```

**User Actions:**
- **Delete attachment:** Tap X on thumbnail → Remove from composer (no upload started yet)
- **Send:** Triggers compress → encrypt → upload → send flow

**Stage Tracking:**
- `PhotoUploadProgressTracker` tracks stages: preparing, uploading, publishing, completed, failed
- `isSendingPhoto` flag on ConversationViewModel prevents duplicate sends

---

### Photo Storage Architecture

#### Local File Storage

```
Documents/
  photos/
    {inboxId}/
      {conversationId}/
        {messageId}/
          original.jpg      # Decrypted photo (iOS Data Protection)
          thumbnail.jpg     # Thumbnail (300px)
```

**Security Model:**
- XMTP SDK handles all encryption for remote storage (see XMTP Integration section)
- Local files are protected by iOS Data Protection (encrypted at rest by the OS)
- No additional app-level encryption needed for local cache
- Files are stored in the app's private container (not accessible to other apps)

**Storage Limits:**
- Soft limit: 500MB per inbox (user warning)
- Hard limit: 1GB total (LRU eviction)
- Cleanup triggers when exceeding soft limit

#### Cleanup Strategy

**Automatic Cleanup:**
- Photos from deleted conversations (immediate)
- Soft limit enforcement: 500MB per inbox (LRU eviction when exceeded)
- Hard limit enforcement: 1GB total (LRU eviction when exceeded)

**Manual Cleanup:**
- User can clear cache in Settings
- Per-conversation cleanup when conversation deleted (removes all photos)

---

### Database Schema

#### New Tables

**photoMetadata:**
Stores photo-specific metadata for each photo message:
- Links to message and conversation (with cascade delete)
- Local file path (relative to photos directory)
- Remote URL (for re-download if local cache cleared)
- Photo dimensions (width, height)
- File size and content type (always JPEG)
- Download/upload status and progress
- Timestamps (created, downloaded, last viewed)

**Indexes needed:**
- messageId (for lookup by message)
- conversationId + createdAt (for conversation photo queries)
- downloadStatus (for pending download queries)

**photoPreferences:**
Stores per-conversation reveal preferences (local only):
- Conversation reference (primary key, cascade delete)
- Auto-reveal setting (true/false)
- Whether first photo has been revealed
- Last updated timestamp

#### Existing Table Modifications

**No changes needed.** The existing `message.attachmentUrls` field stores remote attachment URLs.

---

### XMTP Integration

#### What the SDK Handles

The XMTP SDK manages all encryption automatically via `RemoteAttachmentCodec`:

- **Encryption keys**: Generates `secret`, `salt`, `nonce`, and `contentDigest`
- **Encryption**: `RemoteAttachmentCodec.encodeEncrypted()` encrypts the attachment data
- **Decryption**: `RemoteAttachment.decryptEncoded()` decrypts using the embedded metadata
- **Key transport**: Encryption metadata is embedded in the XMTP message itself (E2E encrypted)

The iOS app does NOT need to:
- Generate or manage encryption keys
- Store keys in Keychain
- Implement any cryptographic operations

#### RemoteAttachment Flow

**Sending:**
1. Compress photo to JPEG (target: under 1MB, max: 10MB)
2. Use XMTP `RemoteAttachmentCodec.encodeEncrypted()` - SDK encrypts and returns encrypted data + metadata
3. Upload encrypted data to S3 via `ConvosAPIClient.uploadAttachment()`
4. SDK creates `RemoteAttachment` with URL and encryption metadata
5. Send via XMTP using `RemoteAttachmentCodec` (already registered)

**Receiving:**
1. XMTP message received with `ContentTypeRemoteAttachment`
2. Extract `RemoteAttachment` from message (contains URL + encryption metadata)
3. Download encrypted data from URL
4. Use `RemoteAttachment.decryptEncoded()` - SDK decrypts using embedded metadata
5. Generate thumbnail from decrypted image
6. Cache both locally (iOS Data Protection handles security)
7. Update `photoMetadata.downloadStatus = .downloaded`

#### Reference

See [XMTP RemoteAttachment Documentation](https://docs.xmtp.org/chat-apps/content-types/attachments) for SDK details.

---

### Backend Requirements (Out of Scope for iOS)

The following requirements are handled by the backend team and are documented here for completeness. The iOS client does not implement these features.

#### Remote Storage Rules

**Media Expiration:**
- All uploaded media (photos, future attachments) expires automatically after a configurable period (e.g., 30 days)
- Backend enforces this via S3 lifecycle rules or equivalent
- iOS client does not track or enforce remote expiration

**Privacy-Preserving Design:**
- Backend cannot map encrypted data to specific XMTP conversation/topic IDs
- Backend stores opaque encrypted blobs with no metadata linking to conversations
- Upload endpoint returns a URL; no conversation context is passed to backend

**Open Question:** Should backend distinguish between content types (profile photos, group images, media)? This may be unnecessary if all are treated as opaque encrypted blobs. Storing less metadata is preferable, but may complicate analytics. *[NEEDS DECISION]*

#### What Backend Provides to iOS

- Presigned URL endpoint for uploads (`ConvosAPIClient.uploadAttachment()`)
- HTTPS GET access to uploaded files for download
- Automatic cleanup (iOS does not need to request deletion)

---

### Photo Compression Strategy

#### Requirements
- **Target:** Under 1MB for fast upload/download
- **Quality:** Sharp on large screens (iPhone Pro Max, iPad)
- **Format:** JPEG (convert HEIC if needed)
- **Max input:** 10MB (reject larger photos)
- **Privacy:** Strip all EXIF metadata before upload (location, camera info, timestamps, etc.)

#### Compression Algorithm

```swift
func compress(image: UIImage, targetBytes: Int = 1_000_000) -> Data? {
    // Resize if dimensions exceed screen size
    let maxDimension: CGFloat = 2048  // iPhone Pro Max width * 2
    let resized = image.resized(maxDimension: maxDimension)

    // Start with quality 0.85
    var quality: CGFloat = 0.85
    var data = resized.jpegData(compressionQuality: quality)

    // Iteratively reduce quality until under target
    while let currentData = data, currentData.count > targetBytes, quality > 0.5 {
        quality -= 0.05
        data = resized.jpegData(compressionQuality: quality)
    }

    return data
}
```

**Note:** Using `UIImage.jpegData()` automatically strips EXIF metadata since `UIImage` does not preserve it. This is the simplest approach for privacy-preserving compression.

#### Adaptive Strategy

**For different source dimensions:**
- Small photos (< 1000px) → Minimal compression, maintain quality
- Medium photos (1000-2000px) → Target 1MB
- Large photos (> 2000px) → Resize to 2048px max, then compress
- Very large (> 4000px) → Resize more aggressively

**For iPad:**
- Consider device screen size
- Max dimension: 2732px (iPad Pro 12.9" width)
- Slightly higher quality target if original is high-res

---

### Blur/Reveal Mechanism

#### State Machine

```
New Photo Received
    ↓
Check photoPreferences.hasRevealedFirst
    ↓
┌─────────────────┬─────────────────┐
│ false           │ true            │
│ (First photo)   │ (Subsequent)    │
└─────────────────┘                 │
    ↓                               ↓
Show Blurred          Check photoPreferences.autoReveal
Tap to Reveal                       │
    ↓               ┌───────────────┴───────────────┐
User Taps           │ true                │ false  │
    ↓               ↓                     ↓
Set hasRevealedFirst=true     Show Revealed    Show Blurred
Show Preference Sheet                          Tap to Reveal
    ↓                                               ↓
User Selects:                                   User Taps
[Auto-reveal] or [Tap-to-reveal]                    ↓
    ↓                                           Reveal Photo
Set autoReveal preference
Reveal Photo
```

#### Database Operations

```swift
// On first photo received
let prefs = try? photoPreferencesRepo.get(conversationId: id)
if prefs?.hasRevealedFirst == false {
    // Show blurred with tap gesture
}

// On first tap
try photoPreferencesWriter.update(conversationId: id, hasRevealedFirst: true)
// Show preference sheet

// User selects preference
try photoPreferencesWriter.update(conversationId: id, autoReveal: userChoice)
```

---

### UI Component Architecture

#### Photo Message Cell

```
ConversationView (existing)
    ↓
MessagesListView (existing)
    ↓
ForEach(messages)
    ↓
if message.contentType == .attachments
    ↓
PhotoMessageView (NEW)
    ├── AsyncImage (from cache or URL)
    ├── PhotoBlurOverlayView (conditional)
    └── PhotoUploadProgressView (conditional)
```

**Layout:**
- Width: Full screen width (edge-to-edge)
- Height: Calculated from aspect ratio (max: 400pt on iPhone, 600pt on iPad)
- No horizontal padding
- Vertical spacing: 8pt between consecutive photos

#### Composer with Attachments

```
MessagesInputView (existing, modified)
    ├── attachmentPreviewArea (conditional, shows when photo selected)
    │   └── attachmentPreview
    │       ├── Image thumbnail
    │       └── DeleteButton (X in corner)
    │
    └── HStack
        ├── ProfileAvatarButton (existing)
        ├── MessagesMediaInputView (photo library button)
        ├── TextField (existing)
        └── SendButton (existing)
```

**Composer Attachment Area:**
- Shows thumbnail of selected photo above the input field
- Delete button (X) removes the attachment
- Collapses when attachment is removed or message is sent
- Upload happens when user taps Send (not on selection)

#### Photo Actions

Save to Photo Library is accessed via native iOS context menu:
- Long press on photo in messages list shows native context menu
- "Save to Photo Library" action exports photo to device Photo Library
- Uses standard iOS context menu APIs (`.contextMenu` modifier)

---

### UI/UX Details

**Screens Affected:**
- Conversation view (main chat interface, photos display full bleed on iPhone, in bubbles on iPad)
- Message input area (add photo library button)
- New: Photo preference selection sheet
- Settings screen (storage management)

**Navigation Flow:**
1. **Sending:** User taps photo library button → Opens PHPicker → Select photo → Photo appears in composer → User taps Send → Upload and send
2. **Canceling:** Photo in composer → User taps X on thumbnail → Attachment removed
3. **Receiving (new conversation):** Photo received → Blurred image displayed → User taps to reveal → Preference sheet appears → Select preference → Photo displays
4. **Saving:** User long presses photo → Native iOS context menu → Select "Save to Photo Library"

**Visual Design Notes:**
- **iPhone**: Edge-to-edge photos, full width of screen, no message bubble
- **iPad**: Photos in traditional message bubbles with max-size
- Photo dimensions optimized for iPhone and iPad viewing
- Blur effect: Strong gaussian blur with "Tap to reveal" text overlay
- Photo actions: Native iOS context menu on long press (familiar iOS pattern)
- Photo library button: Icon next to message input, consistent with messaging patterns

---

## Implementation Phases

### Phase 1: Foundation and Sending ✅
- [x] Database migrations (photoPreferences)
- [x] IOSPhotoCompressor (JPEG conversion, EXIF stripping, size optimization)
- [x] PHPicker integration (PhotosPicker in MessagesBottomBar)
- [x] PhotoAttachmentService.prepareForSend()
- [x] Composer attachment preview (attachmentPreviewArea in MessagesInputView)
- [x] Photo input button (MessagesMediaInputView)
- [x] Edge-to-edge photo display (AttachmentPlaceholder)
- [x] PhotoUploadProgressTracker (stage tracking for UI feedback)

### Phase 2: Receiving and Blur/Reveal ✅
- [x] RemoteAttachmentLoader (download and decrypt)
- [x] ImageCache (memory + disk caching)
- [x] PhotoBlurOverlayView
- [x] RevealMediaInfoSheet
- [x] PhotoPreferencesRepository
- [x] PhotoPreferencesWriter
- [x] Reveal/hide gesture handling

### Phase 3: Photo Actions and Save ✅
- [x] Native iOS context menu on long press (`.contextMenu` modifier)
- [x] Save to Photo Library action via context menu
- [x] iPad-specific layout (rounded corners, centered with max-width)

### Phase 4: Cleanup and Polish
- [ ] PhotoCleanupService (conversation deletion cleanup)
- [ ] Storage monitoring and LRU eviction
- [ ] Settings UI for storage usage
- [ ] Conversation deletion cleanup
- [ ] Performance optimizations
- [ ] Accessibility labels
- [ ] Error handling improvements

---

## Testing Strategy

### Unit Tests

**PhotoCompressor:**
- JPEG conversion from HEIC
- Compression to target size
- Quality preservation on large screens
- Dimension constraints
- Max size enforcement (10MB)

**PhotoStorageManager:**
- File storage and retrieval
- Storage limit enforcement (soft: 500MB, hard: 1GB)
- LRU eviction when limits exceeded
- Conversation deletion cleanup

**PhotoPreferencesRepository:**
- First reveal logic
- Auto-reveal preference
- Conversation isolation

### Integration Tests

**End-to-End Photo Sending:**
1. Select photo from PHPicker
2. Compress to JPEG (verify EXIF stripped)
3. Encrypt with XMTP SDK (`RemoteAttachmentCodec.encodeEncrypted()`)
4. Upload encrypted data to S3 in background
5. Send RemoteAttachment via XMTP
6. Verify local cache created

**Background Upload:**
1. Start upload
2. Background app
3. Verify upload continues
4. Resume app
5. Verify progress updates

**Photo Cleanup:**
1. Create photos in conversation
2. Delete conversation
3. Verify all local files deleted
4. Verify database records removed

**Storage Limits:**
1. Fill storage to 500MB soft limit
2. Verify user warning appears
3. Continue adding photos past 1GB hard limit
4. Verify LRU eviction occurs

### Manual Testing Scenarios

**Composer Flow:**
- Select photo → Verify it appears in composer attachment area
- Delete attachment from composer (tap X) before sending
- Verify send button is enabled when photo is selected

**Sending:**
- Send single photo from library in new conversation
- Test background upload when app is backgrounded mid-upload
- Verify offline photo sending queues properly
- Test manual retry for failed uploads in composer

**Receiving:**
- Receive first photo in new conversation (verify blur, tap-to-reveal, preference sheet)
- Receive subsequent photos with auto-reveal enabled
- Receive subsequent photos with tap-to-reveal enabled

**Display:**
- View photo full bleed in messages list on iPhone
- View photo in traditional bubble on iPad
- Long press photo to show native context menu
- Save received photo to Photo Library via context menu

**Compression & Privacy:**
- Test with very large photos (10MB limit, compression to under 1MB)
- Test with HEIC photos from library (verify JPEG conversion, EXIF stripped)

**Storage & Cleanup:**
- Delete conversation and verify all photos cleaned up
- Test storage limits (500MB soft limit warning, 1GB hard limit with LRU eviction)
- Test with low device storage

**Accessibility & Edge Cases:**
- Test accessibility with VoiceOver
- Test PHPicker integration (verify no permission prompt)
- Test on iPad (verify photos display in bubbles with max-size)

---

## Dependencies

| Dependency | Status | Notes |
|------------|--------|-------|
| XMTP RemoteAttachmentCodec | ✅ Available | Already registered in InboxStateMachine.swift:913 |
| S3 presigned URL endpoint | ✅ Available | ConvosAPIClient.uploadAttachment() |
| GRDB | ✅ Available | For database migrations |
| PHPickerViewController | ✅ Available | iOS 14+, selective permissions |
| Background Tasks API | ✅ Available | iOS 13+ |

**Action Required (Backend):**
- Configure media expiration policy (see Backend Requirements section)

---

## Risks & Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| Background uploads may fail if iOS terminates the task | High | Implement upload queue with retry logic; save progress to database; resume failed uploads on next app launch |
| Photo compression quality may not be acceptable on large screens (iPhone Pro Max, iPad) | High | Test multiple compression strategies; allow slightly larger file sizes (up to 2MB) if quality suffers; use adaptive compression based on photo dimensions |
| 10MB photo limit may be too restrictive for high-quality photos | Medium | Monitor user feedback; limit enforced to prevent excessive upload times; users can use other apps for very large photos if needed |
| Local storage may grow unbounded if cleanup fails | Medium | Implement defensive storage limits (500MB per inbox soft limit, 1GB hard limit); LRU eviction; user warning in Settings |
| Users may not understand impermanence and lose important photos | Medium | Clear UI messaging about media expiration; prominent "Save to Camera Roll" action |
| Tap-to-reveal may create friction for legitimate conversations | Low | Make preference setting easy to change; default to auto-reveal after first reveal |
| PHPicker may have unexpected behavior on older iOS versions | Low | Test on minimum supported iOS version (iOS 26.0); PHPicker is mature API |
| Upload progress may not update smoothly | Medium | Use URLSession background delegate; store progress in DB; UI observes via GRDB |

---

## Resolved Questions

**Q: What compression strategy best balances file size with quality on large screens?**
A: Will determine optimal strategy during technical implementation through testing.

**Q: Should we implement Live Activities for upload progress?**
A: Defer to future phase. Architecture should support future Live Activities integration.

**Q: How should we handle upload failures when user is offline?**
A: Implement retry mechanism similar to message retry (to be implemented). User can manually retry failed uploads.

**Q: Should there be a global setting to disable tap-to-reveal?**
A: No. Tap-to-reveal is always on for first photos in new conversations (opinionated design decision). Users set per-conversation preference after revealing first photo.

**Q: What happens to locally cached photos if user blocks/unblocks a conversation?**
A: Photos are deleted when conversation is deleted.

**Q: Should we show a visual indicator that photos are impermanent?**
A: No visual indicator needed.

---

## Future Enhancements (Post-Phase 1)

1. **In-app camera capture** (no Camera Roll saving)
2. **Multiple photos per message** (XMTP multi-attachment content type)
3. **Live Activities for upload progress** (like Instagram)
4. **Video support** (separate feature)
5. **Photo editing** (crop, filters)
6. **Photo statistics in Settings** (storage used)
7. **Additional composer attachment types** (via `ComposerAttachment` protocol):
   - URL link previews
   - Invite link previews
   - Location sharing
   - Contact cards

---

## File References

Key files for implementation:

| Component | Path |
|-----------|------|
| Database Migrator | `ConvosCore/Sources/ConvosCore/Storage/SharedDatabaseMigrator.swift` |
| DBMessage | `ConvosCore/Sources/ConvosCore/Storage/Database Models/DBMessage.swift` |
| RemoteAttachment Decoding | `ConvosCore/Sources/ConvosCore/Storage/XMTP DB Representations/DecodedMessage+DBRepresentation.swift` |
| XMTP Client Setup | `ConvosCore/Sources/ConvosCore/Inboxes/InboxStateMachine.swift` (line 913) |
| S3 Upload | `ConvosCore/Sources/ConvosCore/API/ConvosAPIClient.swift` |
| Existing Compression | `ConvosCore/Sources/ConvosCoreiOS/IOSImageCompression.swift` |
| Message Input | `Convos/Conversation Detail/Messages/Messages View Controller/View Controller/Views/MessagesInputView.swift` |
| Conversation ViewModel | `Convos/Conversation Detail/ConversationViewModel.swift` |

---

## References

- [XMTP RemoteAttachment Documentation](https://docs.xmtp.org/chat-apps/content-types/attachments)
- [XIP-17: Remote Attachment Content Type Proposal](https://github.com/xmtp/XIPs/blob/main/XIPs/xip-17-remote-attachment-content-type-proposal.md)
- [XMTP iOS SDK](https://docs.xmtp.org/chat-apps/sdks/ios)
- iOS PHPickerViewController documentation
- iOS Background Tasks framework
- Existing message sending/receiving pipeline
- Existing S3 upload infrastructure

---

## Summary

This document provides comprehensive product requirements and technical architecture for Phase 1 photo support in Convos iOS:

- **Simplified scope:** Photo picker only, single photo per message
- **Device-optimized UI:** Full bleed on iPhone, traditional bubbles on iPad
- **Background upload:** Reliable upload with progress tracking and retry logic
- **Quality focus:** Under 1MB target with quality optimization for large screens
- **Privacy-first:** XMTP handles encryption, EXIF metadata stripped, tap-to-reveal for new conversations
- **Simple storage model:** Photos cached locally until conversation deleted, iOS Data Protection for security
- **Testable:** Protocol-based design with clear module boundaries
- **Production-ready:** Builds on existing infrastructure (S3, XMTP, GRDB)

The implementation is divided into four phases for incremental delivery, allowing early testing and iteration on the core photo sending/receiving experience before adding polish and edge case handling.
