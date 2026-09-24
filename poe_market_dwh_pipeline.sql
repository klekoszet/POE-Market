-- ====================================================================================================
-- PROJEKT: Hurtownia Danych i Analityka Rynku Path of Exile (poe.ninja)
-- PLIK:    poe_market_dwh_pipeline.sql
-- OPIS:    Kompleksowy skrypt ETL / DWH w PostgreSQL przekształcający surowe zrzuty poe.ninja (110M+ wierszy)
--          w wydajny, zoptymalizowany schemat gwiazdy (Star Schema) z widokami analitycznymi dla Power BI.
-- ====================================================================================================

/*
ARCHITEKTURA ROZWIĄZANIA (DWH & BI):
1. STAGING / SUROWE DANE:
   - currency (league, date, get, pay, value, confidence) ~1.44M wierszy
   - items (league, date, id, type, name, basetype, variant, links, value, confidence) ~110M wierszy (13 GB)

2. WARSTWA WYMIARÓW (DIMENSIONS):
   - dim_date: Wymiar kalendarzowy z flagą dni weekendowych (analiza weekendowych skoków popytu)
   - dim_league: Wymiar lig z podziałem na ery ekonomiczne (Exalt Era vs Divine Era), wersje i typy lig
   - dim_item: Wymiar przedmiotów wzbogacony o kategoryzację slotów, tiery (T0/T1) i wersje kanoniczne

3. WARSTWA FAKTÓW (FACTS):
   - fact_currency: Znormalizowane notowania walut z relacją do ligi oraz relatywną osią czasu (day/week of league)
   - fact_item_prices: Zoptymalizowana tabela faktów cen unikatów z kluczem złożonym i indeksami b-tree

4. WARSTWA WIDOKÓW ANALITYCZNYCH (DATA MARTS DLA POWER BI):
   - v_fact_currency_daily: Normalizacja par walutowych, wyliczenie kursów krzyżowych (Mirror w Divinach)
   - v_fact_chase_items_daily: Skoncentrowany mart unikatów T0/T1 z automatycznym przeliczaniem na Diviny
   - v_benchmark_day_of_league: Agregat benchmarkingowy (min/avg/max) na potrzeby predykcji cen w czasie gry
*/


-- ====================================================================================================
-- SEKCJA 1: KONFIGURACJA ŚRODOWISKA I ZASOBÓW SESJI (TUNING POD DUŻY WOLUMEN)
-- ====================================================================================================
SET work_mem = '1GB';
SET maintenance_work_mem = '2GB';
SET max_parallel_workers_per_gather = 8;
SET synchronous_commit = off;


-- ====================================================================================================
-- SEKCJA 2: TABELE STAGINGOWE (STRUKTURA DANYCH ŹRÓDŁOWYCH POE.NINJA)
-- ====================================================================================================

CREATE TABLE IF NOT EXISTS currency (
    league TEXT,
    date DATE,
    get TEXT,
    pay TEXT,
    value DOUBLE PRECISION,
    confidence TEXT
);

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


-- ====================================================================================================
-- SEKCJA 3: WYMIARY (DIMENSIONS)
-- ====================================================================================================

-------------------------------------------------------------------------------------------------------
-- 3.1. WYMIAR KALENDARZOWY (dim_date)
-------------------------------------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS dim_date (
    date_key TIMESTAMP WITH TIME ZONE PRIMARY KEY,
    year INTEGER,
    month INTEGER,
    day INTEGER,
    day_of_week INTEGER,
    day_name TEXT,
    quarter INTEGER,
    full_date DATE,
    is_weekend BOOLEAN
);

-- Wzbogacenie i synchronizacja czystej daty kalendarzowej oraz flagi weekendu
UPDATE dim_date 
SET full_date = MAKE_DATE(year, month, day),
    is_weekend = (day_of_week IN (6, 7) OR day_name IN ('Saturday', 'Sunday'))
WHERE full_date IS NULL OR is_weekend IS NULL;

CREATE INDEX IF NOT EXISTS idx_dim_date_full_date ON dim_date(full_date);


-------------------------------------------------------------------------------------------------------
-- 3.2. WYMIAR LIG (dim_league)
-------------------------------------------------------------------------------------------------------
-- Rola: Przechowuje metadane wszystkich oficjalnych lig wyzwań od 2016 roku (Essence) do 2026 roku.
-- Wprowadza kluczowy podział makroekonomiczny:
-- - Exalt Era (Pre-3.19): Główną walutą handlową i craftingową był Exalted Orb
-- - Divine Era (3.19+): Patch Lake of Kalandra przeniósł koszty rzemiosła na Divine Orb
-- - is_trade_challenge: Flaga filtrująca oficjalne ligi Softcore Trade (wyklucza HC/Ruthless/Private)
-------------------------------------------------------------------------------------------------------

DROP TABLE IF EXISTS dim_league CASCADE;

