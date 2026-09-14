-- tests/verify.sql — kjør før push
\set ON_ERROR_STOP on
\pset border 2

\echo '=== Referansestrømmer ==='
SELECT CASE WHEN count(*) = 0 THEN 'PASS' ELSE 'FAIL: ' || count(*) END AS alle_prosesser_har_referansestrom
FROM processes p
WHERE NOT EXISTS (
  SELECT 1 FROM exchanges e WHERE e.process_id = p.id AND e.is_reference_flow
);

\echo '=== convert_amount ==='
SELECT
  CASE WHEN convert_amount(1000, (SELECT id FROM units WHERE name='kg'), (SELECT id FROM units WHERE name='t')) = 1
       THEN 'PASS' ELSE 'FAIL' END AS kg_til_tonn,
  CASE WHEN convert_amount(1, (SELECT id FROM units WHERE name='kWh'), (SELECT id FROM units WHERE name='MJ')) = 3.6
       THEN 'PASS' ELSE 'FAIL' END AS kwh_til_mj,
  CASE WHEN convert_amount(1, (SELECT id FROM units WHERE name='kg'), (SELECT id FROM units WHERE name='MJ')) IS NULL
       THEN 'PASS' ELSE 'FAIL' END AS masse_til_energi_er_null;

\echo '=== Traversering og skalering ==='
SELECT
  CASE WHEN count(*) = 3 THEN 'PASS' ELSE 'FAIL: ' || count(*) END AS antall_prosesser,
  CASE WHEN max(cumulative_scale) = 1.35 THEN 'PASS' ELSE 'FAIL' END AS hvetedyrking_skala,
  CASE WHEN min(cumulative_scale) = 0.27 THEN 'PASS' ELSE 'FAIL' END AS transport_skala
FROM supply_chain_scaled_processes(3, 1.0);

SELECT CASE WHEN count(*) = 1 THEN 'PASS' ELSE 'FAIL: ' || count(*) END AS dybdegrense_0
FROM supply_chain_scaled_processes(3, 1.0, 0);

\echo '=== Inventar ==='
SELECT
  CASE WHEN round(total_amount, 10) = 0.00021065 THEN 'PASS' ELSE 'FAIL: ' || total_amount END AS co2_kjede,
  CASE WHEN skipped_unconvertible_count = 0 THEN 'PASS' ELSE 'FAIL' END AS ingen_hoppet_over
FROM supply_chain_inventory(3, 1.0)
WHERE flow_name = 'Carbon dioxide, fossil';

\echo '=== Cradle-to-gate ==='
SELECT
  ic.code,
  CASE WHEN ic.code = 'GWP100' AND round(calc.value, 10) = 0.00021065 THEN 'PASS'
       WHEN ic.code = 'EP'     AND round(calc.value, 10) = 0.0001890  THEN 'PASS'
       WHEN ic.code = 'AE'                                             THEN 'SJEKK: ' || calc.value
       ELSE 'FAIL: ' || calc.value END AS resultat
FROM calculate_cradle_to_gate_impacts(3, 1.0) AS calc
JOIN impact_categories ic ON ic.id = calc.impact_category_id
ORDER BY ic.code;

\echo '=== Dekningshull ==='
SELECT CASE WHEN count(*) = 2 THEN 'PASS' ELSE 'FAIL: ' || count(*) END AS to_ukarakteriserte_stromme
FROM v_elementary_flows_without_cf
WHERE flow_id IN (
  SELECT DISTINCT e.flow_id FROM exchanges e
  JOIN processes p ON p.id = e.process_id
  WHERE p.source_dataset = 'Seed data (illustrative)'
);