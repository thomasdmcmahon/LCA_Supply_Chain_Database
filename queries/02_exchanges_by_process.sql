/*
Exchanges joined to their process, flow and unit. The bill of material for each process, and the join pattern most other queries build on.

Scoped to the seed data. Against the full ELCD load these return 212k rows; add a process filter before running them there.

Run with:
    docker compoze exec -T postgres psql -U lca_user -d lca_supply_chain < queries/02_exchanges_by_process.sql
*/


/*
Everything in context. direction DESC puts outputs first so each process reads product-out then inputs. 17 rows on seed data.
*/
SELECT
    p.name AS process,
    e.direction,
    f.name AS flow,
    e.amount,
    u.name AS unit,
    e.is_reference_flow
FROM exchanges e
    JOIN processes p ON p.id = e.process_id
    JOIN flows f ON f.id = e.flow_id
    LEFT JOIN units u ON u.id = e.unit_id
ORDER BY p.id, e.direction DESC, e.is_reference_flow DESC;

/*
Inputs only (what each process consumes). Reading these bottom-up is how the supply chain traversal work: each product input resolves to the process that produces it.
*/
SELECT
    p.name AS process,
    f.name AS input_flow,
    f.flow_type,
    e.amount,
    u.name AS unit
FROM exchanges e
    JOIN processes p ON p.id = e.process_id
    JOIN flows f ON f.id = e.flow_id
    JOIN units u ON u.id = e.unit_id
WHERE e.direction = 'input'
ORDER BY p.id, f.flow_type;

/*
Outputs. The product the process exists to make, plus everything it emits. Reference flow first.
*/
SELECT
    p.name AS process,
    f.name AS output_flow,
    f.flow_type,
    e.amount,
    u.name AS unit,
    e.is_reference_flow
FROM exchanges e
    JOIN processes p ON p.id = e.process_id
    JOIN flows f ON f.id = e.flow_id
    JOIN units u ON u.id = e.unit_id
WHERE e.direction = 'output'
ORDER BY p.id, e.is_reference_flow DESC, f.flow_type;