CREATE TABLE dim_league (
    league_key SERIAL PRIMARY KEY,
    league_name TEXT NOT NULL,
    base_league TEXT NOT NULL,
    is_hardcore BOOLEAN NOT NULL,
    start_date DATE NOT NULL,
    end_date DATE,
    release_version VARCHAR(20) NOT NULL,
    league_length_days INTEGER,
    league_index INTEGER,
    league_era TEXT,
    is_trade_challenge BOOLEAN
);

-- Zasilenie słownika metadanymi chronologicznymi lig
WITH league_meta (base_league, start_date, end_date, release_version) AS (
    VALUES
        ('Essence',     '2016-09-02'::date, '2016-11-28'::date, '2.4.0'),
        ('Breach',      '2016-12-02'::date, '2017-02-27'::date, '2.5.0'),
        ('Legacy',      '2017-03-03'::date, '2017-07-31'::date, '2.6.0'),
        ('Harbinger',   '2017-08-04'::date, '2017-12-04'::date, '3.0.0'),
        ('Abyss',       '2017-12-08'::date, '2018-02-26'::date, '3.1.0'),
        ('Bestiary',    '2018-03-02'::date, '2018-05-28'::date, '3.2.0'),
        ('Incursion',   '2018-06-01'::date, '2018-08-27'::date, '3.3.0'),
        ('Delve',       '2018-08-31'::date, '2018-12-03'::date, '3.4.0'),
        ('Betrayal',    '2018-12-07'::date, '2019-03-04'::date, '3.5.0'),
        ('Synthesis',   '2019-03-08'::date, '2019-06-03'::date, '3.6.0'),
        ('Legion',      '2019-06-07'::date, '2019-09-03'::date, '3.7.0'),
        ('Blight',      '2019-09-06'::date, '2019-12-09'::date, '3.8.0'),
        ('Metamorph',   '2019-12-13'::date, '2020-03-09'::date, '3.9.0'),
        ('Delirium',    '2020-03-13'::date, '2020-06-15'::date, '3.10.0'),
        ('Harvest',     '2020-06-19'::date, '2020-09-14'::date, '3.11.0'),
        ('Heist',       '2020-09-18'::date, '2021-01-11'::date, '3.12.0'),
        ('Ritual',      '2021-01-15'::date, '2021-04-12'::date, '3.13.0'),
        ('Ultimatum',   '2021-04-16'::date, '2021-07-19'::date, '3.14.0'),
        ('Expedition',  '2021-07-23'::date, '2021-10-18'::date, '3.15.0'),
        ('Scourge',     '2021-10-22'::date, '2022-02-01'::date, '3.16.0'),
        ('Archnemesis', '2022-02-04'::date, '2022-05-10'::date, '3.17.0'),
        ('Sentinel',    '2022-05-13'::date, '2022-08-16'::date, '3.18.0'),
        ('Kalandra',    '2022-08-19'::date, '2022-12-06'::date, '3.19.0'),
        ('Sanctum',     '2022-12-09'::date, '2023-04-04'::date, '3.20.0'),
        ('Crucible',    '2023-04-07'::date, '2023-08-15'::date, '3.21.0'),
        ('Ancestor',    '2023-08-18'::date, '2023-12-05'::date, '3.22.0'),
        ('Affliction',  '2023-12-08'::date, '2024-03-26'::date, '3.23.0'),
        ('Necropolis',  '2024-03-29'::date, '2024-07-23'::date, '3.24.0'),
        ('Settlers',    '2024-07-26'::date, '2025-06-09'::date, '3.25.0'),
        ('Mercenaries', '2025-06-13'::date, '2025-10-27'::date, '3.26.0'),
        ('Keepers',     '2025-10-31'::date, '2026-03-02'::date, '3.27.0'),
        ('Mirage',      '2026-03-06'::date, '2026-07-20'::date, '3.28.0')
),
modes (is_hardcore, prefix) AS (
    VALUES 
        (FALSE, ''),
        (TRUE, 'Hardcore ')
)
INSERT INTO dim_league (league_name, base_league, is_hardcore, start_date, end_date, release_version, league_length_days)
SELECT 
    TRIM(m.prefix || lm.base_league) AS league_name,
    lm.base_league,
    m.is_hardcore,
    lm.start_date,
    lm.end_date,
    lm.release_version,
    (COALESCE(lm.end_date, CURRENT_DATE) - lm.start_date)::integer AS league_length_days
FROM league_meta lm
CROSS JOIN modes m
ORDER BY lm.start_date, m.is_hardcore;

-- Obsługa lig specjalnych i eventów społeczności
INSERT INTO dim_league (league_name, base_league, is_hardcore, start_date, end_date, release_version, league_length_days)
VALUES 
    ('Ancestors',          'Mirage', false, '2026-06-25'::date, '2026-07-16'::date, 'Event', 21),
    ('Hardcore Ancestors', 'Mirage', true,  '2026-06-25'::date, '2026-07-16'::date, 'Event', 21);

