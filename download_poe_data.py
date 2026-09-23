import io
import json
import re
import urllib.parse
import urllib.request
import zipfile
from pathlib import Path

# ============================================================
# KONFIGURACJA
# ============================================================
# Folder zapisu
OUTPUT_DIR = Path("ninjadata")

# Wybór lig do pobrania:
#   "ALL"    -> wszystkie ligi (41 lig z historii poe.ninja)
#   "LATEST" -> tylko najnowsza liga
#   lub lista nazw, np. ["Mirage", "Settlers", "Necropolis"]
SELECTED_LEAGUES = "ALL"

# Kategorie plików CSV, które chcemy zachować:
INCLUDE_SOFTCORE = True       # Oficjalny Softcore (np. Mirage.currency.csv)
INCLUDE_HARDCORE = True       # Oficjalny Hardcore (np. Hardcore Mirage.currency.csv)
INCLUDE_RUTHLESS = True       # Oficjalny Ruthless i HC Ruthless (np. Ruthless Mirage.csv, HC Ruthless...)
INCLUDE_CMENTARZYSKO = True   # Polska liga prywatna Cmentarzysko (np. Cmentarzysko Mirage...)

# Czy posprzątać z folderu ninjadata niechciane pliki pobrane wcześniej
# (stały Standard, ogólny Hardcore, obce ligi prywatne PL...):
CLEANUP_UNWANTED_FILES = True

API_DUMPS_URL = "https://poe.ninja/poe1/api/data/dumps"
DUMP_DOWNLOAD_URL = "https://poe.ninja/poe1/api/data/dumps/dump"
HEADERS = {"User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"}


def sanitize_filename(name: str) -> str:
    """Usuwa znaki niedozwolone w nazwach folderów."""
    return re.sub(r'[\\/*?:"<>|]', "", name).strip()


def is_target_file(filename: str, league_name: str) -> tuple[bool, str]:
    """
    Sprawdza, czy plik CSV należy do jednej z pożądanych kategorii:
    - Oficjalny Softcore
    - Oficjalny Hardcore
    - Oficjalny Ruthless
    - Cmentarzysko
    """
    fn_lower = filename.lower()

    # 1. Cmentarzysko (polska liga prywatna, np. Cmentarzysko Mirage (PL78661)...)
    if "cmentarz" in fn_lower:
        return (INCLUDE_CMENTARZYSKO, "Cmentarzysko")

    # 2. Wykluczamy permanentne bazy Standard oraz ogólny Hardcore (bez nazwy ligi wyzwań)
    if filename in (
        "Standard.currency.csv", "Standard.items.csv",
        "Hardcore.currency.csv", "Hardcore.items.csv"
    ):
        return (False, "Permanent Standard/Hardcore")

    # 3. Wykluczamy obce ligi prywatne z kodami w nawiasach, np. (PL78803), (IRE001)
    if re.search(r'\([A-Za-z0-9]+\)', filename):
        return (False, "Other Private League")

    # 4. Oficjalny Ruthless (np. Ruthless Mirage.*, HC Ruthless Mirage.*, HC R Ancestors.*)
    if "ruthless" in fn_lower or fn_lower.startswith("hc r "):
        return (INCLUDE_RUTHLESS, "Ruthless")

    # 5. Oficjalny Hardcore ligi wyzwań (np. Hardcore Mirage.*, HC Mirage.*)
    clean_league = re.sub(r'^Ruthless\s+', '', league_name, flags=re.IGNORECASE).strip()
    if (filename.startswith(f"Hardcore {league_name}.") or 
        filename.startswith(f"HC {league_name}.") or
        filename.startswith(f"Hardcore {clean_league}.") or
        filename.startswith(f"HC {clean_league}.")):
        return (INCLUDE_HARDCORE, "Hardcore")

    # 6. Oficjalny Softcore ligi wyzwań (np. Mirage.*, Settlers.*)
    if filename.startswith(f"{league_name}.") or filename.startswith(f"{clean_league}."):
        return (INCLUDE_SOFTCORE, "Softcore")

    return (False, "Other")


