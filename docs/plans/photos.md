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
- [ ] Photo Library button is always visible next to message input field
- [ ] Tapping button opens iOS photo picker using selective permissions (no permission request needed)
- [ ] User can select a single photo
- [ ] Selected photo uploads in background with progress indicator
- [ ] Background upload continues even if app is backgrounded
- [ ] Failed uploads show clear error message with retry option
- [ ] Photos appear edge-to-edge in my conversation view after sending
- [ ] Photos are compressed to under 1MB while maintaining quality for large iPhone/iPad screens
- [ ] Photos are converted to JPEG format for compatibility

### As a user viewing photos, I want an immersive viewing experience so that I can appreciate shared images

Acceptance criteria:
- [ ] Photos display full bleed (edge-to-edge, full width) in conversation view on iPhone
- [ ] Photos display in traditional message bubbles with max-size on iPad
- [ ] Photo dimensions optimized for viewing on iPhone and iPad screens
- [ ] User can access Save to Camera Roll action from photo UI

### As a privacy-conscious user, I want my photos to be impermanent so that I control my digital footprint

Acceptance criteria:
- [ ] Photos are encrypted in local cache on device
- [ ] Photos are not automatically saved to Camera Roll after receiving
- [ ] User can manually save received photos to Camera Roll with explicit action
- [ ] Photos are cached locally until conversation is deleted
- [ ] Photos are automatically deleted from XMTP network storage after 30 days (backend-managed)
- [ ] User receives no notification when photos are auto-deleted from network storage
- [ ] App communicates that photos are deleted from server after 30 days

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
- Backend handles 30-day deletion (iOS caches until conversation deleted)

**Key Technical Decisions:**
1. Use **PHPickerViewController** for selective permissions (no photo library permission needed)
2. Implement **background upload** using iOS background tasks with progress reporting
3. Convert all photos to **JPEG format** for compatibility
4. Target **under 1MB** file size while maintaining quality on large screens (iPhone Pro Max, iPad)
5. **10MB hard limit** enforced client-side
6. Use existing **Convos S3 infrastructure** for photo storage
7. **Local photo preferences only** (not synced across devices)
8. **Simple caching:** Photos cached locally until conversation is deleted (no age-based cleanup)

---

### Module Organization

#### ConvosCore (Business Logic Layer)

**Services:**
- `PhotoAttachmentService` - Orchestrates upload/download with XMTP RemoteAttachment
- `PhotoStorageManager` - Local encrypted cache management
- `PhotoCleanupService` - Background cleanup (30-day expiration, conversation deletion)
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
- `PhotoPreferenceSheet` - Auto-reveal preference selection
- `PhotoInputButton` - Photo library button for input bar
- `PhotoUploadProgressView` - Upload progress indicator

**ViewModels:**
- `ConversationViewModel` - Extended with photo sending state

---

### Background Upload Architecture

#### iOS Background Modes

**Configuration:**
```xml
<key>UIBackgroundModes</key>
<array>
    <string>fetch</string>
    <string>processing</string>
</array>
```

**Background Task Implementation:**
- Use `BGProcessingTask` for photo uploads
- Register task identifier: `com.convos.backgroundPhotoUpload`
- Schedule upload task when photo is selected
- Continue upload even if app is backgrounded

**Upload Progress:**
- URLSession with background configuration
- Progress reported via delegate callbacks
- Progress stored in database (`PhotoMetadata.uploadProgress`)
- UI observes progress via GRDB publisher
- Architecture supports future Live Activities integration for upload progress

**Upload Queue:**
- Failed uploads saved to database with retry count
- Retry on next app launch
- Exponential backoff for failures
- Maximum 3 retry attempts

#### Upload Flow

```
User selects photo from PHPicker
    ↓
Compress to JPEG (target: <1MB, max: 10MB)
    ↓
Generate XMTP encryption keys (secret, salt, nonce)
    ↓
Encrypt photo data
    ↓
Create PhotoMetadata record (uploadProgress: 0.0)
    ↓
Start background URLSession upload to S3
    ↓
Update uploadProgress in real-time
    ↓
On completion: Create RemoteAttachment with URL
    ↓
Send XMTP message with RemoteAttachment
    ↓
Update PhotoMetadata (uploadProgress: 1.0)
```

**Failure Handling:**
- Upload task fails → Save to retry queue with retry count
- App terminated → Resume on next launch
- Network unavailable → Queue for later
- User can manually retry failed uploads (similar to message retry mechanism)
- User deletes message → Cancel upload task

---

### Photo Storage Architecture

#### Local File Storage

```
Documents/
  photos/
    {inboxId}/
      {conversationId}/
        {messageId}/
          original.enc      # Encrypted original
          thumbnail.enc     # Encrypted thumbnail (300px)
          metadata.json     # Local cache
```