-- Normalizacja nazewnictwa Hardcore Ruthless -> HC Ruthless
UPDATE dim_league
SET league_name = REPLACE(league_name, 'Hardcore Ruthless', 'HC Ruthless')
WHERE league_name LIKE 'Hardcore Ruthless%';

-- Przypisanie atrybutów analitycznych: Era ekonomiczna, Flaga Standard Trade, Indeks chronologiczny
WITH ranked_leagues AS (
    SELECT league_key, RANK() OVER (ORDER BY start_date ASC, league_name ASC) AS rnk
    FROM dim_league
)
UPDATE dim_league dl
SET league_index = rl.rnk,
    league_era = CASE 
        WHEN dl.start_date < '2022-08-19' THEN 'Exalt Era (Pre-3.19)'
        ELSE 'Divine Era (3.19+)'
    END,
    is_trade_challenge = (NOT dl.is_hardcore AND dl.league_name NOT ILIKE '%Ruthless%' AND dl.release_version != 'Event')
FROM ranked_leagues rl
WHERE dl.league_key = rl.league_key;

CREATE INDEX idx_dim_league_name ON dim_league(league_name);
CREATE INDEX idx_dim_league_base ON dim_league(base_league);
CREATE INDEX idx_dim_league_era ON dim_league(league_era);


-------------------------------------------------------------------------------------------------------
-- 3.3. WYMIAR PRZEDMIOTÓW (dim_item)
-------------------------------------------------------------------------------------------------------
-- Rola: Centralny słownik przedmiotów unikatowych i bazowych (156k unikalnych kombinacji).
-- Zapewnia podział na:
-- - item_slot: Sloty wyposażenia (Belt, Ring, Amulet, Body Armour, Weapon, Jewel, Flask itp.)
-- - item_tier: Oznaczenie prestiżowych przedmiotów Tier 0 (Chase) i Tier 1 (High Value)
-- - is_canonical: Flaga eliminująca szum wariantów (np. 4 Flasks jako standard rynkowy Mageblooda)
-------------------------------------------------------------------------------------------------------

DROP TABLE IF EXISTS dim_item CASCADE;

CREATE TABLE dim_item AS
SELECT 
    ROW_NUMBER() OVER (ORDER BY name, NULLIF(variant, ''), links) AS id_item,
    id AS id_name,
    name,
    basetype,
    NULLIF(variant, '') AS variant,
    links
FROM (
    SELECT DISTINCT
        id,
        name,
        basetype,
        variant,
        links
    FROM items
) sub;

ALTER TABLE dim_item ADD PRIMARY KEY (id_item);
CREATE INDEX idx_dim_item_id_name ON dim_item(id_name);
CREATE INDEX idx_dim_item_name ON dim_item(name);

-- Rozbudowa o atrybuty kategoryzacyjne
ALTER TABLE dim_item ADD COLUMN item_slot TEXT;
ALTER TABLE dim_item ADD COLUMN item_tier TEXT DEFAULT 'Other';
ALTER TABLE dim_item ADD COLUMN is_canonical BOOLEAN DEFAULT TRUE;

-- Klasyfikacja slotów ekwipunku na podstawie basetype i specyfiki gry
UPDATE dim_item
SET item_slot = CASE 
        WHEN basetype ILIKE '%Belt%' OR name IN ('Mageblood', 'Headhunter') THEN 'Belt'
        WHEN basetype ILIKE '%Ring%' OR name IN ('Nimis', 'Kalandra''s Touch', 'Original Sin', 'Helical Ring') THEN 'Ring'
        WHEN basetype ILIKE '%Amulet%' OR name IN ('Stranglegasp', 'Defiance of Destiny', 'Badge of the Brotherhood', 'Ashes of the Stars', 'Crystallised Omniscience', 'Simplex Amulet', 'Focused Amulet') THEN 'Amulet'
        WHEN basetype ILIKE '%Flask%' OR name = 'Progenesis' THEN 'Flask'
        WHEN basetype ILIKE '%Jewel%' OR name IN ('Voices', 'Sublime Vision', 'Watcher''s Eye', 'Unnatural Instinct', 'Thread of Hope', 'Melding of the Flesh', 'Forbidden Flame', 'Forbidden Flesh') THEN 'Jewel'
        WHEN basetype ILIKE '%Shield%' OR name IN ('The Squire', 'Aegis Aurora') THEN 'Shield'
        WHEN basetype ILIKE '%Gloves%' OR basetype ILIKE '%Gauntlets%' OR basetype ILIKE '%Mitts%' OR name IN ('Hateforge', 'Asenath''s Gentle Touch') THEN 'Gloves'
        WHEN basetype ILIKE '%Boots%' OR basetype ILIKE '%Greaves%' OR basetype ILIKE '%Slippers%' OR name IN ('Ralakesh''s Impatience', 'Skyforth') THEN 'Boots'
        WHEN basetype ILIKE '%Helmet%' OR basetype ILIKE '%Circlet%' OR basetype ILIKE '%Burgonet%' OR basetype ILIKE '%Pelt%' OR basetype ILIKE '%Crown%' OR basetype ILIKE '%Mask%' OR basetype ILIKE '%Cap%' THEN 'Helmet'
        WHEN basetype ILIKE '%Plate%' OR basetype ILIKE '%Vestment%' OR basetype ILIKE '%Armour%' OR basetype ILIKE '%Robe%' OR basetype ILIKE '%Garb%' OR basetype ILIKE '%Hauberk%' OR basetype ILIKE '%Lamellar%' OR basetype ILIKE '%Brigandine%' OR basetype ILIKE '%Doublet%' OR basetype ILIKE '%Tunic%' OR basetype ILIKE '%Jacket%' OR basetype ILIKE '%Coat%' OR name IN ('Stasis Prison', 'Kaom''s Heart', 'Shavronne''s Wrappings', 'Farrul''s Fur', 'Doryani''s Prototype', 'Dialla''s Malefaction', 'Inpulsa''s Broken Heart', 'The Covenant') THEN 'Body Armour'
        WHEN basetype ILIKE '%Bow%' OR basetype ILIKE '%Sword%' OR basetype ILIKE '%Axe%' OR basetype ILIKE '%Mace%' OR basetype ILIKE '%Wand%' OR basetype ILIKE '%Dagger%' OR basetype ILIKE '%Claw%' OR basetype ILIKE '%Staff%' OR basetype ILIKE '%Sceptre%' OR name IN ('Cospri''s Malice', 'Arakaali''s Fang', 'Windripper', 'Lioneye''s Glare') THEN 'Weapon'
        WHEN basetype ILIKE '%Map%' THEN 'Map'
        ELSE 'Other'
    END;

