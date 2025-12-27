// worker/tools/csv_to_riders_upsert.mjs
// Usage:
//   node worker/tools/csv_to_riders_upsert.mjs path/to/cyclistes.csv > riders_upsert.sql
//
// Then:
//   wrangler d1 execute cycling_quiz_db --remote --file riders_upsert.sql

import fs from "node:fs";
import crypto from "node:crypto";

function stripBom(s) {
  return s.replace(/^\uFEFF/, "");
}

function detectDelimiter(headerLine) {
  // Most FR CSV are ';', but we'll detect by count
  const semi = (headerLine.match(/;/g) || []).length;
  const comma = (headerLine.match(/,/g) || []).length;
  return semi >= comma ? ";" : ",";
}

function parseCsvLine(line, delim) {
  // Minimal CSV parser with quotes support
  // Handles: "a;""b"";c" etc.
  const out = [];
  let cur = "";
  let inQuotes = false;

  for (let i = 0; i < line.length; i++) {
    const ch = line[i];

    if (inQuotes) {
      if (ch === '"') {
        const next = line[i + 1];
        if (next === '"') {
          cur += '"';
          i++;
        } else {
          inQuotes = false;
        }
      } else {
        cur += ch;
      }
    } else {
      if (ch === '"') {
        inQuotes = true;
      } else if (ch === delim) {
        out.push(cur);
        cur = "";
      } else {
        cur += ch;
      }
    }
  }
  out.push(cur);
  return out.map((v) => String(v ?? "").trim());
}

function sqlEscape(value) {
  // Escape single quotes for SQL literals
  return String(value).replace(/'/g, "''");
}

function normalizeHeader(h) {
  // lower + strip accents + normalize spaces/underscores
  return String(h ?? "")
    .trim()
    .toLowerCase()
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "") // remove accents
    .replace(/\s+/g, "_");
}

function pickColumnIndex(headers, candidates) {
  const set = new Set(candidates.map((c) => normalizeHeader(c)));
  const idx = headers.findIndex((h) => set.has(normalizeHeader(h)));
  return idx >= 0 ? idx : -1;
}

function stableId(fullName, nation) {
  const base = `${String(fullName ?? "").trim()}|${String(nation ?? "").trim()}`;
  const hash = crypto.createHash("sha1").update(base).digest("hex").slice(0, 12);

  const slug = String(fullName ?? "")
    .trim()
    .toLowerCase()
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/(^-|-$)/g, "")
    .slice(0, 40);

  return `${slug || "rider"}-${hash}`;
}

const csvPath = process.argv[2];
if (!csvPath) {
  console.error(
    "Missing CSV path.\nExample: node worker/tools/csv_to_riders_upsert.mjs cyclistes.csv > riders_upsert.sql",
  );
  process.exit(1);
}

const raw = stripBom(fs.readFileSync(csvPath, "utf8"));
const lines = raw
  .split(/\r?\n/)
  .map((l) => l.trim())
  .filter((l) => l.length > 0);

if (lines.length < 2) {
  console.error("CSV seems empty (need header + rows).");
  process.exit(1);
}

const delim = detectDelimiter(lines[0]);
const headerCells = parseCsvLine(lines[0], delim).map(normalizeHeader);

// Support several common header names (including French)
const idIdx = pickColumnIndex(headerCells, ["id", "rider_id", "riderid"]);
const nameIdx = pickColumnIndex(headerCells, [
  "full_name",
  "fullname",
  "name",
  "rider_name",
  "ridername",
  "coureur",
]);
const natIdx = pickColumnIndex(headerCells, ["nation", "country", "nat"]);

// You have these in your CSV but we do not use them for riders table (kept for future)
// const teamIdx = pickColumnIndex(headerCells, ["equipe", "team"]);
// const catIdx = pickColumnIndex(headerCells, ["categorie", "category", "catégorie", "category_code"]);

if (nameIdx < 0) {
  console.error("Could not find required columns in CSV header.");
  console.error("Detected headers:", headerCells);
  console.error("Need at least: full_name (or compatible names like 'coureur').");
  process.exit(1);
}

// Build SQL (transaction + batch upserts)
let sql = "";
sql += "BEGIN TRANSACTION;\n";

let count = 0;
const BATCH_SIZE = 400; // keep file size/limits reasonable

function flushBatch() {
  sql += "COMMIT;\nBEGIN TRANSACTION;\n";
}

for (let i = 1; i < lines.length; i++) {
  const row = parseCsvLine(lines[i], delim);

  const fullName = (row[nameIdx] ?? "").trim();
  const nation = natIdx >= 0 ? (row[natIdx] ?? "").trim() : "";

  if (!fullName) continue;

  // If CSV has an id column, we use it; otherwise we generate a stable one from fullName+nation.
  const providedId = idIdx >= 0 ? (row[idIdx] ?? "").trim() : "";
  const id = providedId || stableId(fullName, nation);

  sql +=
    "INSERT INTO riders(id, full_name, nation)\n" +
    `VALUES('${sqlEscape(id)}','${sqlEscape(fullName)}',${nation ? `'${sqlEscape(nation)}'` : "NULL"})\n` +
    "ON CONFLICT(id) DO UPDATE SET\n" +
    "  full_name=excluded.full_name,\n" +
    "  nation=excluded.nation;\n";

  count++;
  if (count % BATCH_SIZE === 0) flushBatch();
}

sql += "COMMIT;\n";

console.error(`Generated UPSERT SQL for ${count} riders (delimiter: "${delim}")`);
process.stdout.write(sql);
