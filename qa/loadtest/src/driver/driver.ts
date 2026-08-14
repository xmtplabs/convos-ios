// The driver abstracts "one fake user acting on the XMTP network" so the phases
// don't care whether calls go through the in-process library (LibraryDriver,
// default) or a CLI subprocess (ServeDriver, fallback). Slice 1 uses the
// library for bulk actions and a serve subprocess only for the one-time
// bootstrap join-processing (see bootstrap.ts).

import type { LoadTestEnv } from '../config.js';

export interface CreatedGroup {
  conversationId: string;
}

export interface InviteJoinResult {
  /** The conversation the controller was added to after joining. */
  conversationId: string;
  /** The invite's creator inbox id (= the phone's stable inbox id). */
  creatorInboxId: string;
}

// A handle to one virtual user's client, scoped to a home directory (= one XMTP
// inbox, per ADR 011). A single Node process can hold many of these concurrently.
export interface VuClient {
  readonly home: string;
  readonly inboxId: string;

  /** Create a group; optionally seed it with member inbox ids at creation. */
  createGroup(name: string, memberInboxIds: string[]): Promise<CreatedGroup>;

  /** Add members to an existing group (emits MLS welcomes). */
  addMembers(conversationId: string, inboxIds: string[]): Promise<void>;

  /**
   * Join a conversation from an invite slug or URL (created on the phone). DMs a
   * join request to the invite's creator and waits for the creator's app to add
   * this client, then returns the joined conversation and the creator inbox id.
   */
  joinViaInvite(inviteInput: string, opts?: { profileName?: string; timeoutMs?: number }): Promise<InviteJoinResult>;

  /** Member inbox ids of a group. */
  memberInboxIds(conversationId: string): Promise<string[]>;

  /** Ids of all conversations (groups and DMs) this client knows locally. */
  listConversationIds(): Promise<string[]>;

  sendText(conversationId: string, text: string): Promise<string>;

  /** Upload + send a file as a remote attachment. Requires an upload provider. */
  sendAttachment(conversationId: string, filePath: string, mimeType?: string): Promise<string>;

  /** React to a message. `add` toggles between Added (true) and Removed. */
  sendReaction(conversationId: string, messageId: string, emoji: string, add?: boolean): Promise<void>;

  /** Reply to a message with text. */
  sendReply(conversationId: string, messageId: string, text: string): Promise<string>;

  /** Silent typing indicator (no message, no push). */
  sendTyping(conversationId: string, isTyping: boolean): Promise<void>;

  /** Silent read receipt (no message, no push). */
  sendReadReceipt(conversationId: string): Promise<void>;

  updateName(conversationId: string, name: string): Promise<void>;
  updateDescription(conversationId: string, description: string): Promise<void>;

  /** Update this sender's own display name within a group (ProfileUpdate). */
  updateProfile(conversationId: string, name: string): Promise<void>;

  /** Remove members from a group (used by teardown to unenroll the phone). */
  removeMembers(conversationId: string, inboxIds: string[]): Promise<void>;

  /** Pull the latest state for a group / all groups from the network. */
  sync(conversationId?: string): Promise<void>;
}

export interface Driver {
  /** Open (creating on first use) the client for a home dir on the given env. */
  open(home: string, env: LoadTestEnv): Promise<VuClient>;
  /** Whether a working upload provider is configured (attachments possible). */
  hasUploadProvider(): boolean;
  /** Release all open clients (frees SQLite locks). */
  closeAll(): Promise<void>;
}