-- Korekta dedykowana: Cospri's Malice jest bronią (Jewelled Foil), a nie klejnotem
UPDATE dim_item SET item_slot = 'Weapon' WHERE name = 'Cospri''s Malice';

-- Klasyfikacja rzadkości i wartości (Tier 0 Chase / Tier 1 High Value / Tier 2 Meta & Build Enablers)
UPDATE dim_item
SET item_tier = CASE 
        WHEN name IN (
            'Mageblood', 'Headhunter', 'The Squire', 'Nimis', 'Kalandra''s Touch', 
            'Original Sin', 'Hateforge', 'Stasis Prison', 'Stranglegasp', 
            'Progenesis', 'Defiance of Destiny', 'Voices', 'Sublime Vision', 
            'Watcher''s Eye', 'Aegis Aurora', 'Simplex Amulet', 'Focused Amulet', 'Helical Ring'
        ) THEN 'Tier 0 (Chase)'
        WHEN name IN (
            'Asenath''s Gentle Touch', 'Badge of the Brotherhood', 'Crystallised Omniscience', 
            'Ashes of the Stars', 'Melding of the Flesh', 'Unnatural Instinct', 
            'Thread of Hope', 'Forbidden Flame', 'Forbidden Flesh', 'Farrul''s Fur', 
            'Cospri''s Malice', 'Arakaali''s Fang', 'Doryani''s Prototype', 
            'Shavronne''s Wrappings', 'Kaom''s Heart', 'Ralakesh''s Impatience', 
            'Dialla''s Malefaction', 'The Covenant', 'Inpulsa''s Broken Heart'
        ) THEN 'Tier 1 (High)'
        WHEN name IN (
            'Lightning Coil', 'The Fourth Vow', 'The Brass Dome', 'Loreweave', 'Heatshiver', 
            'Sandstorm Visage', 'Taste of Hate', 'Dying Sun', 'Bottled Faith', 'Oriath''s End', 
            'Ventor''s Gamble', 'Prism Guardian', 'Anathema', 'Polaric Devastation', 
            'Crown of the Inward Eye', 'Abyssus', 'Tabula Rasa', 'Bisco''s Collar', 
            'Sin''s Rebirth', 'Lion''s Roar', 'Replica Farrul''s Fur', 'Replica Dragonfang''s Flight', 
            'Atziri''s Reflection'
        ) THEN 'Tier 2 (Meta)'
        ELSE 'Other'
    END;

-- Eliminacja wariantów podrzędnych dla głównych unikatów na wykresach ogólnych
UPDATE dim_item
SET is_canonical = CASE
        WHEN name = 'Mageblood' AND variant != '4 Flasks' THEN FALSE
        WHEN name = 'Voices' AND variant NOT IN ('3 passives', '1 passive') AND variant IS NOT NULL THEN FALSE
        ELSE TRUE
    END;

CREATE INDEX idx_dim_item_tier ON dim_item(item_tier);
CREATE INDEX idx_dim_item_slot ON dim_item(item_slot);


-- ====================================================================================================
-- SEKCJA 4: TABELE FAKTÓW (FACT TABLES)
-- ====================================================================================================

