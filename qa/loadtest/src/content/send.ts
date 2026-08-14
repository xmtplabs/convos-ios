import type { LoadTestConfig } from '../config.js';
import type { VuClient } from '../driver/driver.js';
import type { Rng } from '../rng.js';
import { EMOJI, emojiOnly, linkText, longText, mediumText, shortText } from './corpus.js';
import { generateImage } from './media.js';

export interface SendResult {
  messages: number; // countable messages produced (0 or 1)
  reactions: number; // reactions produced (0 or 1)
}

export interface SendContext {
  rng: Rng;
  config: LoadTestConfig;
  sender: VuClient;
  controller: VuClient; // fallback when the member VU can't send
  conversationId: string;
  getLast: () => string | undefined;
  setLast: (id: string) => void;
  mediaCacheDir: string;
  hasProvider: boolean;
}

type Kind = 'short' | 'medium' | 'long' | 'emoji' | 'link' | 'reply' | 'reaction' | 'attachmentImage';

function pickKind(rng: Rng, config: LoadTestConfig): Kind {
  const mix = config.backfill.contentMix;
  const options: Array<[number, Kind]> = [
    [mix.textShort, 'short'],
    [mix.textMedium, 'medium'],
    [mix.textLong, 'long'],
    [mix.emojiOnly, 'emoji'],
    [mix.link, 'link'],
    [mix.reply, 'reply'],
    [mix.reaction, 'reaction'],
    [mix.attachmentImage, 'attachmentImage'],
  ];
  return options[rng.weightedIndex(options.map(([w]) => w))]![1];
}

// Send one content item chosen from the full configured mix. Falls back to the
// controller if a member VU send fails, and downgrades reply/reaction/attachment
// to text when there's no target message / no upload provider. Used by both
// backfill and churn so content behavior stays identical across phases.
export async function sendMixedContent(sc: SendContext): Promise<SendResult> {
  const { rng, config, sender, controller, conversationId: cid } = sc;

  const sendText = async (text: string): Promise<SendResult> => {
    const id = await sender.sendText(cid, text).catch(() => controller.sendText(cid, text));
    sc.setLast(id);
    return { messages: 1, reactions: 0 };
  };

  switch (pickKind(rng, config)) {
    case 'short':
      return sendText(shortText(rng));
    case 'medium':
      return sendText(mediumText(rng));
    case 'long':
      return sendText(longText(rng, config.backfill.longTextMaxChars));
    case 'emoji':
      return sendText(emojiOnly(rng));
    case 'link':
      return sendText(linkText(rng));
    case 'reply': {
      const last = sc.getLast();
      if (!last) return sendText(shortText(rng));
      const id = await sender.sendReply(cid, last, shortText(rng)).catch(() => controller.sendReply(cid, last, shortText(rng)));
      sc.setLast(id);
      return { messages: 1, reactions: 0 };
    }
    case 'reaction': {
      const last = sc.getLast();
      if (!last) return sendText(emojiOnly(rng));
      await sender.sendReaction(cid, last, rng.pick(EMOJI)).catch(() => {});
      return { messages: 0, reactions: 1 };
    }
    case 'attachmentImage': {
      if (!sc.hasProvider) return sendText(shortText(rng));
      const target = rng.pick(config.backfill.media.imageTargetBytes);
      const img = generateImage(sc.mediaCacheDir, target);
      const id = await sender.sendAttachment(cid, img.path, img.mimeType).catch(() => controller.sendText(cid, shortText(rng)));
      sc.setLast(id);
      return { messages: 1, reactions: 0 };
    }
  }
}
