import { createHash } from "node:crypto";
import { readFile, rename, writeFile } from "node:fs/promises";
import { registerWorker } from "iii-sdk";

const args = process.argv.slice(2);
const source = (args.shift() || "all").toLowerCase();
const dryRun = args.includes("--dry-run");
const baseUrl = "http://127.0.0.1:3111";
const manifestPath = "/data/graph-backfill-manifest.json";
const maxBatchObservations = 20;
const maxBatchCharacters = 100_000;
// AgentMemory 0.9.28 graph index and snapshot updates are not atomic.
const concurrency = 1;
const secret = (await readFile("/data/.hmac", "utf8")).trim();
const headers = { authorization: `Bearer ${secret}` };

async function getJson(path) {
  const response = await fetch(`${baseUrl}${path}`, { headers });
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
    return new Set(Array.isArray(value.completed) ? value.completed : []);
  } catch (error) {
    if (error.code === "ENOENT") return new Set();
    throw error;
  }
}

async function saveManifest(completed) {
  const temporary = `${manifestPath}.tmp`;
  await writeFile(
    temporary,
    `${JSON.stringify({
      version: 1,
      updatedAt: new Date().toISOString(),
      completed: [...completed].sort(),
    })}\n`,
    { mode: 0o600 },
  );
  await rename(temporary, manifestPath);
}

function batchKey(observations) {
  return createHash("sha256")
    .update(
      observations
        .map((observation) =>
          [
            observation.id,
            observation.title,
            observation.narrative,
            ...(observation.concepts || []),
            ...(observation.files || []),
          ].join("\0"),
        )
        .join("\0"),
    )
    .digest("hex");
}

const sessionsResponse = await getJson("/agentmemory/sessions");
const sourceTag = source === "all" ? null : `source-${source}`;
const allSessions = sessionsResponse.sessions || [];
const selectedHistoricalSessions = allSessions.filter((session) => {
  const tags = Array.isArray(session.tags) ? session.tags : [];
  return (
    tags.includes("historical-import") &&
    (!sourceTag || tags.includes(sourceTag))
  );
});
const sessions = allSessions.filter(
  (session) => session.summary?.title && session.summary?.narrative,
);
const completed = await loadManifest();
const batches = [];
const summaryObservations = [];
const missingSummaries = selectedHistoricalSessions
  .filter((session) => !session.summary?.title || !session.summary?.narrative)
  .map((session) => session.id);

for (const session of sessions.sort((left, right) =>
  String(left.id).localeCompare(String(right.id)),
)) {
  const summary = session.summary;
  if (!summary?.title || !summary?.narrative) {
    missingSummaries.push(session.id);
    continue;
  }
  const encoded = encodeURIComponent(session.id);
  const response = await getJson(
    `/agentmemory/observations?sessionId=${encoded}&agentId=*`,
  );
  const firstObservation = (response.observations || [])
    .filter((observation) => observation?.title)
    .sort(
      (left, right) =>
        String(left.timestamp || "").localeCompare(
          String(right.timestamp || ""),
        ) || String(left.id).localeCompare(String(right.id)),
    )[0];
  if (!firstObservation) {
    missingSummaries.push(session.id);
    continue;
  }
  const decisions = Array.isArray(summary.keyDecisions)
    ? summary.keyDecisions.filter(Boolean)
    : [];
  summaryObservations.push({
    id: firstObservation.id,
    title: summary.title,
    narrative: [
      summary.narrative,
      decisions.length > 0
        ? `Key decisions:\n${decisions.map((decision) => `- ${decision}`).join("\n")}`
        : "",
    ]
      .filter(Boolean)
      .join("\n\n"),
    concepts: Array.isArray(summary.concepts) ? summary.concepts : [],
    files: Array.isArray(summary.filesModified) ? summary.filesModified : [],
    type: "session_summary",
    sessionId: session.id,
  });
}

let items = [];
let characters = 0;
const addBatch = () => {
  if (items.length === 0) return;
  const key = batchKey(items);
  if (!completed.has(key)) {
    batches.push({
      sessionIds: items.map((observation) => observation.sessionId),
      key,
      observations: items,
    });
  }
  items = [];
  characters = 0;
};
for (const observation of summaryObservations) {
  const observationCharacters =
    String(observation.title || "").length +
    String(observation.narrative || "").length;
  if (
    items.length > 0 &&
    (items.length >= maxBatchObservations ||
      characters + observationCharacters > maxBatchCharacters)
  ) {
    addBatch();
  }
  items.push(observation);
  characters += observationCharacters;
}
addBatch();

if (dryRun) {
  console.log(
    JSON.stringify({
      dryRun: true,
      sessions: sessions.length,
      summaries: summaryObservations.length,
      missingSummaries: missingSummaries.length,
      completedBatches: completed.size,
      pendingBatches: batches.length,
    }),
  );
  process.exit(0);
}

if (missingSummaries.length > 0) {
  throw new Error(
    `${missingSummaries.length} historical sessions have no usable summary; rerun summary enrichment first.`,
  );
}

const iii = registerWorker("ws://127.0.0.1:49134", {
  invocationTimeoutMs: 900_000,
});

async function extractWithRetry(observations) {
  const result = await iii.trigger({
    function_id: "mem::graph-extract",
    payload: { observations },
  });
  if (!result?.success) {
    throw new Error(result?.error || "graph extraction rejected");
  }
  return result;
}

let succeeded = 0;
let failed = 0;
let nodes = 0;
let edges = 0;
const failures = [];

for (let offset = 0; offset < batches.length; offset += concurrency) {
  const wave = batches.slice(offset, offset + concurrency);
  const results = await Promise.all(
    wave.map(async (batch) => {
      try {
        return {
          batch,
          result: await extractWithRetry(batch.observations),
        };
      } catch (error) {
        return { batch, error };
      }
    }),
  );
  let manifestChanged = false;
  for (const entry of results) {
    if (entry.error) {
      failed += 1;
      failures.push({
        sessionIds: entry.batch.sessionIds,
        error: entry.error.message,
      });
      continue;
    }
    succeeded += 1;
    nodes += Number(entry.result.nodesAdded) || 0;
    edges += Number(entry.result.edgesAdded) || 0;
    completed.add(entry.batch.key);
    manifestChanged = true;
  }
  if (manifestChanged) await saveManifest(completed);
  if ((succeeded + failed) % 10 < concurrency || offset + concurrency >= batches.length) {
    console.log(
      JSON.stringify({
        processed: succeeded + failed,
        pending: batches.length,
        succeeded,
        failed,
        nodes,
        edges,
      }),
    );
  }
}

console.log(
  JSON.stringify({
    sessions: sessions.length,
    completedBatches: completed.size,
    succeeded,
    failed,
    nodes,
    edges,
    failures,
  }),
);
process.exit(failed > 0 ? 1 : 0);