-------------------------------------------------------------------------------------------------------
-- 4.1. CZYSZCZENIE ANOMALII W SUROWYCH DANYCH POE.NINJA
-------------------------------------------------------------------------------------------------------
-- Błąd literówki w zrzucie surowym dla 1 wpisu waluty
UPDATE currency 
SET value = 333.5745 
WHERE value = 333574.5;

-- Naprawa nazwy eventu Ancestors w surowych danych walut
UPDATE currency 
SET league = 'Hardcore Ancestors' 
WHERE league = 'Hardcore Ancestor' 
  AND date >= '2026-01-01' 
  AND date <= '2026-12-31';


-------------------------------------------------------------------------------------------------------
-- 4.2. TABELA FAKTÓW WALUT (fact_currency)
-------------------------------------------------------------------------------------------------------

DROP TABLE IF EXISTS fact_currency CASCADE;

CREATE TABLE fact_currency AS
SELECT
    dl.league_key,
    c.date,
    (c.date - dl.start_date + 1)::integer AS day_of_league,
    CEIL((c.date - dl.start_date + 1) / 7.0)::integer AS week_of_league,
    c.get,
    c.pay,
    c.value::double precision,
    c.confidence
FROM currency c
JOIN dim_league dl 
    ON dl.league_name = c.league;

ALTER TABLE fact_currency 
    ADD CONSTRAINT fk_curr_league FOREIGN KEY (league_key) REFERENCES dim_league(league_key);

CREATE INDEX idx_fct_curr_league ON fact_currency (league_key);
CREATE INDEX idx_fct_curr_day ON fact_currency (day_of_league);
CREATE INDEX idx_fct_curr_pairs ON fact_currency (get, pay);


-------------------------------------------------------------------------------------------------------
-- 4.3. TABELA FAKTÓW CEN PRZEDMIOTÓW (fact_item_prices)
-------------------------------------------------------------------------------------------------------

DROP TABLE IF EXISTS fact_item_prices CASCADE;

CREATE TABLE fact_item_prices AS
SELECT
    dl.league_key,
    di.id_item,
    i.date,
    (i.date - dl.start_date + 1)::integer AS day_of_league,
    CEIL((i.date - dl.start_date + 1) / 7.0)::integer AS week_of_league,
    i.value::double precision             AS value_chaos,
    i.confidence
FROM items i
JOIN dim_league dl 
    ON dl.league_name = i.league
JOIN dim_item di 
    ON di.id_name = i.id
   AND di.name     IS NOT DISTINCT FROM i.name
   AND di.basetype IS NOT DISTINCT FROM i.basetype
   AND di.variant  IS NOT DISTINCT FROM NULLIF(i.variant, '')
   AND di.links    IS NOT DISTINCT FROM i.links;

-- Klucz główny kompozytowy i więzy integralności
ALTER TABLE fact_item_prices 
    ADD PRIMARY KEY (league_key, id_item, date);

ALTER TABLE fact_item_prices 
    ADD CONSTRAINT fk_fct_league FOREIGN KEY (league_key) REFERENCES dim_league(league_key),
    ADD CONSTRAINT fk_fct_item   FOREIGN KEY (id_item)    REFERENCES dim_item(id_item);

CREATE INDEX idx_fct_item_day ON fact_item_prices (id_item, day_of_league);
CREATE INDEX idx_fct_league   ON fact_item_prices (league_key);


-- ====================================================================================================
-- SEKCJA 5: WARSTWA WIDOKÓW ANALITYCZNYCH
-- ====================================================================================================

-------------------------------------------------------------------------------------------------------
-- 5.1. WIDOK WALUT I KURSÓW KRZYŻOWYCH (v_fact_currency_daily)
-- Rola: Eliminuje potrzebę ręcznego łączenia setek par walutowych.
-- Automatycznie wylicza:
-- - Kurs w Chaosach (standard rynkowy poe.ninja)
-- - Kurs w Divinach (przeliczenie dla er 3.19+)
-- - Kurs w Exaltach (przeliczenie dla er pre-3.19)
-- - Kurs w Walucie Głównej (price_anchor_high)
-------------------------------------------------------------------------------------------------------

