import { randomBytes } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { basename } from 'node:path';
import {
  getClient,
  inviteToSlug,
  JoinRequestCodec,
  MemberKind,
  parseInvite,
  sendProfileUpdate,
  TypingIndicatorCodec,
  verifyInvite,
} from '@xmtp/convos-cli';
import { parseAppDataForWrite, serializeAppData } from '@xmtp/convos-cli/utils/metadata';
import { getUploadProvider, type UploadProvider } from '@xmtp/convos-cli/utils/upload';
import { getMimeType } from '@xmtp/convos-cli/utils/mime';
import { encodeText, encryptAttachment } from '@xmtp/node-sdk';
import type { LoadTestEnv, UploadConfig } from '../config.js';
import { sleep } from '../util.js';
import type { CreatedGroup, Driver, InviteJoinResult, VuClient } from './driver.js';

// Matches the CLI's ReactionAction / ReactionSchema enums.
const REACTION_ADDED = 1;
const REACTION_REMOVED = 2;
const REACTION_SCHEMA_UNICODE = 1;

// Base62, matching the app's XMTPGroup.generateSecureRandomString charset.
const INVITE_TAG_ALPHABET = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
const INVITE_TAG_LENGTH = 10;

// A group's invite tag (ConversationCustomMetadata.tag) is stored NOT NULL and
// UNIQUE in the app's conversation table. A group created without one reads as
// tag="" on the device, so the second and later such groups collide on the
// unique index and are silently dropped ("UNIQUE constraint failed:
// conversation.inviteTag"), never landing in the conversations list. Mirrors the
// app's ensureInviteTag(); uses crypto randomness (not the run's seeded Rng) so
// tags stay globally unique across runs and never re-collide on the device.
function randomInviteTag(): string {
  return Array.from(randomBytes(INVITE_TAG_LENGTH))
    .map((byte) => INVITE_TAG_ALPHABET.charAt(byte % INVITE_TAG_ALPHABET.length))
    .join('');
}

// node-sdk types are broad generics; we treat clients/groups structurally to
// keep this layer small. skipLibCheck + runtime via tsx makes the `any` casts
// harmless and localized to this file.
type AnyClient = Awaited<ReturnType<typeof getClient>>;
type AnyGroup = any;

function memberInboxId(member: any): string {
  const v = member?.inboxId;
  return typeof v === 'function' ? v.call(member) : v;
}

class LibraryVuClient implements VuClient {
  constructor(
    readonly home: string,
    readonly inboxId: string,
    private readonly client: AnyClient,
    private readonly provider: UploadProvider | null,
  ) {}

  private async group(conversationId: string): Promise<AnyGroup> {
    const convo = await (this.client as any).conversations.getConversationById(conversationId);
    if (!convo) throw new Error(`conversation not found locally: ${conversationId} (try sync)`);
    return convo;
  }

  async createGroup(name: string, memberInboxIds: string[]): Promise<CreatedGroup> {
    const group = await (this.client as any).conversations.createGroup(memberInboxIds, { name });
    // Belt-and-suspenders: ensure the name stuck regardless of option shape.
    if (name) {
      try {
        await group.updateName(name);
      } catch {
        // non-fatal; name option may already have applied
      }
    }
    await this.ensureInviteTag(group);
    return { conversationId: group.id };
  }

  // Set a unique invite tag in the group's custom metadata if it lacks one. The
  // control group gets this from `agent serve`; plain createGroup does not, and
  // without it the device drops every group past the first on the unique
  // inviteTag index. Mirrors the app's XMTPGroup.ensureInviteTag().
  private async ensureInviteTag(group: AnyGroup): Promise<void> {
    const metadata = parseAppDataForWrite(group.appData ?? '');
    if (typeof metadata.tag === 'string' && metadata.tag.length > 0) return;
    metadata.tag = randomInviteTag();
    await group.updateAppData(serializeAppData(metadata));
  }

