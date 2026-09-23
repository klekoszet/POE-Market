import argparse
import os
import sys
import time
from pathlib import Path

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")
if hasattr(sys.stderr, "reconfigure"):
    sys.stderr.reconfigure(encoding="utf-8")

# Domyślne ścieżki
DEFAULT_INPUT_DIR = Path("ninjadata")
DEFAULT_OUTPUT_DIR = Path("processed_data")

# Oczekiwane nagłówki z surowych plików poe.ninja
CURRENCY_HEADER = "League;Date;Get;Pay;Value;Confidence\n"
ITEMS_HEADER = "League;Date;Id;Type;Name;BaseType;Variant;Links;Value;Confidence\n"

CURRENCY_COL_COUNT = 6
ITEMS_COL_COUNT = 10


def find_unique_files(input_dir: Path, pattern: str) -> list[Path]:
    """
    Wyszukuje pliki CSV w ninjadata i eliminuje duplikaty.
    Niektóre ligi (np. Ruthless Affliction) znajdują się zarówno w podfolderze Affliction,
    jak i we własnym folderze Ruthless Affliction. Używamy unikalnej nazwy pliku.
    """
    all_files = sorted(list(input_dir.glob(f"*/*{pattern}*.csv")))
    unique_files = {}
    for f in all_files:
        if f.name not in unique_files:
            unique_files[f.name] = f
        else:
            if f.stat().st_size > unique_files[f.name].stat().st_size:
                unique_files[f.name] = f

    return sorted(list(unique_files.values()), key=lambda x: x.name.lower())


def merge_currency_files(files: list[Path], output_file: Path) -> int:
    """
    Łączy wszystkie surowe pliki currency z ninjadata w jeden plik processed_data/currency.csv.
    Czysty UNION - zachowuje oryginalne kolumny bez żadnych modyfikacji.
    """
    print(f"\n--- SCALANIE TABELI 'currency' ({len(files)} unikalnych plików) ---", flush=True)
    total_rows = 0
    t0 = time.time()

    with open(output_file, "w", encoding="utf-8", newline="") as out_fp:
        # Zapisujemy nagłówek tylko raz na samym początku
        out_fp.write(CURRENCY_HEADER)

        for idx, fpath in enumerate(files, start=1):
            if fpath.stat().st_size == 0:
                continue

            file_rows = 0
            with open(fpath, "r", encoding="utf-8", errors="replace") as in_fp:
                # Pomijamy nagłówek w każdym kolejnym pliku
                in_fp.readline()

                for line in in_fp:
                    clean = line.strip()
                    if not clean:
                        continue
                    out_fp.write(clean + "\n")
                    file_rows += 1

            total_rows += file_rows
            if idx % 10 == 0 or idx == len(files):
                print(f"  [{idx}/{len(files)}] {fpath.name:<45} (łączna liczba wierszy: {total_rows:,})", flush=True)

    dt = time.time() - t0
    size_mb = output_file.stat().st_size / (1024 * 1024)
    print(f"Gotowe! Zapisano {total_rows:,} wierszy do {output_file} ({size_mb:.2f} MB w {dt:.1f}s)", flush=True)
    return total_rows