CREATE OR REPLACE VIEW v_fact_currency_daily AS
WITH divine_prices AS (
    SELECT league_key, date, value AS divine_chaos
    FROM fact_currency
    WHERE get = 'Divine Orb' AND pay = 'Chaos Orb'
),
exalt_prices AS (
    SELECT league_key, date, value AS exalt_chaos
    FROM fact_currency
    WHERE get = 'Exalted Orb' AND pay = 'Chaos Orb'
)
SELECT 
    fc.league_key,
    dl.league_name,
    dl.base_league,
    dl.release_version,
    dl.league_era,
    dl.is_trade_challenge,
    fc.date,
    fc.day_of_league,
    fc.week_of_league,
    fc.get AS currency_name,
    fc.value AS price_chaos,
    dp.divine_chaos AS divine_rate_chaos,
    ep.exalt_chaos AS exalt_rate_chaos,
    ROUND((fc.value / NULLIF(dp.divine_chaos, 0))::numeric, 4) AS price_divine,
    ROUND((fc.value / NULLIF(ep.exalt_chaos, 0))::numeric, 4) AS price_exalt,
    CASE 
        WHEN dl.start_date >= '2022-08-19' THEN ROUND((fc.value / NULLIF(dp.divine_chaos, 0))::numeric, 4)
        ELSE ROUND((fc.value / NULLIF(ep.exalt_chaos, 0))::numeric, 4)
    END AS price_anchor_high,
    CASE 
        WHEN dl.start_date >= '2022-08-19' THEN 'Divine'
        ELSE 'Exalt'
    END AS anchor_currency,
    fc.confidence
FROM fact_currency fc
JOIN dim_league dl ON fc.league_key = dl.league_key
LEFT JOIN divine_prices dp ON fc.league_key = dp.league_key AND fc.date = dp.date
LEFT JOIN exalt_prices ep ON fc.league_key = ep.league_key AND fc.date = ep.date
WHERE fc.pay = 'Chaos Orb';


-------------------------------------------------------------------------------------------------------
-- 5.2. WIDOK RYNKU UNIKATÓW TIER 0 I TIER 1 (v_fact_chase_items_daily)
-- Rola: Zamiast obciążać Power BI 110 milionami wierszy przez DirectQuery, ten widok wyciąga tylko
-- kluczowe unikatowe przedmioty rynkowe (~200k wierszy w historii, ~60k dla lig trade).
-- Może być załadowany do Power BI w trybie IMPORT.
-------------------------------------------------------------------------------------------------------

CREATE OR REPLACE VIEW v_fact_chase_items_daily AS
WITH divine_prices AS (
    SELECT league_key, date, value AS divine_chaos
    FROM fact_currency
    WHERE get = 'Divine Orb' AND pay = 'Chaos Orb'
),
exalt_prices AS (
    SELECT league_key, date, value AS exalt_chaos
    FROM fact_currency
    WHERE get = 'Exalted Orb' AND pay = 'Chaos Orb'
)
SELECT 
    f.league_key,
    dl.league_name,
    dl.base_league,
    dl.release_version,
    dl.league_era,
    dl.is_trade_challenge,
    f.id_item,
    di.name AS item_name,
    di.basetype AS item_basetype,
    di.item_slot,
    di.item_tier,
    di.variant,
    di.links,
    di.is_canonical,
    f.date,
    f.day_of_league,
    f.week_of_league,
    f.value_chaos,
    dp.divine_chaos AS divine_rate_chaos,
    ep.exalt_chaos AS exalt_rate_chaos,
    ROUND((f.value_chaos / NULLIF(dp.divine_chaos, 0))::numeric, 2) AS value_divine,
    ROUND((f.value_chaos / NULLIF(ep.exalt_chaos, 0))::numeric, 2) AS value_exalt,
    CASE 
        WHEN dl.start_date >= '2022-08-19' THEN ROUND((f.value_chaos / NULLIF(dp.divine_chaos, 0))::numeric, 2)
        ELSE ROUND((f.value_chaos / NULLIF(ep.exalt_chaos, 0))::numeric, 2)
    END AS value_anchor_high,
    CASE 
        WHEN dl.start_date >= '2022-08-19' THEN 'Divine'
        ELSE 'Exalt'
    END AS anchor_currency,
    f.confidence
FROM fact_item_prices f
JOIN dim_league dl ON f.league_key = dl.league_key
JOIN dim_item di ON f.id_item = di.id_item
LEFT JOIN divine_prices dp ON f.league_key = dp.league_key AND f.date = dp.date
LEFT JOIN exalt_prices ep ON f.league_key = ep.league_key AND f.date = ep.date
WHERE di.item_tier IN ('Tier 0 (Chase)', 'Tier 1 (High)', 'Tier 2 (Meta)');


-------------------------------------------------------------------------------------------------------
-- 5.3. WIDOK BENCHMARKINGU DNIA LIGI (v_benchmark_day_of_league)
-- Rola: Narzędzie wspomagania decyzji w trakcie trwania nowej ligi.
-- Oblicza statystyki rozkładu cen (Min, Avg, Max) dla każdego relatywnego dnia ligi.
-- Kolumna 'market_basket', dzieli przedmioty na koszyki skali (Apex, Standard, Chase, Meta),
-- dzięki czemu Mirror i Divine nie zniekształcają wzajemnie skali na jednym wykresie.
-------------------------------------------------------------------------------------------------------

DROP VIEW IF EXISTS v_benchmark_day_of_league CASCADE;

