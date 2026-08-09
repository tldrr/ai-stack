import { readFileSync, readdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const distPath = process.argv[2];
if (!distPath) {
  throw new Error("AgentMemory dist path is required.");
}

const candidates = readdirSync(distPath)
  .filter((name) => /^src-.*\.mjs$/.test(name))
  .map((name) => join(distPath, name));
const target = candidates.find((path) =>
  readFileSync(path, "utf8").includes('logger.info("Import complete"'),
);
if (!target) {
  throw new Error("Cannot locate the AgentMemory import bundle.");
}

let source = readFileSync(target, "utf8");

function replaceExactlyOnce(pattern, replacement, label) {
  const matches = source.match(new RegExp(pattern.source, pattern.flags.includes("g") ? pattern.flags : `${pattern.flags}g`));
  if (!matches || matches.length !== 1) {
    throw new Error(`${label}: expected one bundle match, found ${matches?.length ?? 0}.`);
  }
  source = source.replace(pattern, replacement);
}

function replaceExactly(pattern, replacement, expected, label) {
  const flags = pattern.flags.includes("g") ? pattern.flags : `${pattern.flags}g`;
  const matches = source.match(new RegExp(pattern.source, flags));
  if (!matches || matches.length !== expected) {
    throw new Error(`${label}: expected ${expected} bundle matches, found ${matches?.length ?? 0}.`);
  }
  source = source.replace(new RegExp(pattern.source, flags), replacement);
}

replaceExactlyOnce(
  /\nasync function rebuildIndex\(kv\) \{/,
  `
async function indexImportedRecords(observations, memories, replaceExisting) {
\tconst idx = getSearchIndex();
\tif (replaceExisting) {
\t\tidx.clear();
\t\tvectorIndex?.clear();
\t}
\tconst jobs = [];
\tfor (const memory of memories) {
\t\tidx.remove(memory.id);
\t\tvectorIndex?.remove(memory.id);
\t\tif (memory.isLatest === false || !memory.title || !memory.content) continue;
\t\tidx.add(memoryToObservation(memory));
\t\tjobs.push({
\t\t\tid: memory.id,
\t\t\tsessionId: memory.sessionIds?.[0] ?? "memory",
\t\t\ttext: \`\${memory.title} \${memory.content}\`
\t\t});
\t}
\tfor (const observation of observations) {
\t\tidx.remove(observation.id);
\t\tvectorIndex?.remove(observation.id);
\t\tif (!observation.title || !observation.narrative) continue;
\t\tidx.add(observation);
\t\tjobs.push({
\t\t\tid: observation.id,
\t\t\tsessionId: observation.sessionId,
\t\t\ttext: \`\${observation.title} \${observation.narrative}\`
\t\t});
\t}
\tif (vectorIndex && currentEmbeddingProvider && jobs.length > 0) {
\t\tfor (let offset = 0; offset < jobs.length; offset += 32) {
\t\t\tconst batch = jobs.slice(offset, offset + 32);
\t\t\ttry {
\t\t\t\tconst inputs = batch.map((job) => clipEmbedInput(job.text));
\t\t\t\tconst embeddings = typeof currentEmbeddingProvider.embedBatch === "function"
\t\t\t\t\t? await currentEmbeddingProvider.embedBatch(inputs)
\t\t\t\t\t: await Promise.all(inputs.map((input) => currentEmbeddingProvider.embed(input)));
\t\t\t\tif (embeddings.length !== batch.length) {
\t\t\t\t\tthrow new Error(
\t\t\t\t\t\t\`import index: embedding batch returned \${embeddings.length} vectors for \${batch.length} records\`
\t\t\t\t\t);
\t\t\t\t}
\t\t\t\tfor (let index = 0; index < batch.length; index++) {
\t\t\t\t\tconst embedding = embeddings[index];
\t\t\t\t\tif (embedding.length !== currentEmbeddingProvider.dimensions) {
\t\t\t\t\t\tthrow new Error(
\t\t\t\t\t\t\t\`import index: embedding dimension \${embedding.length} did not match \${currentEmbeddingProvider.dimensions}\`
\t\t\t\t\t\t);
\t\t\t\t\t}
\t\t\t\t\tvectorIndex.add(batch[index].id, batch[index].sessionId, embedding);
\t\t\t\t}
\t\t\t} catch (error) {
\t\t\t\tlogger.error("import index: embedding batch failed", {
\t\t\t\t\tbatchSize: batch.length,
\t\t\t\t\terror: error instanceof Error ? error.message : String(error)
\t\t\t\t});
\t\t\t\tthrow error;
\t\t\t}
\t\t}
\t}
\tawait flushIndexSave();
}
async function rebuildIndex(kv) {`,
  "batched import index helper",
);

replaceExactlyOnce(
  /(\s*const stats = \{\n\s*sessions: 0,\n\s*observations: 0,\n\s*memories: 0,\n\s*summaries: 0,\n\s*skipped: 0\n\s*\};)/,
  `$1
\t\tconst importIndexObservations = [];
\t\tconst importIndexMemories = [];`,
  "import index accumulators",
);

replaceExactlyOnce(
  /(\s*await kv\.set\(KV\.observations\(sessionId\), o\.id, o\);\n)(\s*)stats\.observations\+\+;/,
  `$1$2importIndexObservations.push(o);
$2stats.observations++;`,
  "observation import indexing",
);

replaceExactlyOnce(
  /(\s*await kv\.set\(KV\.memories, memory\.id, memory\);\n)(\s*)stats\.memories\+\+;/,
  `$1$2importIndexMemories.push(memory);
$2stats.memories++;`,
  "memory import indexing",
);

replaceExactlyOnce(
  /\n(\s*)logger\.info\("Import complete", \{/,
  `\n$1await indexImportedRecords(importIndexObservations, importIndexMemories, strategy === "replace");\n$1logger.info("Import complete", {`,
  "import index persistence",
);

replaceExactlyOnce(
  /(\s*)let consolidated = 0;\n(\s*)const existingMemories = await kv\.list\(KV\.memories\);/,
  `$1let consolidated = 0;
$1const consolidationFailures = [];
$2const existingMemories = await kv.list(KV.memories);`,
  "consolidation failure tracking",
);

replaceExactlyOnce(
  /(\s*)const sessionIds = \[\.\.\.new Set\(top\.map\(\(o\) => o\.sid\)\)\];\n(\s*)const prompt = top\.map/,
  `$1const sessionIds = [...new Set(top.map((o) => o.sid))];
$1const obsIds = [...new Set(top.map((o) => o.id))];
$1const checkpointKey = \`\${data.stateHash ?? "default"}|\${concept}|\${obsIds.slice().sort().join("|")}\`;
$1if (await kv.get("mem:consolidation:completed", checkpointKey)) continue;
$2const prompt = top.map`,
  "consolidation concept checkpoint lookup",
);

replaceExactlyOnce(
  /(\s*)if \(!parsed\) continue;\n(\s*)const now = \(\/\* @__PURE__ \*\/ new Date\(\)\)\.toISOString\(\);\n(\s*)const obsIds = \[\.\.\.new Set\(top\.map\(\(o\) => o\.id\)\)\];/,
  `$1if (!parsed) throw new Error("Consolidation model returned an invalid memory");
$2const now = (/* @__PURE__ */ new Date()).toISOString();`,
  "consolidation parse failure",
);

replaceExactlyOnce(
  /(\s*)existingTitles\.add\(memory\.title\.toLowerCase\(\)\);\n(\s*)consolidated\+\+;\n(\s*)\}\n(\s*)\} catch \(err\) \{/,
  `$1existingTitles.add(memory.title.toLowerCase());
$2consolidated++;
$3}
$3await kv.set("mem:consolidation:completed", checkpointKey, {
$3\tstateHash: data.stateHash ?? "default",
$3\tconcept,
$3\tobservationIds: obsIds,
$3\tcompletedAt: (/* @__PURE__ */ new Date()).toISOString()
$3});
$4} catch (err) {`,
  "consolidation concept checkpoint save",
);

replaceExactlyOnce(
  /(\s*)logger\.warn\("Consolidation failed for concept", \{\n(\s*)concept,\n(\s*)error: err instanceof Error \? err\.message : String\(err\)\n(\s*)\}\);/,
  `$1const error = err instanceof Error ? err.message : String(err);
$1consolidationFailures.push({ concept, error });
$1logger.warn("Consolidation failed for concept", {
$2concept,
$3error
$4});`,
  "consolidation failure capture",
);

replaceExactlyOnce(
  /(\s*)logger\.info\("Consolidation complete", \{\n(\s*)consolidated,\n(\s*)totalObs: allObs\.length\n(\s*)\}\);\n(\s*)return \{\n(\s*)consolidated,\n(\s*)totalObservations: allObs\.length\n(\s*)\};/,
  `$1const currentMemories = await kv.list(KV.memories);
$1await indexImportedRecords([], currentMemories, false);
$1await flushIndexSave(kv);
$1logger.info("Consolidation complete", {
$2consolidated,
$3totalObs: allObs.length
$4});
$5return {
$6consolidated,
$7totalObservations: allObs.length,
$7failures: consolidationFailures
$8};`,
  "consolidation index refresh",
);

replaceExactlyOnce(
  /(\s*)const results = \{\};\n(\s*)if \(tier === "all" \|\| tier === "semantic"\) \{/,
  `$1const results = {};
$1if (data?.resetDerived === true) {
$1\tconst semantic = await kv.list(KV.semantic);
$1\tconst procedural = await kv.list(KV.procedural);
$1\tconst insights = await kv.list(KV.insights);
$1\tfor (const item of semantic) await kv.delete(KV.semantic, item.id);
$1\tfor (const item of procedural) await kv.delete(KV.procedural, item.id);
$1\tfor (const item of insights) await kv.delete(KV.insights, item.id);
$1\tresults.resetDerived = {
$1\t\tsemantic: semantic.length,
$1\t\tprocedural: procedural.length,
$1\t\tinsights: insights.length
$1\t};
$1}
$2if (tier === "all" || tier === "semantic") {`,
  "consolidation derived reset",
);

replaceExactlyOnce(
  /(\s*)let totalInsights = 0;\n(\s*)for \(const conceptNames of conceptClusters\) \{/,
  `$1let totalInsights = 0;
$1const reflectionFailures = [];
$2for (const conceptNames of conceptClusters) {`,
  "reflection failure tracking",
);

replaceExactlyOnce(
  /(\s*)\} catch \{\n(\s*)continue;\n(\s*)\}\n(\s*)\}\n(\s*)try \{\n(\s*)await recordAudit\(kv, "reflect"/,
  `$1} catch (err) {
$2reflectionFailures.push({
$2\tconcepts: conceptNames,
$2\terror: err instanceof Error ? err.message : String(err)
$2});
$2continue;
$3}
$4}
$5try {
$6await recordAudit(kv, "reflect"`,
  "reflection failure capture",
);

replaceExactlyOnce(
  /(\s*)clustersSkipped,\n(\s*)usedFallback\n(\s*)\};\n(\s*)\}\);\n(\s*)sdk\.registerFunction\("mem::insight-list"/,
  `$1clustersSkipped,
$2usedFallback,
$2failures: reflectionFailures
$3};
$4});
$5sdk.registerFunction("mem::insight-list"`,
  "reflection failure result",
);

replaceExactlyOnce(
  /(\s*const newEdgesForTopCheck = \[\];\n)/,
  `$1\t\t\tconst idRemap = /* @__PURE__ */ new Map();\n`,
  "graph node id remap",
);

replaceExactlyOnce(
  /(\s*if \(existing\) \{\n)(\s*const merged = mergeNode\(existing, node, obsIds, capturedAt\);)/,
  `$1\t\t\t\t\tidRemap.set(node.id, existing.id);\n$2`,
  "graph merged node remap",
);

replaceExactly(
  /if \(existing && snap\.resetAt && typeof existing\.createdAt === "string" && existing\.createdAt < snap\.resetAt\) existing = null;/,
  `if (existing && snap.resetAt && (typeof existing.createdAt !== "string" || existing.createdAt < snap.resetAt)) existing = null;`,
  2,
  "graph reset merge filtering",
);

replaceExactlyOnce(
  /(\s*)for \(const edge of edges\) \{\n(\s*)const eKey = edgeIndexKey\(edge\.sourceNodeId, edge\.targetNodeId, edge\.type\);/,
  `$1for (const rawEdge of edges) {
$2const edge = {
$2\t...rawEdge,
$2\tsourceNodeId: idRemap.get(rawEdge.sourceNodeId) ?? rawEdge.sourceNodeId,
$2\ttargetNodeId: idRemap.get(rawEdge.targetNodeId) ?? rawEdge.targetNodeId
$2};
$2const eKey = edgeIndexKey(edge.sourceNodeId, edge.targetNodeId, edge.type);`,
  "graph edge endpoint remap",
);

replaceExactlyOnce(
  /(\s*)allNodes = rawNodes\.filter\(\(n\) => !n\.stale\);\n(\s*)allEdges = rawEdges\.filter\(\(e\) => !e\.stale\);/,
  `$1const activeSnapshot = await readSnapshot(kv);
$1const resetAt = activeSnapshot?.resetAt;
$1allNodes = rawNodes.filter((n) =>
$1\t!n.stale && (!resetAt || (typeof n.createdAt === "string" && n.createdAt >= resetAt))
$1);
$2allEdges = rawEdges.filter((e) =>
$2\t!e.stale && (!resetAt || (typeof e.createdAt === "string" && e.createdAt >= resetAt))
$2);`,
  "graph reset query filtering",
);

replaceExactlyOnce(
  /\n(\t\t\t)const liveNodes = nodes\.filter\(\(n\) => !n\.stale\);\n(\t\t\t)const liveEdges = edges\.filter\(\(e\) => !e\.stale\);/,
  `
$1const rebuildSnapshot = await readSnapshot(kv);
$1const rebuildResetAt = rebuildSnapshot?.resetAt;
$1const liveNodes = nodes.filter((n) =>
$1\t!n.stale && (!rebuildResetAt || (typeof n.createdAt === "string" && n.createdAt >= rebuildResetAt))
$1);
$2const liveEdges = edges.filter((e) =>
$2\t!e.stale && (!rebuildResetAt || (typeof e.createdAt === "string" && e.createdAt >= rebuildResetAt))
$2);`,
  "graph reset rebuild filtering",
);

replaceExactlyOnce(
  /const snap = buildSnapshotFromArrays\(nodes, edges\);\n(\s*)await kv\.set\(KV\.graphSnapshot, SNAPSHOT_KEY, snap\);/,
  `const snap = buildSnapshotFromArrays(liveNodes, liveEdges);
$1if (rebuildResetAt) snap.resetAt = rebuildResetAt;
$1await kv.set(KV.graphSnapshot, SNAPSHOT_KEY, snap);`,
  "graph reset rebuild snapshot",
);

replaceExactlyOnce(
  /(\s*)const nodes = await kv\.list\(KV\.graphNodes\);\n(\s*)const edges = await kv\.list\(KV\.graphEdges\);\n(\s*)const nodesByType = \{\};/,
  `$1const graphSnapshot = await readSnapshot(kv);
$1const graphResetAt = graphSnapshot?.resetAt;
$1const rawNodes = await kv.list(KV.graphNodes);
$2const rawEdges = await kv.list(KV.graphEdges);
$1const nodes = rawNodes.filter((node) =>
$1\t!node.stale && (!graphResetAt || (typeof node.createdAt === "string" && node.createdAt >= graphResetAt))
$1);
$2const edges = rawEdges.filter((edge) =>
$2\t!edge.stale && (!graphResetAt || (typeof edge.createdAt === "string" && edge.createdAt >= graphResetAt))
$2);
$3const nodesByType = {};`,
  "graph reset MCP stats filtering",
);

replaceExactlyOnce(
  /(\s*)sdk\.registerFunction\("mem::graph-extract", async \(data\) => \{([\s\S]*?)\n\1\}\);\n\1sdk\.registerFunction\("mem::graph-query"/,
  `$1let graphExtractionChain = Promise.resolve();
$1const withGraphExtractionLock = (operation) => {
$1\tconst result = graphExtractionChain.then(operation, operation);
$1\tgraphExtractionChain = result.then(() => undefined, () => undefined);
$1\treturn result;
$1};
$1sdk.registerFunction("mem::graph-extract", async (data) => {
$1\treturn withGraphExtractionLock(async () => {$2
$1\t});
$1});
$1sdk.registerFunction("mem::graph-query"`,
  "serialized graph extraction",
);

replaceExactlyOnce(
  /(\s*)sdk\.registerFunction\("mem::graph-snapshot-rebuild", async \(data\) => \{([\s\S]*?)\n\1\}\);\n\1sdk\.registerFunction\("mem::graph-reset"/,
  `$1sdk.registerFunction("mem::graph-snapshot-rebuild", async (data) => {
$1\treturn withGraphExtractionLock(async () => {$2
$1\t});
$1});
$1sdk.registerFunction("mem::graph-reset"`,
  "serialized graph snapshot rebuild",
);

replaceExactlyOnce(
  /(\s*)sdk\.registerFunction\("mem::graph-reset", async \(\) => \{([\s\S]*?)\n\1\}\);\n\}/,
  `$1sdk.registerFunction("mem::graph-reset", async () => {
$1\treturn withGraphExtractionLock(async () => {$2
$1\t});
$1});
}`,
  "serialized graph reset",
);

writeFileSync(target, source);
