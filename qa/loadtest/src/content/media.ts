import { randomBytes } from 'node:crypto';
import { existsSync, mkdirSync, writeFileSync, statSync } from 'node:fs';
import { join } from 'node:path';
import { crc32, deflateSync } from 'node:zlib';

// Dependency-free media generation. We emit valid PNGs of random pixels so the
// app actually decodes them (exercising the image-decode + cache + jetsam
// pressure axes) and so file size is controllable: random RGBA is near
// incompressible, so bytes ~= width*height*4. Images are cached per target size
// under the run's media-cache so repeated sends reuse one file.

function pngChunk(type: string, data: Buffer): Buffer {
  const typeBuf = Buffer.from(type, 'ascii');
  const len = Buffer.alloc(4);
  len.writeUInt32BE(data.length, 0);
  const crcBuf = Buffer.alloc(4);
  crcBuf.writeUInt32BE(crc32(Buffer.concat([typeBuf, data])) >>> 0, 0);
  return Buffer.concat([len, typeBuf, data, crcBuf]);
}

function encodePng(width: number, height: number, pixels: Buffer): Buffer {
  const signature = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(width, 0);
  ihdr.writeUInt32BE(height, 4);
  ihdr.writeUInt8(8, 8); // bit depth
  ihdr.writeUInt8(6, 9); // color type RGBA
  ihdr.writeUInt8(0, 10); // compression
  ihdr.writeUInt8(0, 11); // filter
  ihdr.writeUInt8(0, 12); // interlace

  // Prefix each scanline with filter byte 0.
  const stride = width * 4;
  const raw = Buffer.alloc((stride + 1) * height);
  for (let y = 0; y < height; y++) {
    raw[y * (stride + 1)] = 0;
    pixels.copy(raw, y * (stride + 1) + 1, y * stride, (y + 1) * stride);
  }
  const idat = deflateSync(raw, { level: 1 });

  return Buffer.concat([
    signature,
    pngChunk('IHDR', ihdr),
    pngChunk('IDAT', idat),
    pngChunk('IEND', Buffer.alloc(0)),
  ]);
}

const generated = new Set<string>();

export interface GeneratedMedia {
  path: string;
  bytes: number;
  mimeType: string;
  filename: string;
}

// Generate (or reuse) a PNG whose byte size is approximately `targetBytes`.
export function generateImage(cacheDir: string, targetBytes: number): GeneratedMedia {
  mkdirSync(cacheDir, { recursive: true });
  const kb = Math.round(targetBytes / 1024);
  const filename = `img-${kb}kb.png`;
  const path = join(cacheDir, filename);
  if (!generated.has(path) || !existsSync(path)) {
    // bytes ~= side*side*4 -> side = sqrt(target/4). Clamp to sane pixel bounds.
    const side = Math.min(2600, Math.max(64, Math.round(Math.sqrt(targetBytes / 4))));
    const pixels = randomBytes(side * side * 4);
    writeFileSync(path, encodePng(side, side, pixels));
    generated.add(path);
  }
  return { path, bytes: statSync(path).size, mimeType: 'image/png', filename };
}