CREATE VIEW v_benchmark_day_of_league AS
WITH currency_bench AS (
    SELECT 
        day_of_league,
        league_era,
        currency_name AS entity_name,
        'Currency' AS entity_type,
        CASE 
            WHEN currency_name IN ('Mirror of Kalandra', 'Mirror Shard') THEN 'Waluty Apex (Mirror Scale)'
            ELSE 'Waluty Standard (Chaos Scale)'
        END AS market_basket,
        COUNT(DISTINCT league_key) AS leagues_count,
        ROUND(AVG(price_chaos)::numeric, 1) AS avg_chaos,
        ROUND(MIN(price_chaos)::numeric, 1) AS min_chaos,
        ROUND(MAX(price_chaos)::numeric, 1) AS max_chaos,
        ROUND(AVG(price_divine)::numeric, 2) AS avg_divine,
        ROUND(MIN(price_divine)::numeric, 2) AS min_divine,
        ROUND(MAX(price_divine)::numeric, 2) AS max_divine
    FROM v_fact_currency_daily
    WHERE is_trade_challenge AND day_of_league <= 120
      AND currency_name IN ('Divine Orb', 'Exalted Orb', 'Mirror of Kalandra', 'Mirror Shard')
    GROUP BY day_of_league, league_era, currency_name
),
item_bench AS (
    SELECT 
        day_of_league,
        league_era,
        item_name AS entity_name,
        'Item' AS entity_type,
        CASE 
            WHEN item_name IN ('Mageblood', 'Headhunter') THEN 'Paski Chase (Mageblood/HH)'
            WHEN item_name IN ('Nimis', 'The Squire', 'Original Sin') THEN 'Akcesoria Chase (Nimis/Squire)'
            ELSE 'Unikaty Meta (Doryani/Coil)'
        END AS market_basket,
        COUNT(DISTINCT league_key) AS leagues_count,
        ROUND(AVG(value_chaos)::numeric, 1) AS avg_chaos,
        ROUND(MIN(value_chaos)::numeric, 1) AS min_chaos,
        ROUND(MAX(value_chaos)::numeric, 1) AS max_chaos,
        ROUND(AVG(value_divine)::numeric, 2) AS avg_divine,
        ROUND(MIN(value_divine)::numeric, 2) AS min_divine,
        ROUND(MAX(value_divine)::numeric, 2) AS max_divine
    FROM v_fact_chase_items_daily
    WHERE is_trade_challenge AND is_canonical AND day_of_league <= 120
      AND item_name IN ('Mageblood', 'Headhunter', 'The Squire', 'Nimis', 'Doryani''s Prototype', 'Lightning Coil')
    GROUP BY day_of_league, league_era, item_name
)
SELECT * FROM currency_bench
UNION ALL
SELECT * FROM item_bench;


-------------------------------------------------------------------------------------------------------
-- 5.4. WIDOK KALKULATORA ROI WCZESNEJ LIGI (v_early_league_roi)
-- Rola: Zaawansowana matryca zwrotu z inwestycji (ROI).
-- Porównuje zakup aktywów w Dniu 3 (wczesna faza) ze sprzedażą w Dniu 7, 14 i 28.
-- Wylicza ROI % zarówno w Divinach, jak i w Chaosach dla kluczowych walut i unikatów.
-------------------------------------------------------------------------------------------------------

DROP VIEW IF EXISTS v_early_league_roi CASCADE;