  async addMembers(conversationId: string, inboxIds: string[]): Promise<void> {
    if (inboxIds.length === 0) return;
    const group = await this.group(conversationId);
    await group.addMembers(inboxIds);
  }

  // Join an invite created on the phone. Mirrors `convos conversations join`:
  // DM a JoinRequest to the invite creator, then poll for the creator's app to
  // add us. The join-request profile omits memberKind so the phone records the
  // controller as a regular user (an "agent" memberKind would tag it as an agent
  // account); the bootstrap caller then republishes an Unspecified ProfileUpdate.
  async joinViaInvite(inviteInput: string, opts: { profileName?: string; timeoutMs?: number } = {}): Promise<InviteJoinResult> {
    const invite = parseInvite(inviteInput);
    if (!(await verifyInvite(invite))) throw new Error('invite signature failed to verify');
    const now = new Date();
    if (invite.expiresAt && invite.expiresAt < now) throw new Error('invite has expired');
    if (invite.conversationExpiresAt && invite.conversationExpiresAt < now) throw new Error('the invited conversation has expired');
    const creatorInboxId = invite.creatorInboxId;
    if (creatorInboxId === this.inboxId) {
      throw new Error('invite was created by the controller — pass the invite generated on the phone');
    }

    const client = this.client as any;
    // createDm is idempotent; reuses any existing DM with the creator.
    const dm = await client.conversations.createDm(creatorInboxId);
    await client.conversations.sync();
    const preJoinGroupIds = new Set<string>();
    for (const convo of await client.conversations.list()) {
      if (convo.id !== dm.id) preJoinGroupIds.add(convo.id);
    }

    const slug = inviteToSlug(invite);
    const joinRequest = { inviteSlug: slug, ...(opts.profileName ? { profile: { name: opts.profileName } } : {}) };
    await dm.send(new JoinRequestCodec().encode(joinRequest));
    // Also send the plain slug for older app clients that predate JoinRequest.
    await dm.sendText(slug);

    const deadline = Date.now() + (opts.timeoutMs ?? 120_000);
    while (Date.now() < deadline) {
      await sleep(2000);
      await client.conversations.sync();
      for (const convo of await client.conversations.list()) {
        if (convo.id === dm.id || preJoinGroupIds.has(convo.id)) continue;
        return { conversationId: convo.id, creatorInboxId };
      }
    }
    throw new Error('timed out waiting for the phone to accept the join request — is the Convos app open on the matching env?');
  }

  async memberInboxIds(conversationId: string): Promise<string[]> {
    const group = await this.group(conversationId);
    const members = await group.members();
    return members.map(memberInboxId).filter((id: unknown): id is string => typeof id === 'string');
  }

  async listConversationIds(): Promise<string[]> {
    const convos = await (this.client as any).conversations.list();
    return convos.map((c: any) => c.id).filter((id: unknown): id is string => typeof id === 'string');
  }

  async sendText(conversationId: string, text: string): Promise<string> {
    const group = await this.group(conversationId);
    return group.sendText(text);
  }

  async sendAttachment(conversationId: string, filePath: string, mimeType?: string): Promise<string> {
    if (!this.provider) throw new Error('no upload provider configured for attachments');
    const content = readFileSync(filePath);
    const filename = basename(filePath);
    const mt = mimeType ?? getMimeType(filePath);
    const encrypted = encryptAttachment({ mimeType: mt, content, filename });
    const url = await this.provider.upload(encrypted.payload, filename, mt);
    const group = await this.group(conversationId);
    return group.sendRemoteAttachment(
      {
        url,
        contentDigest: encrypted.contentDigest,
        secret: encrypted.secret,
        salt: encrypted.salt,
        nonce: encrypted.nonce,
        scheme: 'https',
        contentLength: encrypted.payload.length,
        filename,
      },
      {},
    );
  }

  async sendReaction(conversationId: string, messageId: string, emoji: string, add = true): Promise<void> {
    const group = await this.group(conversationId);
    await group.sendReaction({
      reference: messageId,
      referenceInboxId: '',
      action: add ? REACTION_ADDED : REACTION_REMOVED,
      content: emoji,
      schema: REACTION_SCHEMA_UNICODE,
    });
  }