**Encryption:**
- AES-256-GCM per-photo random keys
- Keys stored in iOS Keychain
- Keychain account: `photo-key-{messageId}`
- Accessibility: `kSecAttrAccessibleAfterFirstUnlock`

**Storage Limits:**
- Soft limit: 500MB per inbox
- Hard limit: 1GB total
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
- Local and remote file URLs
- Encryption key identifier (references Keychain)
- Photo dimensions (width, height)
- File size and content type (always JPEG)
- Download/upload status and progress
- Timestamps (created, expires at 30 days on server, downloaded, last viewed)

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

#### RemoteAttachment Flow

**Sending:**
1. Compress photo to JPEG (target: under 1MB, max: 10MB)
2. Use XMTP `RemoteAttachment.encodeEncrypted()` to encrypt
3. Upload encrypted data to S3 via `ConvosAPIClient.uploadAttachment()`
4. Create `RemoteAttachment` object:
```swift
RemoteAttachment(
    url: s3URL,
    secret: secret,  // 32 bytes
    salt: salt,      // 32 bytes
    nonce: nonce,    // 12 bytes
    contentDigest: sha256Hash,
    contentLength: encryptedSize,
    filename: "photo.jpg"
)
```
5. Send via XMTP using `RemoteAttachmentCodec` (already registered)

**Receiving:**
1. XMTP message received with `ContentTypeRemoteAttachment`
2. Extract URL from `attachmentUrls` field
3. Download encrypted data from URL
4. Decrypt using `RemoteAttachment.decryptEncoded()`
5. Generate thumbnail
6. Encrypt both for local storage
7. Update `photoMetadata.downloadStatus = .downloaded`

#### S3 Configuration

**Backend Task:**
- Configure S3 bucket lifecycle rule for 30-day auto-deletion
- Existing `ConvosAPIClient.uploadAttachment()` handles presigned URLs
- No iOS client changes needed for S3 integration

---

### Photo Compression Strategy

#### Requirements
- **Target:** Under 1MB for fast upload/download
- **Quality:** Sharp on large screens (iPhone Pro Max, iPad)
- **Format:** JPEG (convert HEIC if needed)
- **Max input:** 10MB (reject larger photos)

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

#### Photo Input Button

```
MessagesInputView (existing, modified)
    ├── HStack
    │   ├── ProfileAvatarButton (existing)
    │   ├── PhotoInputButton (NEW) ← Photo library icon
    │   ├── TextField (existing, slightly narrower)
    │   └── SendButton (existing)
    └── PhotoUploadProgressView (NEW, conditional overlay)
```

#### Photo Actions

Save to Camera Roll action is accessible directly from the photo in the messages list:
- Long press on photo or tap action button reveals contextual menu
- "Save to Camera Roll" action exports photo to device Camera Roll

---

### UI/UX Details

**Screens Affected:**
- Conversation view (main chat interface, photos display full bleed on iPhone, in bubbles on iPad)
- Message input area (add photo library button)
- New: Photo preference selection sheet
- Settings screen (storage management)

**Navigation Flow:**
1. User taps photo library button → Opens photo picker (PHPicker, selective permissions) → Select single photo → Background upload begins with progress indicator
2. User receives photo (new conversation) → Sees blurred image → Taps to reveal → Preference sheet appears → Select preference → Photo displays
3. User long presses photo or taps action button → Contextual menu appears → Select "Save to Camera Roll" to export

**Visual Design Notes:**
- **iPhone**: Edge-to-edge photos, full width of screen, no message bubble
- **iPad**: Photos in traditional message bubbles with max-size
- Photo dimensions optimized for iPhone and iPad viewing
- Blur effect: Strong gaussian blur with "Tap to reveal" text overlay
- Photo actions: Accessible via long press or action button on photo in messages list
- "Save to Camera Roll" action: Exports photo to device Camera Roll
- Photo library button: Icon next to message input, consistent with messaging patterns
- Upload progress: Linear progress indicator or circular progress overlay

---

## Implementation Phases

### Phase 1: Foundation and Sending
- [ ] Database migrations (photoMetadata, photoPreferences)
- [ ] PhotoStorageManager with local encryption
- [ ] IOSPhotoCompressor (JPEG conversion, size optimization)
- [ ] PHPickerViewController integration
- [ ] BackgroundUploadManager
- [ ] PhotoAttachmentService.prepareForSend()
- [ ] Photo input button in MessagesInputView
- [ ] Upload progress UI
- [ ] Basic PhotoMessageView (edge-to-edge display)

### Phase 2: Receiving and Blur/Reveal
- [ ] PhotoAttachmentService.processIncoming()
- [ ] Download manager with caching
- [ ] Thumbnail generation
- [ ] PhotoBlurOverlayView
- [ ] PhotoPreferenceSheet
- [ ] PhotoPreferencesRepository
- [ ] Reveal gesture handling

### Phase 3: Photo Actions and Save
- [ ] Photo contextual menu (long press or action button)
- [ ] Save to Camera Roll action
- [ ] iPad-specific layout (photos in traditional bubbles with max-size)