CREATE VIEW v_early_league_roi AS
WITH asset_days AS (
    SELECT 
        league_key,
        currency_name AS entity_name,
        'Currency' AS entity_type,
        'Currency' AS item_slot,
        day_of_league,
        price_chaos AS p_chaos,
        price_divine AS p_divine
    FROM v_fact_currency_daily
    WHERE is_trade_challenge 
      AND day_of_league IN (3, 7, 14, 28)
      AND currency_name IN ('Divine Orb', 'Mirror of Kalandra', 'Mirror Shard', 'Exalted Orb')
    
    UNION ALL
    
    SELECT 
        league_key,
        item_name,
        'Item' AS entity_type,
        item_slot,
        day_of_league,
        value_chaos AS p_chaos,
        value_divine AS p_divine
    FROM v_fact_chase_items_daily
    WHERE is_trade_challenge AND is_canonical
      AND day_of_league IN (3, 7, 14, 28)
      AND item_name IN ('Mageblood', 'Headhunter', 'The Squire', 'Nimis', 'Doryani''s Prototype', 'Lightning Coil')
),
pivoted AS (
    SELECT 
        ad.league_key,
        ad.entity_name,
        ad.entity_type,
        ad.item_slot,
        AVG(CASE WHEN ad.day_of_league = 3 THEN ad.p_chaos END) AS p3_chaos,
        AVG(CASE WHEN ad.day_of_league = 7 THEN ad.p_chaos END) AS p7_chaos,
        AVG(CASE WHEN ad.day_of_league = 14 THEN ad.p_chaos END) AS p14_chaos,
        AVG(CASE WHEN ad.day_of_league = 28 THEN ad.p_chaos END) AS p28_chaos,
        AVG(CASE WHEN ad.day_of_league = 3 THEN ad.p_divine END) AS p3_div,
        AVG(CASE WHEN ad.day_of_league = 7 THEN ad.p_divine END) AS p7_div,
        AVG(CASE WHEN ad.day_of_league = 14 THEN ad.p_divine END) AS p14_div,
        AVG(CASE WHEN ad.day_of_league = 28 THEN ad.p_divine END) AS p28_div
    FROM asset_days ad
    GROUP BY ad.league_key, ad.entity_name, ad.entity_type, ad.item_slot
)
SELECT 
    dl.league_key,
    dl.league_name,
    dl.start_date,
    dl.release_version,
    dl.league_era,
    pv.entity_name,
    pv.entity_type,
    pv.item_slot,
    ROUND(pv.p3_chaos::numeric, 1) AS buy_day3_chaos,
    ROUND(pv.p7_chaos::numeric, 1) AS sell_day7_chaos,
    ROUND(pv.p14_chaos::numeric, 1) AS sell_day14_chaos,
    ROUND(pv.p28_chaos::numeric, 1) AS sell_day28_chaos,
    ROUND(((pv.p7_chaos - pv.p3_chaos) / NULLIF(pv.p3_chaos, 0) * 100)::numeric, 1) AS roi_day7_chaos_pct,
    ROUND(((pv.p14_chaos - pv.p3_chaos) / NULLIF(pv.p3_chaos, 0) * 100)::numeric, 1) AS roi_day14_chaos_pct,
    ROUND(((pv.p28_chaos - pv.p3_chaos) / NULLIF(pv.p3_chaos, 0) * 100)::numeric, 1) AS roi_day28_chaos_pct,
    ROUND(pv.p3_div::numeric, 2) AS buy_day3_div,
    ROUND(pv.p7_div::numeric, 2) AS sell_day7_div,
    ROUND(pv.p14_div::numeric, 2) AS sell_day14_div,
    ROUND(pv.p28_div::numeric, 2) AS sell_day28_div,
    ROUND(((pv.p7_div - pv.p3_div) / NULLIF(pv.p3_div, 0) * 100)::numeric, 1) AS roi_day7_div_pct,
    ROUND(((pv.p14_div - pv.p3_div) / NULLIF(pv.p3_div, 0) * 100)::numeric, 1) AS roi_day14_div_pct,
    ROUND(((pv.p28_div - pv.p3_div) / NULLIF(pv.p3_div, 0) * 100)::numeric, 1) AS roi_day28_div_pct
FROM pivoted pv
JOIN dim_league dl ON pv.league_key = dl.league_key
WHERE pv.p3_chaos IS NOT NULL;



-------------------------------------------------------------------------------------------------------
-- 5.5. WIDOK AKTYWÓW INWESTYCYJNYCH (v_fact_investment_assets_daily)
-- Rola: Łączy kluczowe waluty inwestycyjne (Mirror Shard, Annulment, Hinekora, Sextants itp.) 
-- oraz unikatowe przedmioty Chase/Meta w jedną zunifikowaną strukturę.
-------------------------------------------------------------------------------------------------------

CREATE OR REPLACE VIEW v_fact_investment_assets_daily AS
SELECT 
    fc.league_key,
    dl.league_name,
    dl.league_era,
    dl.is_trade_challenge,
    fc.currency_name AS asset_name,
    'Currency' AS asset_category,
    fc.day_of_league,
    fc.week_of_league,
    fc.price_chaos AS value_chaos,
    fc.price_divine AS value_divine
FROM v_fact_currency_daily fc
JOIN dim_league dl ON fc.league_key = dl.league_key
WHERE fc.currency_name IN (
    'Mirror of Kalandra', 'Mirror Shard', 'Divine Orb', 'Exalted Orb',
    'Orb of Annulment', 'Ancient Orb', 'Awakened Sextant', 'Elevated Sextant',
    'Hinekora''s Lock', 'Fracturing Orb', 'Fracturing Shard', 'Veiled Chaos Orb',
    'Veiled Orb', 'Sacred Orb', 'Awakener''s Orb', 'Crusader''s Orb',
    'Hunter''s Orb', 'Redeemer''s Orb', 'Warlord''s Orb', 'Valdo''s Puzzle Box',
    'Reflecting Mist', 'Orb of Dominance', 'Orb of Conflict', 'Tempering Orb', 'Tailoring Orb'
) AND fc.is_trade_challenge AND fc.day_of_league <= 120

UNION ALL

SELECT 
    fi.league_key,
    fi.league_name,
    fi.league_era,
    fi.is_trade_challenge,
    fi.item_name AS asset_name,
    'Unique Item' AS asset_category,
    fi.day_of_league,
    fi.week_of_league,
    fi.value_chaos,
    fi.value_divine
FROM v_fact_chase_items_daily fi
WHERE fi.is_canonical AND fi.is_trade_challenge AND fi.day_of_league <= 120;
