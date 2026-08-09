import { existsSync } from "node:fs";
import { DatabaseSync } from "node:sqlite";

const databasePath = process.argv[2];
if (!databasePath) {
  console.error("Usage: node read-copilot-sessions.mjs <session-store.db>");
  process.exit(2);
}

if (!existsSync(databasePath)) {
  process.exit(0);
}

const database = new DatabaseSync(databasePath, { readOnly: true });
try {
  const sessions = database
    .prepare(
      `SELECT id, cwd, repository, host_type, branch, summary, created_at, updated_at
       FROM sessions
       ORDER BY created_at, id`,
    )
    .all();
  const readTurns = database.prepare(
    `SELECT turn_index, user_message, assistant_response, timestamp
     FROM turns
     WHERE session_id = ?
     ORDER BY turn_index`,
  );

  for (const session of sessions) {
    const record = {
      ...session,
      turns: readTurns.all(session.id),
    };
    process.stdout.write(`${JSON.stringify(record)}\n`);
  }
} finally {
  database.close();
}