### Phase 4: Cleanup and Polish
- [ ] PhotoCleanupService (conversation deletion cleanup)
- [ ] Storage monitoring and LRU eviction
- [ ] Settings UI for storage usage
- [ ] Manual retry for failed uploads (similar to message retry)
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

**BackgroundUploadManager:**
- Upload task creation
- Progress tracking
- Retry queue management
- Upload cancellation
- App backgrounding during upload

**PhotoStorageManager:**
- Local encryption/decryption
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
2. Compress to JPEG
3. Encrypt with XMTP
4. Upload to S3 in background
5. Send RemoteAttachment via XMTP
6. Verify local cache

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
4. Verify keychain keys deleted

**Storage Limits:**
1. Fill storage to 500MB soft limit
2. Verify user warning appears
3. Continue adding photos past 1GB hard limit
4. Verify LRU eviction occurs

### Manual Testing Scenarios
- Send single photo from library in new conversation
- Test background upload when app is backgrounded mid-upload
- Test upload progress UI during sending
- Test manual retry for failed uploads
- Receive first photo in new conversation (verify blur, tap-to-reveal, preference sheet)
- Receive subsequent photos with auto-reveal enabled
- Receive subsequent photos with tap-to-reveal enabled
- View photo full bleed in messages list on iPhone
- View photo in traditional bubble on iPad
- Long press photo to open contextual menu
- Save received photo to Camera Roll via contextual menu
- Delete conversation and verify all photos cleaned up
- Verify offline photo sending queues properly
- Test with very large photos (10MB limit, compression to under 1MB)
- Test with HEIC photos from library (verify JPEG conversion)
- Test on iPad (verify photos display in bubbles with max-size)
- Test storage limits (500MB soft limit warning, 1GB hard limit with LRU eviction)
- Test with low device storage
- Test accessibility with VoiceOver
- Test PHPicker integration (verify no permission prompt)

---

## Dependencies

| Dependency | Status | Notes |
|------------|--------|-------|
| XMTP RemoteAttachmentCodec | ✅ Available | Already registered in InboxStateMachine.swift:913 |
| S3 presigned URL endpoint | ✅ Available | ConvosAPIClient.uploadAttachment() |
| GRDB | ✅ Available | For database migrations |
| PHPickerViewController | ✅ Available | iOS 14+, selective permissions |
| Background Tasks API | ✅ Available | iOS 13+ |
| Keychain | ✅ Available | For encryption keys |

**Action Required:**
- Configure S3 bucket lifecycle rule for 30-day auto-deletion (backend team)

---

## Risks & Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| Background uploads may fail if iOS terminates the task | High | Implement upload queue with retry logic; save progress to database; resume failed uploads on next app launch |
| Photo compression quality may not be acceptable on large screens (iPhone Pro Max, iPad) | High | Test multiple compression strategies; allow slightly larger file sizes (up to 2MB) if quality suffers; use adaptive compression based on photo dimensions |
| 10MB photo limit may be too restrictive for high-quality photos | Medium | Monitor user feedback; limit enforced to prevent excessive upload times; users can use other apps for very large photos if needed |
| Photo encryption/decryption for local storage could impact performance | Medium | Use background threading for crypto operations; implement progressive loading for gallery view; test on minimum supported iOS device |
| Temporary storage could grow unbounded if cleanup fails | Medium | Implement defensive storage limits (e.g., max 500MB per inbox); monitor storage in background; alert user if approaching limit |
| Users may not understand impermanence and lose important photos | Medium | Clear UI messaging about 30-day deletion; prominent "Save to Camera Roll" action in gallery view |
| Tap-to-reveal may create friction for legitimate conversations | Low | Make preference setting easy to change; default to auto-reveal after first reveal |
| PHPicker may have unexpected behavior on older iOS versions | Low | Test on minimum supported iOS version (iOS 26.0); PHPicker is mature API by this point |
| Upload progress may not update smoothly | Medium | Use URLSession background delegate; store progress in DB; UI observes via GRDB |
| Local storage may grow unbounded | Medium | Enforce 500MB per inbox limit; automatic cleanup; user warning in Settings |

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

- **Simplified scope:** Photo picker only, single photo, no screenshot detection
- **Device-optimized UI:** Full bleed on iPhone, traditional bubbles on iPad
- **Background upload:** Reliable upload with progress tracking and retry logic
- **Quality focus:** Under 1MB target with quality optimization for large screens
- **Privacy-first:** Local encryption, tap-to-reveal, backend-managed 30-day deletion
- **Simple storage model:** Photos cached locally until conversation deleted
- **Testable:** Protocol-based design with clear module boundaries
- **Production-ready:** Builds on existing infrastructure (S3, XMTP, GRDB)

The implementation is divided into four phases for incremental delivery, allowing early testing and iteration on the core photo sending/receiving experience before adding polish and edge case handling.
