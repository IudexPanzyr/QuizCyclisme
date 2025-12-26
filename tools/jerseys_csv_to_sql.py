import csv
from pathlib import Path

# --- Config ---
BASE_URL = "https://iudexpanzyr.github.io/QuizCyclisme/jerseys/"
CSV_PATH = Path("data/jerseys.csv")
OUT_PATH = Path("worker/migrations/0005_jerseys_urls.sql")


def esc_sql(s: str) -> str:
    return s.replace("'", "''")


def detect_delimiter(sample: str) -> str:
    # Simple heuristic: choose the most likely delimiter
    semi = sample.count(";")
    comma = sample.count(",")
    return ";" if semi >= comma else ","


def main() -> None:
    if not CSV_PATH.exists():
        raise FileNotFoundError(f"CSV not found: {CSV_PATH.resolve()}")

    # Read a small sample to detect delimiter
    raw = CSV_PATH.read_bytes()
    text = raw.decode("utf-8-sig", errors="replace")  # removes BOM if present
    sample = "\n".join(text.splitlines()[:5])
    delim = detect_delimiter(sample)

    lines: list[str] = [
        "-- Auto-generated from data/jerseys.csv",
        f"-- Base: {BASE_URL}",
        "-- Expected columns: teamId,file (separator can be ',' or ';')",
        "",
    ]

    updated = 0
    skipped = 0

    # Parse CSV with detected delimiter, BOM-safe
    with CSV_PATH.open(newline="", encoding="utf-8-sig") as f:
        reader = csv.reader(f, delimiter=delim)
        rows = list(reader)

    if not rows:
        raise ValueError("CSV is empty")

    header = [h.strip() for h in rows[0]]

    # Normalize header (lowercase)
    header_norm = [h.lower() for h in header]

    def idx_of(name: str) -> int | None:
        name = name.lower()
        return header_norm.index(name) if name in header_norm else None

    i_team = idx_of("teamid")
    i_file = idx_of("file")

    start_row = 1  # default assumes first row is header

    # If header not detected, fallback: assume 2 columns in every row, no header
    if i_team is None or i_file is None:
        # Example: if first row is actually "teamId;file" combined, split fallback
        # But since we already parsed with delimiter, if header not found, treat as no-header.
        i_team, i_file = 0, 1
        start_row = 0

    for r in rows[start_row:]:
        if len(r) <= max(i_team, i_file):
            skipped += 1
            continue

        team_id = (r[i_team] or "").strip()
        file_name = (r[i_file] or "").strip()

        if not team_id or not file_name:
            skipped += 1
            continue

        file_name = file_name.lstrip("/")
        url = f"{BASE_URL}{file_name}"

        lines.append(
            "UPDATE teams "
            f"SET jersey_url='{esc_sql(url)}' "
            f"WHERE id='{esc_sql(team_id)}';"
        )
        updated += 1

    lines += [
        "",
        f"-- Rows generated: {updated}",
        f"-- Rows skipped: {skipped}",
        "",
    ]

    OUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    OUT_PATH.write_text("\n".join(lines), encoding="utf-8")

    print(f"✅ Wrote migration: {OUT_PATH}")
    print(f"   Delimiter detected: '{delim}'")
    print(f"   Updates: {updated} | Skipped: {skipped}")


if __name__ == "__main__":
    main()
