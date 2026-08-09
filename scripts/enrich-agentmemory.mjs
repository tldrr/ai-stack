import { readFile, rename, writeFile } from "node:fs/promises";

const args = process.argv.slice(2);
const baseUrl = args.shift();
const secretPath = args.shift();
const source = (args.shift() || "all").toLowerCase();
const concurrency = Math.max(1, Math.min(4, Number(args.shift()) || 2));
const manifestPath = args.shift();
const dryRun = args.includes("--dry-run");
const force = args.includes("--force");

if (!baseUrl || !secretPath || !manifestPath) {
  throw new Error(
    "Usage: node enrich-agentmemory.mjs <base-url> <secret-file> <source> <concurrency> <manifest> [--dry-run] [--force]",
  );
}

const secret = (await readFile(secretPath, "utf8")).trim();
const headers = {
  authorization: `Bearer ${secret}`,
  "content-type": "application/json",
};

async function api(path, options = {}) {
  const response = await fetch(`${baseUrl}${path}`, {
    ...options,
    headers: { ...headers, ...(options.headers || {}) },
  });
  const body = await response.json();
  if (!response.ok) {
    throw new Error(
      `${path} returned ${response.status}: ${body.error || "unknown error"}`,
    );
  }
  return body;
}

async function loadManifest() {
  try {
    const value = JSON.parse(await readFile(manifestPath, "utf8"));
    return value?.version === 1 && value.sessions
      ? value
      : { version: 1, sessions: {} };
  } catch (error) {
    if (error.code === "ENOENT") return { version: 1, sessions: {} };
    throw error;
  }
}

async function saveManifest(manifest) {
  const temporary = `${manifestPath}.tmp`;
  await writeFile(
    temporary,
    `${JSON.stringify({
      ...manifest,
      updatedAt: new Date().toISOString(),
    })}\n`,
    { mode: 0o600 },
  );
  await rename(temporary, manifestPath);
}

const sessionResponse = await api("/agentmemory/sessions");
const manifest = await loadManifest();
const sourceTag = source === "all" ? null : `source-${source}`;
const sessions = (sessionResponse.sessions || []).filter((session) => {
  const tags = Array.isArray(session.tags) ? session.tags : [];
  return (
    tags.includes("historical-import") &&
    (!sourceTag || tags.includes(sourceTag))
  );
});
const adopted = [];
const pending = sessions.filter((session) => {
  if (force) return true;
  const hasSummary =
    session.summary &&
    typeof session.summary === "object" &&
    session.summary.sessionId === session.id;
  if (!hasSummary) return true;
  const contentHash =
    session.importContentHash || `observations:${session.observationCount || 0}`;
  const entry = manifest.sessions[session.id];
  if (entry) return entry.contentHash !== contentHash;
  if (
    Number(session.summary.observationCount) ===
    Number(session.observationCount)
  ) {
    adopted.push({ sessionId: session.id, contentHash });
    return false;
  }
  return true;
});

if (dryRun) {
  console.log(
    JSON.stringify({
      dryRun: true,
      sessions: sessions.length,
      alreadySummarized: sessions.length - pending.length,
      pending: pending.length,
    }),
  );
  process.exit(0);
}

let next = 0;
let completed = 0;
let failed = 0;
const failures = [];

async function summarize(session) {
  for (let attempt = 1; attempt <= 2; attempt += 1) {
    try {
      const result = await api("/agentmemory/summarize", {
        method: "POST",
        body: JSON.stringify({ sessionId: session.id }),
      });
      if (!result.success) {
        throw new Error(result.error || "summary rejected");
      }
      const contentHash =
        session.importContentHash ||
        `observations:${session.observationCount || 0}`;
      manifest.sessions[session.id] = {
        contentHash,
        summarizedAt: new Date().toISOString(),
      };
      return;
    } catch (error) {
      if (attempt === 2) throw error;
      await new Promise((resolve) => setTimeout(resolve, 2000));
    }
  }
}

async function worker() {
  while (true) {
    const index = next;
    next += 1;
    if (index >= pending.length) return;
    const session = pending[index];
    try {
      await summarize(session);
      completed += 1;
    } catch (error) {
      failed += 1;
      failures.push({ sessionId: session.id, error: error.message });
    }
    if (
      (completed + failed) % 10 === 0 ||
      completed + failed === pending.length
    ) {
      console.log(
        JSON.stringify({
          processed: completed + failed,
          pending: pending.length,
          completed,
          failed,
        }),
      );
    }
  }
}

await Promise.all(Array.from({ length: concurrency }, () => worker()));
for (const entry of adopted) {
  manifest.sessions[entry.sessionId] = {
    contentHash: entry.contentHash,
    summarizedAt: new Date().toISOString(),
  };
}
await saveManifest(manifest);
console.log(
  JSON.stringify({
    sessions: sessions.length,
    alreadySummarized: sessions.length - pending.length,
    completed,
    failed,
    failures,
  }),
);
if (failed > 0) process.exitCode = 1;