  async sendReply(conversationId: string, messageId: string, text: string): Promise<string> {
    const group = await this.group(conversationId);
    return group.sendReply({ reference: messageId, content: encodeText(text) });
  }

  async sendTyping(conversationId: string, isTyping: boolean): Promise<void> {
    const group = await this.group(conversationId);
    await group.send(new TypingIndicatorCodec().encode({ isTyping }));
  }

  async sendReadReceipt(conversationId: string): Promise<void> {
    const group = await this.group(conversationId);
    await group.sendReadReceipt();
  }

  async updateName(conversationId: string, name: string): Promise<void> {
    const group = await this.group(conversationId);
    await group.updateName(name);
  }

  async updateDescription(conversationId: string, description: string): Promise<void> {
    const group = await this.group(conversationId);
    await group.updateDescription(description);
  }

  async updateProfile(conversationId: string, name: string): Promise<void> {
    const group = await this.group(conversationId);
    await sendProfileUpdate(group, { name, memberKind: MemberKind.Unspecified });
  }

  async removeMembers(conversationId: string, inboxIds: string[]): Promise<void> {
    if (inboxIds.length === 0) return;
    const group = await this.group(conversationId);
    await group.removeMembers(inboxIds);
  }

  async sync(conversationId?: string): Promise<void> {
    if (conversationId) {
      const group = await this.group(conversationId);
      await group.sync();
    } else {
      await (this.client as any).conversations.syncAll();
    }
  }
}

export class LibraryDriver implements Driver {
  private readonly clients = new Map<string, LibraryVuClient>();
  private readonly providers = new Map<LoadTestEnv, UploadProvider | null>();

  constructor(
    private readonly runEnv: LoadTestEnv,
    private readonly uploadConfig: UploadConfig = {},
  ) {}

  // Build the ConvosConfig getClient/getUploadProvider expect, merging the run's
  // upload settings and falling back to the CONVOS_API_KEY env var.
  private convosConfig(env: LoadTestEnv): Record<string, unknown> {
    return {
      env,
      uploadProvider: this.uploadConfig.provider,
      uploadProviderToken: this.uploadConfig.token,
      uploadProviderGateway: this.uploadConfig.gateway,
      convosApiKey: this.uploadConfig.convosApiKey ?? process.env.CONVOS_API_KEY,
      convosApiBaseUrl: this.uploadConfig.convosApiBaseUrl,
      s3Bucket: this.uploadConfig.s3Bucket,
      s3Region: this.uploadConfig.s3Region,
      s3Endpoint: this.uploadConfig.s3Endpoint,
    };
  }

  private providerFor(env: LoadTestEnv): UploadProvider | null {
    if (!this.providers.has(env)) {
      let provider: UploadProvider | null = null;
      try {
        provider = getUploadProvider(this.convosConfig(env) as any);
      } catch (err) {
        // Misconfigured upload settings (e.g. bad S3 token) must not crash the
        // run — degrade to text-only attachments.
        console.warn(`[upload] provider disabled: ${(err as Error).message}`);
      }
      this.providers.set(env, provider);
    }
    return this.providers.get(env) ?? null;
  }

  hasUploadProvider(): boolean {
    return this.providerFor(this.runEnv) !== null;
  }

  async open(home: string, env: LoadTestEnv): Promise<VuClient> {
    const key = `${home}::${env}`;
    const existing = this.clients.get(key);
    if (existing) return existing;
    const client = await getClient(this.convosConfig(env) as any, home);
    const vu = new LibraryVuClient(home, (client as any).inboxId, client, this.providerFor(env));
    this.clients.set(key, vu);
    return vu;
  }

  async closeAll(): Promise<void> {
    // node-sdk clients don't expose an explicit close in this version; dropping
    // references lets the process release DB handles on exit. Kept for symmetry
    // and future explicit teardown.
    this.clients.clear();
  }
}