def get_available_leagues() -> list[dict]:
    """Pobiera listę lig z poe.ninja."""
    req = urllib.request.Request(API_DUMPS_URL, headers=HEADERS)
    with urllib.request.urlopen(req) as resp:
        return json.loads(resp.read().decode("utf-8"))


def download_and_extract_league(league_name: str, target_dir: Path) -> None:
    """Pobiera archiwum zip ligi i wypakowuje TYLKO wybrane pliki CSV."""
    league_dir = target_dir / sanitize_filename(league_name)
    league_dir.mkdir(parents=True, exist_ok=True)

    # Pobranie archiwum zip
    encoded_name = urllib.parse.quote(league_name)
    url = f"{DUMP_DOWNLOAD_URL}?name={encoded_name}"

    req = urllib.request.Request(url, headers=HEADERS)
    with urllib.request.urlopen(req) as resp:
        zip_bytes = resp.read()

    extracted_files = []
    with zipfile.ZipFile(io.BytesIO(zip_bytes)) as zf:
        for member in zf.namelist():
            if not member.lower().endswith(".csv"):
                continue

            should_keep, category = is_target_file(member, league_name)
            if should_keep:
                zf.extract(member, path=league_dir)
                extracted_files.append((member, category))

    if extracted_files:
        summary = ", ".join({cat for _, cat in extracted_files})
        print(f"[{league_name}] Rozpakowano {len(extracted_files)} plikow ({summary}).")
    else:
        print(f"[{league_name}] Brak plikow pasujacych do wybranych filtrow.")


def cleanup_existing_files(target_dir: Path) -> None:
    """Usuwa niechciane pliki CSV (Standard, obce ligi prywatne) z poprzednich pobrań."""
    if not target_dir.exists():
        return

    removed_count = 0
    for league_dir in target_dir.iterdir():
        if not league_dir.is_dir():
            continue
        league_name = league_dir.name
        for f in league_dir.glob("*.csv"):
            should_keep, reason = is_target_file(f.name, league_name)
            if not should_keep:
                f.unlink()
                removed_count += 1

        # Usunięcie pustego folderu jeśli w danej lidze nie ma żadnych plików
        if not any(league_dir.iterdir()):
            league_dir.rmdir()

    if removed_count > 0:
        print(f"[Porzadki] Usunieto {removed_count} niechcianych plikow (Standard / obce ligi prywatne).\n")


def main():
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

    if CLEANUP_UNWANTED_FILES:
        cleanup_existing_files(OUTPUT_DIR)

    print("Pobieranie listy lig z poe.ninja...")
    all_leagues = get_available_leagues()

    # Filtrowanie lig do pobrania
    if SELECTED_LEAGUES == "ALL":
        leagues_to_process = all_leagues
    elif SELECTED_LEAGUES == "LATEST":
        leagues_to_process = [all_leagues[-1]]
    elif isinstance(SELECTED_LEAGUES, list):
        target_names = {l.lower() for l in SELECTED_LEAGUES}
        leagues_to_process = [l for l in all_leagues if l["leagueName"].lower() in target_names]
    else:
        leagues_to_process = all_leagues

    print(f"Ligi wybrane do pobrania: {len(leagues_to_process)}\n")

    for i, league in enumerate(leagues_to_process, start=1):
        name = league["leagueName"]
        league_dir = OUTPUT_DIR / sanitize_filename(name)
        
        # Jeśli folder już zawiera pasujące pliki CSV, pomijamy
        if league_dir.exists():
            existing = [f for f in league_dir.glob("*.csv") if is_target_file(f.name, name)[0]]
            if existing:
                print(f"({i}/{len(leagues_to_process)}) [{name}] Pominieto - posiada juz {len(existing)} wlasciwych plikow.")
                continue

        print(f"({i}/{len(leagues_to_process)}) Pobieranie danych dla ligi: {name}...")
        try:
            download_and_extract_league(name, OUTPUT_DIR)
        except Exception as e:
            print(f"Blad podczas pobierania ligi {name}: {e}")

    print("\nZakonczono!")


if __name__ == "__main__":
    main()
