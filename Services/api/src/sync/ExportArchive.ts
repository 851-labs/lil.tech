// A data export's archive (851-2596): a tar (POSIX ustar) streamed from the files it holds, so
// an export of any size is never held in memory or copied. Every entry's size is known up front,
// so the download has a `Content-Length` and the app can show progress.

/** A file in the archive. */
export interface ArchiveEntry {
  /** Its path in the archive, at most 100 bytes. */
  readonly name: string;
  readonly size: number;
  /** Its bytes: given, or opened when the stream reaches it (`null` if it's gone). */
  readonly content: Uint8Array | (() => Promise<ReadableStream<Uint8Array> | null>);
}

const blockSize = 512;

const padding = (size: number) => (blockSize - (size % blockSize)) % blockSize;

/** The archive's size: each entry's header and padded content, then two empty blocks. */
export const archiveSize = (entries: ReadonlyArray<ArchiveEntry>) =>
  entries.reduce((total, entry) => total + blockSize + entry.size + padding(entry.size), 0) +
  2 * blockSize;

/** An octal field of `length` bytes: digits, zero-padded, then a NUL. */
const octal = (value: number, length: number) => value.toString(8).padStart(length - 1, "0");

/** A ustar header for a regular file, modified at `mtime` (Unix seconds). */
export const tarHeader = (name: string, size: number, mtime: number): Uint8Array => {
  const encoder = new TextEncoder();
  const nameBytes = encoder.encode(name);
  if (nameBytes.length > 100) throw new Error(`Archive name too long: ${name}`);
  // 11 octal digits hold up to 8 GiB; entries are snapshot parts and blobs, far smaller.
  if (size >= 8 ** 11) throw new Error(`Archive entry too large: ${name}`);
  const header = new Uint8Array(blockSize);
  const put = (offset: number, text: string) => header.set(encoder.encode(text), offset);
  header.set(nameBytes, 0);
  put(100, octal(0o644, 8)); // mode
  put(108, octal(0, 8)); // uid
  put(116, octal(0, 8)); // gid
  put(124, octal(size, 12));
  put(136, octal(mtime, 12));
  put(148, "        "); // the checksum counts its own field as spaces
  put(156, "0"); // a regular file
  put(257, "ustar\u0000");
  put(263, "00");
  const checksum = header.reduce((sum, byte) => sum + byte, 0);
  put(148, `${octal(checksum, 7)}\u0000 `);
  return header;
};

/**
 * The archive of `entries` as a stream, `archiveSize(entries)` bytes long. An entry whose file is
 * gone, or isn't the size it was listed with, fails the stream, so a download never ends with a
 * silently wrong archive.
 */
export const archiveStream = (
  entries: ReadonlyArray<ArchiveEntry>,
  mtime: number,
): ReadableStream<Uint8Array> => {
  const { readable, writable } = new TransformStream<Uint8Array, Uint8Array>();
  const writer = writable.getWriter();
  const write = async () => {
    for (const entry of entries) {
      await writer.write(tarHeader(entry.name, entry.size, mtime));
      if (entry.content instanceof Uint8Array) {
        await writer.write(entry.content);
      } else {
        const body = await entry.content();
        if (body === null) throw new Error(`${entry.name} is gone`);
        let written = 0;
        const reader = body.getReader();
        try {
          for (let read = await reader.read(); !read.done; read = await reader.read()) {
            written += read.value.length;
            await writer.write(read.value);
          }
        } catch (error) {
          // E.g. the client went away: the file's body isn't read any further.
          await reader.cancel(error).catch(() => {});
          throw error;
        }
        if (written !== entry.size) {
          throw new Error(`${entry.name} has ${written} bytes, not ${entry.size}`);
        }
      }
      const pad = padding(entry.size);
      if (pad > 0) await writer.write(new Uint8Array(pad));
    }
    await writer.write(new Uint8Array(2 * blockSize));
    await writer.close();
  };
  write().catch((error: unknown) => writer.abort(error).catch(() => {}));
  return fixedLength(readable, archiveSize(entries));
};

/**
 * Workers' `FixedLengthStream`, which makes the response's `Content-Length` binding: a plain
 * stream goes out chunked. Tests run outside Workers, without it.
 */
const fixedLength = (stream: ReadableStream<Uint8Array>, length: number) => {
  const { FixedLengthStream } = globalThis as {
    readonly FixedLengthStream?: new (length: number) => TransformStream<Uint8Array, Uint8Array>;
  };
  return FixedLengthStream === undefined
    ? stream
    : stream.pipeThrough(new FixedLengthStream(length));
};

/**
 * The most files one archive holds. Each is an R2 call, and a Worker request makes at most 10,000
 * (`docs/DECISIONS.md`); the rest is room for listing the blobs.
 */
export const maxArchiveFiles = 9_000;