def merge_items_files(files: list[Path], output_file: Path) -> int:
    """
    Łączy wszystkie surowe pliki items z ninjadata w jeden plik processed_data/items.csv.
    Czysty UNION - zachowuje oryginalne kolumny.
    Automatycznie łączy wielolinijkowe wpisy z trumien w lidze Necropolis,
    dzięki czemu każdy wiersz wynikowy ma dokładnie 10 kolumn.
    """
    print(f"\n--- SCALANIE TABELI 'items' ({len(files)} unikalnych plików) ---", flush=True)
    total_rows = 0
    t0 = time.time()

    with open(output_file, "w", encoding="utf-8", newline="") as out_fp:
        # Zapisujemy nagłówek tylko raz na samym początku
        out_fp.write(ITEMS_HEADER)

        for idx, fpath in enumerate(files, start=1):
            if fpath.stat().st_size == 0:
                continue

            file_rows = 0
            with open(fpath, "r", encoding="utf-8", errors="replace") as in_fp:
                # Pomijamy nagłówek
                in_fp.readline()

                buffer = ""
                for line in in_fp:
                    clean = line.rstrip("\r\n")
                    if not clean:
                        continue

                    # Obsługa opisów trumien z połamanymi liniami
                    if buffer:
                        buffer += " " + clean
                    else:
                        buffer = clean

                    # 10 kolumn oznacza dokładnie 9 średników ';'
                    if buffer.count(";") >= ITEMS_COL_COUNT - 1:
                        out_fp.write(buffer + "\n")
                        file_rows += 1
                        buffer = ""

                if buffer:
                    out_fp.write(buffer + "\n")
                    file_rows += 1

            total_rows += file_rows
            if idx % 10 == 0 or idx == len(files):
                print(f"  [{idx}/{len(files)}] {fpath.name:<45} (łączna liczba wierszy: {total_rows:,})", flush=True)

    dt = time.time() - t0
    size_mb = output_file.stat().st_size / (1024 * 1024)
    print(f"Gotowe! Zapisano {total_rows:,} wierszy do {output_file} ({size_mb:.2f} MB w {dt:.1f}s)", flush=True)
    return total_rows


def load_to_postgresql(output_dir: Path, config: dict):
    """
    Opcjonalne ładowanie połączonych plików z processed_data/ do bazy PostgreSQL w kontenerze Docker.
    Tworzy tabele currency i items w surowej postaci poe.ninja.
    """
    try:
        import psycopg2
    except ImportError:
        print("\nBrak biblioteki psycopg2. Aby wgrać do bazy danych: pip install psycopg2-binary", flush=True)
        return

    curr_file = output_dir / "currency.csv"
    items_file = output_dir / "items.csv"

    print(f"\n--- ŁADOWANIE DO POSTGRESQL ({config['user']}@{config['host']}:{config['port']}/{config['dbname']}) ---", flush=True)
    try:
        conn = psycopg2.connect(**config)
        conn.autocommit = False
        cur = conn.cursor()
        cur.execute("SET synchronous_commit = off;")
        conn.commit()
    except Exception as e:
        print(f"BŁĄD połączenia z bazą PostgreSQL: {e}", flush=True)
        return

    # Tabela currency
    cur.execute("""
    CREATE TABLE IF NOT EXISTS currency (
        league TEXT,
        date DATE,
        get TEXT,
        pay TEXT,
        value DOUBLE PRECISION,
        confidence TEXT
    );
    """)
    conn.commit()

    if curr_file.exists():
        print(f"Wgrywanie {curr_file.name} do tabeli currency...", flush=True)
        t0 = time.time()
        with open(curr_file, "r", encoding="utf-8") as f:
            cur.copy_expert("""
                COPY currency (league, date, get, pay, value, confidence)
                FROM STDIN WITH (FORMAT csv, HEADER true, DELIMITER ';', NULL '');
            """, f)
        conn.commit()
        print(f"Załadowano {cur.rowcount:,} wierszy w {time.time() - t0:.1f}s!", flush=True)

    # Tabela items
    cur.execute("""
    CREATE TABLE IF NOT EXISTS items (
        league TEXT,
        date DATE,
        id BIGINT,
        type TEXT,
        name TEXT,
        basetype TEXT,
        variant TEXT,
        links TEXT,
        value DOUBLE PRECISION,
        confidence TEXT
    );
    """)
    conn.commit()

    if items_file.exists():
        print(f"Wgrywanie {items_file.name} do tabeli items...", flush=True)
        t0 = time.time()
        with open(items_file, "r", encoding="utf-8") as f:
            cur.copy_expert("""
                COPY items (league, date, id, type, name, basetype, variant, links, value, confidence)
                FROM STDIN WITH (FORMAT csv, HEADER true, DELIMITER ';', NULL '');
            """, f)
        conn.commit()
        print(f"Załadowano {cur.rowcount:,} wierszy w {time.time() - t0:.1f}s!", flush=True)

    cur.close()
    conn.close()
    print("Ładowanie do bazy PostgreSQL zakończone!", flush=True)


