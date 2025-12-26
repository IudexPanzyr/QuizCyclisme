import csv
import hashlib
import sys
from pathlib import Path

def stable_id(prefix: str, *parts: str) -> str:
    base = "|".join((p or "").strip() for p in parts)
    h = hashlib.sha1(base.encode("utf-8")).hexdigest()[:16]
    return f"{prefix}_{h}"

def sql_str(s: str) -> str:
    s = (s or "").strip()
    return "'" + s.replace("'", "''") + "'"

def sniff_dialect(path: Path):
    sample = path.read_text(encoding="utf-8-sig", errors="ignore")[:4096]
    return csv.Sniffer().sniff(sample, delimiters=",;\t")

def norm_key(s: str) -> str:
    return (s or "").replace("\ufeff", "").strip().lower()


def get_field(row: dict, *names: str) -> str:
    # tolère "Catégorie" / "catégorie" / "categorie" etc.
    keys = {norm_key(k): k for k in row.keys()}
    for n in names:
        k = keys.get(norm_key(n))
        if k is not None and row.get(k) is not None:
            return str(row[k]).strip()
    return ""

def main():
    if len(sys.argv) < 3:
        print("Usage: python tools/csv_to_seed.py data/cyclistes.csv seed.sql", file=sys.stderr)
        sys.exit(1)

    csv_path = Path(sys.argv[1])
    out_path = Path(sys.argv[2])

    dialect = sniff_dialect(csv_path)

    categories = {}  # code -> (id, name)
    teams = {}       # (cat_code, team_name) -> (id, name, cat_id)
    riders = {}      # rider_name -> (id, name, nation)
    rider_team = {}  # rider_id -> team_id (current)

    with csv_path.open("r", encoding="utf-8-sig", newline="") as f:
        reader = csv.DictReader(f, dialect=dialect)
        for row in reader:
            team_name = get_field(row, "equipe", "équipe", "team")
            rider_name = get_field(row, "coureur", "rider")
            nation = get_field(row, "nation", "nationalité", "country")
            cat = get_field(row, "Catégorie", "catégorie", "categorie", "category")

            if not team_name or not rider_name or not cat:
                continue

            cat_code = cat.strip().upper()

            # catégorie
            if cat_code not in categories:
                categories[cat_code] = (stable_id("cat", cat_code), cat_code)
            cat_id, cat_name = categories[cat_code]

            # équipe (unique par catégorie + nom)
            team_key = (cat_code, team_name)
            if team_key not in teams:
                teams[team_key] = (stable_id("team", cat_code, team_name), team_name, cat_id)

            # coureur (id stable basé sur nom+nation pour réduire collisions)
            if rider_name not in riders:
                riders[rider_name] = (stable_id("rider", rider_name, nation), rider_name, nation)

            rider_id = riders[rider_name][0]
            team_id = teams[team_key][0]

            # équipe "actuelle" = dernière occurrence si doublons
            rider_team[rider_id] = team_id

    lines = []
    lines.append("-- Generated from CSV. Safe to re-run (UPSERT).")
    lines.append("PRAGMA foreign_keys=ON;")
    lines.append("")

    # IMPORTANT: pas de BEGIN/COMMIT (wrangler d1 execute les refuse)

    for code, (cat_id, cat_name) in sorted(categories.items()):
        lines.append(
            "INSERT INTO categories(id, code, name) VALUES("
            f"{sql_str(cat_id)}, {sql_str(code)}, {sql_str(cat_name)}"
            ") ON CONFLICT(id) DO UPDATE SET code=excluded.code, name=excluded.name;"
        )

    lines.append("")

    for (cat_code, team_name), (team_id, _name, cat_id) in sorted(
        teams.items(), key=lambda x: (x[0][0], x[0][1])
    ):
        lines.append(
            "INSERT INTO teams(id, name, category_id, jersey_url) VALUES("
            f"{sql_str(team_id)}, {sql_str(team_name)}, {sql_str(cat_id)}, NULL"
            ") ON CONFLICT(id) DO UPDATE SET name=excluded.name, category_id=excluded.category_id;"
        )

    lines.append("")

    for rider_id, rider_name, nation in sorted(riders.values(), key=lambda x: x[1]):
        lines.append(
            "INSERT INTO riders(id, full_name, nation) VALUES("
            f"{sql_str(rider_id)}, {sql_str(rider_name)}, {sql_str(nation)}"
            ") ON CONFLICT(id) DO UPDATE SET full_name=excluded.full_name, nation=excluded.nation;"
        )

    lines.append("")

    for rider_id, team_id in sorted(rider_team.items()):
        lines.append(
            "INSERT INTO rider_team_current(rider_id, team_id) VALUES("
            f"{sql_str(rider_id)}, {sql_str(team_id)}"
            ") ON CONFLICT(rider_id) DO UPDATE SET team_id=excluded.team_id;"
        )

    lines.append("")
    out_path.write_text("\n".join(lines), encoding="utf-8")
    print(f"Wrote {out_path}")

if __name__ == "__main__":
    main()
