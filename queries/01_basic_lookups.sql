/*
- LCA Supply Chain Database
- File: 01_basic_lookups.sql
- Description: Simple single-table selects. Confirms data is present and readable before moving to joins and aggregations.

Run with:
    docker compose exec -T postgres psql -U lca_user -d lca_supply_chain < queries/01_basic_lookups.sql
*/

-- PROCESSES
-- Expected: 3 rows (wheat farming, lorry transport, flour milling)
SELECT
    p.id,
    p.name,
    p.reference_year,
    p.source_dataset
FROM processes p
ORDER BY p.id;

-- FLOWS BY TYPE
-- Expected: 5 product flows, 6 elementary flows, 0 waste flows
SELECT
    f.flow_type,
    COUNT(*) AS flow_count
FROM flows f
GROUP BY f.flow_type
ORDER BY f.flow_type;

-- ALL FLOWS WITH UNIT
-- Expected: 11 rows
SELECT
    f.id,
    f.name,
    f.flow_type,
    u.name AS unit
FROM flows f
LEFT JOIN units u ON u.id = f.unit_id
ORDER BY f.flow_type, f.id;

-- IMPACT CATEGORIES
-- Expected: 4 rows (GWP100, AP, EP, CED)
SELECT
    ic.code,
    ic.name,
    ic.method,
    ic.unit
FROM impact_categories ic
ORDER BY ic.id;

-- GEOGRAPHIES
-- Expected: 5 rows
SELECT
    g.code,
    g.name,
    g.is_global
FROM geographies g
ORDER BY g.is_global DESC, g.code;

-- CATEGORY TREE
-- Flat display of the category using full_path.
-- Expected: 8 rows (4 top-level, 4 sub-categories)
SELECT
    c.id,
    c.full_path,
    CASE
        WHEN c.parent_id IS NULL THEN 'top-level' ELSE 'sub-category'
    END AS level
FROM categories c
ORDER BY c.full_path;