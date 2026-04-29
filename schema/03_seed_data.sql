/*
-- IMPACT RESULTS --
Illustrative LCIA scores for the three processes.
In a real pipeline these would be calculated from exchanges x CF tables.
Values are plausible orders of magnitude for CML 2002.
*/

INSERT INTO impact_results
    (process_id, impact_category_id, value)
VALUES
    -- Wheat farming
    (1, 1, 0.350),
    -- GWP100: 0.350 kg CO2-eq per kg wheat
    (1, 2, 0.00280),
    -- AP:     0.00280 kg SO2-eq
    (1, 3, 0.00210),
    -- EP:     0.00210 kg PO4-eq
    (1, 4, 2.10),
    -- CED:    2.10 MJ

    -- Lorry transport (per tkm)
    (2, 1, 0.000098),
    -- GWP100: 0.000098 kg CO2-eq per tkm
    (2, 2, 0.00000071),-- AP
    (2, 3, 0.0),
    -- EP:     negligible
    (2, 4, 0.00143),
    -- CED:    0.00143 MJ per tkm

    -- Flour milling (per kg flour)
    (3, 1, 0.512),
    -- GWP100: 0.512 kg CO2-eq per kg flour (includes upstream wheat + transport)
    (3, 2, 0.00341),
    -- AP
    (3, 3, 0.00224),
    -- EP
    (3, 4, 3.86);      -- CED:    3.86 MJ per kg flour