def main():
    parser = argparse.ArgumentParser(description="Scalanie surowych danych PoE Ninja ze wszystkich lig (UNION)")
    parser.add_argument("--input-dir", default=str(DEFAULT_INPUT_DIR), help="Folder ze źródłowymi danymi (domyślnie: ninjadata)")
    parser.add_argument("--output-dir", default=str(DEFAULT_OUTPUT_DIR), help="Folder wynikowy (domyślnie: processed_data)")
    parser.add_argument("--to-db", action="store_true", help="Opcjonalnie załaduj wynikowe pliki bezpośrednio do PostgreSQL w Dockerze")
    parser.add_argument("--host", default=os.environ.get("DB_HOST", "localhost"), help="Host PostgreSQL (domyślnie: localhost)")
    parser.add_argument("--port", type=int, default=int(os.environ.get("DB_PORT", 5433)), help="Port PostgreSQL (domyślnie: 5433)")
    parser.add_argument("--dbname", default=os.environ.get("DB_NAME", "poe_market"), help="Baza PostgreSQL (domyślnie: poe_market)")
    parser.add_argument("--user", default=os.environ.get("DB_USER", "poe_admin"), help="Użytkownik PostgreSQL (domyślnie: poe_admin)")
    parser.add_argument("--password", default=os.environ.get("DB_PASSWORD", "poe_password"), help="Hasło PostgreSQL (domyślnie: poe_password)")

    args = parser.parse_args()
    input_path = Path(args.input_dir)
    output_path = Path(args.output_dir)

    if not input_path.exists():
        print(f"BŁĄD: Folder wejściowy {input_path} nie istnieje!", flush=True)
        sys.exit(1)

    output_path.mkdir(parents=True, exist_ok=True)

    print("=" * 80, flush=True)
    print("      SCALANIE DANYCH POE NINJA (UNION WSZYSTKICH LIG)", flush=True)
    print("=" * 80, flush=True)
    print(f"Folder wejściowy:  {input_path.resolve()}", flush=True)
    print(f"Folder docelowy:    {output_path.resolve()}", flush=True)

    # 1. Wyszukanie unikalnych plików
    currency_files = find_unique_files(input_path, "currency")
    items_files = find_unique_files(input_path, "items")

    print(f"\nZnaleziono unikalnych plików do scalenia:", flush=True)
    print(f"  - Pliki walut (currency):    {len(currency_files)} plików", flush=True)
    print(f"  - Pliki przedmiotów (items): {len(items_files)} plików", flush=True)

    total_start = time.time()

    # 2. Scalanie walut
    curr_output = output_path / "currency.csv"
    curr_rows = merge_currency_files(currency_files, curr_output)

    # 3. Scalanie przedmiotów
    items_output = output_path / "items.csv"
    items_rows = merge_items_files(items_files, items_output)

    total_time = time.time() - total_start

    print("\n" + "=" * 80, flush=True)
    print("                         PODSUMOWANIE PROCESU", flush=True)
    print("=" * 80, flush=True)
    print(f" Łączny czas scalania: {total_time:.1f}s", flush=True)
    print(f" Plik 1: {curr_output.resolve()}", flush=True)
    print(f"   - Wiersze:  {curr_rows:,}", flush=True)
    print(f"   - Rozmiar:  {curr_output.stat().st_size / (1024 * 1024):.2f} MB", flush=True)
    print(f"   - Kolumny:  {CURRENCY_HEADER.strip()}", flush=True)
    print("-" * 80, flush=True)
    print(f" Plik 2: {items_output.resolve()}", flush=True)
    print(f"   - Wiersze:  {items_rows:,}", flush=True)
    print(f"   - Rozmiar:  {items_output.stat().st_size / (1024 * 1024 * 1024):.2f} GB", flush=True)
    print(f"   - Kolumny:  {ITEMS_HEADER.strip()}", flush=True)
    print("=" * 80 + "\n", flush=True)

    # 4. Opcjonalne ładowanie do bazy PostgreSQL
    if args.to_db:
        db_config = {
            "host": args.host,
            "port": args.port,
            "dbname": args.dbname,
            "user": args.user,
            "password": args.password,
        }
        load_to_postgresql(output_path, db_config)


if __name__ == "__main__":
    main()
