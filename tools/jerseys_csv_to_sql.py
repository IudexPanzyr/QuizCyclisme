import csv
from pathlib import Path

# --- Config ---
CSV_PATH = Path("data/jerseys.csv")
OUT_PATH = Path("worker/migrations/0005_jerseys_urls.sql")

# Si ton CSV contient déjà des URLs complètes (https://iudexpanzyr.github.io/...),
# le script les utilisera telles quelles.
# Si tu mets juste "Alpecin.png", il construira l'URL avec BASE_URL.
BASE_URL = "https://iudexpanzyr.github.io/QuizCyclisme/jerseys/"


def esc_sql(s: str) -> str:
    return s.replace("'", "''")


def detect_delimiter(sample: str) -> str:
    semi = sample.count(";")
    comma = sample.count(",")
    return ";" if semi >= comma else ","


def is_url(s: str) -> bool:
    s = s.lower()
    return s.startswith("http://") or s.startswith("https://")


def main() -> None:
    if not CSV_PATH.exists():
        raise FileNotFoundError(f"CSV not found: {CSV_PATH.resolve()}")

    raw = CSV_PATH.read_bytes()
    text = raw.decode("utf-8-sig", errors="replace")  # enlève BOM si présent
    sample = "\n".join(text.splitlines()[:5])
    delim = detect_delimiter(sample)

    lines: list[str] = [
        "-- Auto-generated from data/jerseys.csv",
        f"-- Base (if needed): {BASE_URL}",
        "-- Expected columns: name,file (separator can be ',' or ';')",
        "",
    ]

    updated = 0
    skipped = 0

    with CSV_PATH.open(newline="", encoding="utf-8-sig") as f:
        reader = csv.reader(f, delimiter=delim)
        rows = list(reader)

    if not rows:
        raise ValueError("CSV is empty")

    header = [h.strip() for h in rows[0]]
    header_norm = [h.lower() for h in header]

    def idx_of(col: str) -> int | None:
        col = col.lower()
        return header_norm.index(col) if col in header_norm else None

    i_name = idx_of("name")
    i_file = idx_of("file")

    start_row = 1
    if i_name is None or i_file is None:
        # fallback: pas d'en-tête
        i_name, i_file = 0, 1
        start_row = 0

    for r in rows[start_row:]:
        if len(r) <= max(i_name, i_file):
            skipped += 1
            continue

        name = (r[i_name] or "").strip()
        file_or_url = (r[i_file] or "").strip()

        if not name or not file_or_url:
            skipped += 1
            continue

        if is_url(file_or_url):
            url = file_or_url
        else:
            file_name = file_or_url.lstrip("/")
            url = f"{BASE_URL}{file_name}"

        lines.append(
            "UPDATE teams "
            f"SET jersey_url='{esc_sql(url)}' "
            f"WHERE name='{esc_sql(name)}';"
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
