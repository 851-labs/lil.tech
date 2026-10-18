// Generates a core D1 migration (migrations/core) when src/core/Schema.ts has changed, or with
// --check fails if it has changed without one, or if a migration already on main was edited or
// removed (Alchemy refuses those at deploy, as rewritten history). drizzle-kit only writes a
// migration when the schema differs from the latest snapshot, so the check runs it on a copy.
import { execFileSync } from "node:child_process";
import {
  cpSync,
  existsSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const here = fileURLToPath(new URL("..", import.meta.url));
const migrations = join(here, "migrations/core");
const drizzleKit = join(here, "node_modules/.bin/drizzle-kit");

const git = (...args: ReadonlyArray<string>) =>
  execFileSync("git", args, { cwd: here, encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] });

/** Migrations on main whose `migration.sql` (what Alchemy hashes) differs here, or is gone. */
const editedApplied = (): ReadonlyArray<string> => {
  let files: ReadonlyArray<string>;
  try {
    files = git("ls-tree", "-r", "--name-only", "--full-name", "origin/main", "migrations/core")
      .split("\n")
      .filter((file) => /\/migrations\/core\/\d{14}_[^/]+\/migration\.sql$/.test(file));
  } catch {
    return []; // No origin/main to compare with, e.g. a clone that hasn't fetched it.
  }
  const root = git("rev-parse", "--show-toplevel").trim();
  return files.filter((file) => {
    const path = join(root, file);
    return !existsSync(path) || readFileSync(path, "utf8") !== git("show", `origin/main:${file}`);
  });
};

if (process.argv.includes("--check")) {
  const edited = editedApplied();
  if (edited.length > 0) {
    console.error(
      `Migrations already on main were changed or removed: ${edited.join(", ")}. Restore them, ` +
        "and change the schema with a new migration instead.",
    );
    process.exit(1);
  }
  const scratch = mkdtempSync(join(tmpdir(), "lil-migrations-"));
  try {
    const out = join(scratch, "core");
    cpSync(migrations, out, { recursive: true });
    const config = join(scratch, "drizzle.config.mjs");
    const schema = join(here, "src/core/Schema.ts");
    writeFileSync(
      config,
      `export default ${JSON.stringify({ dialect: "sqlite", schema, out })};\n`,
    );
    const before = readdirSync(out).length;
    try {
      execFileSync(drizzleKit, ["generate", "--config", config], { cwd: here, stdio: "pipe" });
    } catch (error) {
      const { stdout, stderr } = error as { stdout?: Buffer; stderr?: Buffer };
      console.error(`drizzle-kit failed:\n${stdout?.toString() ?? ""}${stderr?.toString() ?? ""}`);
      process.exit(1);
    }
    if (readdirSync(out).length !== before) {
      console.error(
        "src/core/Schema.ts has changes without a migration. Run scripts/format to generate one.",
      );
      process.exit(1);
    }
  } finally {
    rmSync(scratch, { recursive: true, force: true });
  }
} else {
  execFileSync(drizzleKit, ["generate"], { cwd: here, stdio: "inherit" });
}
