// Just enough PNG for Pixelbook's thumbnails (851-2955): decoding the state catalogs' references
// (8-bit RGBA or RGB, not interlaced, as SnapshotTesting writes them), shrinking them, and
// encoding the result, with Node's zlib only, so publishing runs on Linux, without `sips`.
import { crc32, deflateSync, inflateSync } from "node:zlib";

/** Pixels as RGBA, 8 bits a channel, not premultiplied, row by row. */
export interface Pixels {
  readonly width: number;
  readonly height: number;
  readonly data: Uint8Array;
}

const signature = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);

/** The predictor of PNG's Paeth filter: whichever of left, up and up-left is nearest. */
const paeth = (a: number, b: number, c: number) => {
  const p = a + b - c;
  const pa = Math.abs(p - a);
  const pb = Math.abs(p - b);
  const pc = Math.abs(p - c);
  return pa <= pb && pa <= pc ? a : pb <= pc ? b : c;
};

/** Decodes an 8-bit RGBA or RGB PNG that isn't interlaced, and throws on any other. */
export const decodePng = (bytes: Uint8Array): Pixels => {
  const buffer = Buffer.from(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  if (!buffer.subarray(0, 8).equals(signature)) throw new Error("It isn't a PNG.");
  let header: Buffer | undefined;
  const compressed: Buffer[] = [];
  // Chunks follow the signature: length, type, data, CRC.
  for (let offset = 8; offset + 8 <= buffer.length;) {
    const length = buffer.readUInt32BE(offset);
    const type = buffer.toString("latin1", offset + 4, offset + 8);
    const data = buffer.subarray(offset + 8, offset + 8 + length);
    if (type === "IHDR") header = data;
    else if (type === "IDAT") compressed.push(data);
    else if (type === "IEND") break;
    offset += 12 + length;
  }
  if (header === undefined) throw new Error("The PNG has no header.");
  const width = header.readUInt32BE(0);
  const height = header.readUInt32BE(4);
  const [depth, colorType, , , interlace] = header.subarray(8, 13);
  const channels = colorType === 6 ? 4 : colorType === 2 ? 3 : 0;
  if (depth !== 8 || channels === 0 || interlace !== 0) {
    throw new Error(
      `Only 8-bit RGBA or RGB PNGs that aren't interlaced are read, not ${depth}-bit, color ` +
        `type ${colorType}, interlace ${interlace}.`,
    );
  }
  const raw = inflateSync(Buffer.concat(compressed));
  const stride = width * channels;
  if (raw.length < (stride + 1) * height) throw new Error("The PNG's pixels are cut short.");
  const rows = new Uint8Array(stride * height);
  for (let y = 0; y < height; y++) {
    const filter = raw[y * (stride + 1)];
    const input = y * (stride + 1) + 1;
    const output = y * stride;
    const above = output - stride;
    for (let x = 0; x < stride; x++) {
      const value = raw[input + x] ?? 0;
      const left = x >= channels ? (rows[output + x - channels] ?? 0) : 0;
      const up = y > 0 ? (rows[above + x] ?? 0) : 0;
      const upLeft = y > 0 && x >= channels ? (rows[above + x - channels] ?? 0) : 0;
      const predicted =
        filter === 0
          ? 0
          : filter === 1
            ? left
            : filter === 2
              ? up
              : filter === 3
                ? (left + up) >> 1
                : filter === 4
                  ? paeth(left, up, upLeft)
                  : Number.NaN;
      if (Number.isNaN(predicted)) throw new Error(`Row ${y} has an unknown filter, ${filter}.`);
      rows[output + x] = (value + predicted) & 0xff;
    }
  }
  if (channels === 4) return { width, height, data: rows };
  const data = new Uint8Array(width * height * 4);
  for (let pixel = 0; pixel < width * height; pixel++) {
    data[pixel * 4] = rows[pixel * 3] ?? 0;
    data[pixel * 4 + 1] = rows[pixel * 3 + 1] ?? 0;
    data[pixel * 4 + 2] = rows[pixel * 3 + 2] ?? 0;
    data[pixel * 4 + 3] = 255;
  }
  return { width, height, data };
};

/**
 * `pixels` `divisor` times smaller in each dimension (rounded, at least 1), each pixel the average
 * of the block it covers, weighted by alpha, so transparent pixels' colors don't bleed in.
 */
export const shrink = (pixels: Pixels, divisor: number): Pixels => {
  const width = Math.max(1, Math.round(pixels.width / divisor));
  const height = Math.max(1, Math.round(pixels.height / divisor));
  const data = new Uint8Array(width * height * 4);
  const source = pixels.data;
  for (let y = 0; y < height; y++) {
    const top = Math.floor((y * pixels.height) / height);
    const bottom = Math.max(top + 1, Math.floor(((y + 1) * pixels.height) / height));
    for (let x = 0; x < width; x++) {
      const left = Math.floor((x * pixels.width) / width);
      const right = Math.max(left + 1, Math.floor(((x + 1) * pixels.width) / width));
      let red = 0;
      let green = 0;
      let blue = 0;
      let alpha = 0;
      for (let sy = top; sy < bottom; sy++) {
        for (let sx = left; sx < right; sx++) {
          const index = (sy * pixels.width + sx) * 4;
          const a = source[index + 3] ?? 0;
          red += (source[index] ?? 0) * a;
          green += (source[index + 1] ?? 0) * a;
          blue += (source[index + 2] ?? 0) * a;
          alpha += a;
        }
      }
      const out = (y * width + x) * 4;
      const count = (bottom - top) * (right - left);
      if (alpha > 0) {
        data[out] = Math.round(red / alpha);
        data[out + 1] = Math.round(green / alpha);
        data[out + 2] = Math.round(blue / alpha);
      }
      data[out + 3] = Math.round(alpha / count);
    }
  }
  return { width, height, data };
};

const chunk = (type: string, data: Buffer) => {
  const length = Buffer.alloc(4);
  length.writeUInt32BE(data.length);
  const typed = Buffer.concat([Buffer.from(type, "latin1"), data]);
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(crc32(typed));
  return Buffer.concat([length, typed, crc]);
};

/** An 8-bit RGBA PNG of `pixels`, every row Paeth-filtered, which suits flat UI well. */
export const encodePng = (pixels: Pixels): Buffer => {
  const { width, height, data } = pixels;
  const stride = width * 4;
  const raw = Buffer.alloc((stride + 1) * height);
  for (let y = 0; y < height; y++) {
    const row = y * (stride + 1);
    raw[row] = 4;
    for (let x = 0; x < stride; x++) {
      const index = y * stride + x;
      const left = x >= 4 ? (data[index - 4] ?? 0) : 0;
      const up = y > 0 ? (data[index - stride] ?? 0) : 0;
      const upLeft = y > 0 && x >= 4 ? (data[index - stride - 4] ?? 0) : 0;
      raw[row + 1 + x] = ((data[index] ?? 0) - paeth(left, up, upLeft)) & 0xff;
    }
  }
  const header = Buffer.alloc(13);
  header.writeUInt32BE(width, 0);
  header.writeUInt32BE(height, 4);
  // 8 bits a channel, RGBA, deflate, adaptive filtering, not interlaced.
  header.set([8, 6, 0, 0, 0], 8);
  return Buffer.concat([
    signature,
    chunk("IHDR", header),
    chunk("IDAT", deflateSync(raw, { level: 9 })),
    chunk("IEND", Buffer.alloc(0)),
  ]);
};
