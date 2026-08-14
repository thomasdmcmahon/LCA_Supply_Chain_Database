"""Independent reference computation for the LCIA calculation engine.

Run with:
    python loader/validate_lcia_seed.py
    make validate-lcia-seed

This does NOT touch the database (Decimal arithmetic only) and does NOT
implement the SQL engine's logic by importing it -- it is a deliberately
independent, from-scratch recomputation of the same numbers, transcribed
directly from schema/03_seed_data.sql (exchange amounts) and
schema/04_characterization_factors.sql (factors). The point is to have a
second, differently-derived source of truth to compare the SQL engine
against, not to test the SQL by re-running it.

Prints the same expected values documented in
queries/09_lcia_calculation_validation.sql and
queries/10_supply_chain_rollup_examples.sql. After running those query files
against a live database (`make psql` or `docker compose exec ...`), diff the
output by eye against what this script prints -- they should match exactly
(these are small, exact decimal fractions, not floating point, so "exactly"
is a meaningful bar here, not an approximation).
"""

from __future__ import annotations

from decimal import Decimal, getcontext

getcontext().prec = 50

# Elementary exchange amounts, transcribed from schema/03_seed_data.sql.
# process name -> {flow name -> amount}
WHEAT_FARMING = {
    "Carbon dioxide, fossil": Decimal("0.00013"),
    "Ammonia": Decimal("0.0028"),
    "Nitrate, to water": Decimal("0.0019"),
    "Phosphate, to water": Decimal("0.00014"),
    "Water, river": Decimal("0.42"),  # input (resource), not characterized
}
LORRY_TRANSPORT = {
    "Carbon dioxide, fossil": Decimal("0.000095"),
    "Nitrogen oxides": Decimal("0.00000062"),
}
FLOUR_MILLING = {
    "Carbon dioxide, fossil": Decimal("0.0000095"),
}

# Reference-flow amounts and the input amount flour milling requires from
# each upstream process, transcribed from schema/03_seed_data.sql.
FLOUR_MILLING_REFERENCE_AMOUNT = Decimal("1.0")  # 1 kg flour
WHEAT_FARMING_REFERENCE_AMOUNT = Decimal("1.0")  # 1 kg grain
LORRY_REFERENCE_AMOUNT = Decimal("1.0")  # 1 tkm
FLOUR_MILLING_WHEAT_INPUT = Decimal("1.35")  # kg grain per kg flour
FLOUR_MILLING_TRANSPORT_INPUT = Decimal("0.27")  # tkm per kg flour

# Characterization factors, transcribed from
# schema/04_characterization_factors.sql. Flow -> (impact category code, factor).
CFS = {
    "Carbon dioxide, fossil": ("GWP100", Decimal("1")),
    "Phosphate, to water": ("EP", Decimal("1")),
    "Ammonia": ("AE", Decimal("3.02")),
    "Nitrogen oxides": ("AE", Decimal("0.74")),
}

FAILURES: list[str] = []


def check(label: str, actual: Decimal, expected: Decimal) -> None:
    ok = actual == expected
    status = "PASS" if ok else "FAIL"
    print(f"[{status}] {label}: {actual} (expected {expected})")
    if not ok:
        FAILURES.append(label)


def direct_impacts(exchanges: dict[str, Decimal]) -> dict[str, Decimal]:
    totals: dict[str, Decimal] = {}
    for flow, amount in exchanges.items():
        if flow not in CFS:
            continue
        category, factor = CFS[flow]
        totals[category] = totals.get(category, Decimal(0)) + amount * factor
    return totals


def main() -> int:
    print("=== Direct impacts per process ===")
    wheat_direct = direct_impacts(WHEAT_FARMING)
    check("Wheat farming GWP100", wheat_direct.get("GWP100", Decimal(0)), Decimal("0.00013"))
    check("Wheat farming AE", wheat_direct.get("AE", Decimal(0)), Decimal("0.008456"))
    check("Wheat farming EP", wheat_direct.get("EP", Decimal(0)), Decimal("0.00014"))

    lorry_direct = direct_impacts(LORRY_TRANSPORT)
    check("Lorry transport GWP100", lorry_direct.get("GWP100", Decimal(0)), Decimal("0.000095"))
    check("Lorry transport AE", lorry_direct.get("AE", Decimal(0)), Decimal("0.0000004588"))

    flour_direct = direct_impacts(FLOUR_MILLING)
    check("Flour milling GWP100", flour_direct.get("GWP100", Decimal(0)), Decimal("0.0000095"))

    print("\n=== Cradle-to-gate rollup (target: 1 kg flour, process 3) ===")
    scale_flour = FLOUR_MILLING_REFERENCE_AMOUNT / FLOUR_MILLING_REFERENCE_AMOUNT  # 1.0
    scale_wheat = scale_flour * (FLOUR_MILLING_WHEAT_INPUT / WHEAT_FARMING_REFERENCE_AMOUNT)
    scale_lorry = scale_flour * (FLOUR_MILLING_TRANSPORT_INPUT / LORRY_REFERENCE_AMOUNT)
    check("scale(wheat farming)", scale_wheat, Decimal("1.35"))
    check("scale(lorry transport)", scale_lorry, Decimal("0.27"))

    inventory: dict[str, Decimal] = {}
    for flow, amount in FLOUR_MILLING.items():
        inventory[flow] = inventory.get(flow, Decimal(0)) + amount * scale_flour
    for flow, amount in WHEAT_FARMING.items():
        inventory[flow] = inventory.get(flow, Decimal(0)) + amount * scale_wheat
    for flow, amount in LORRY_TRANSPORT.items():
        inventory[flow] = inventory.get(flow, Decimal(0)) + amount * scale_lorry

    check("Inventory: Carbon dioxide, fossil", inventory.get("Carbon dioxide, fossil", Decimal(0)), Decimal("0.00021065"))
    check("Inventory: Ammonia", inventory.get("Ammonia", Decimal(0)), Decimal("0.003780"))
    check("Inventory: Phosphate, to water", inventory.get("Phosphate, to water", Decimal(0)), Decimal("0.0001890"))
    check("Inventory: Nitrogen oxides", inventory.get("Nitrogen oxides", Decimal(0)), Decimal("0.0000001674"))

    print("\n=== Cradle-to-gate impacts ===")
    cradle_to_gate = direct_impacts(inventory)
    check("Cradle-to-gate GWP100", cradle_to_gate.get("GWP100", Decimal(0)), Decimal("0.00021065"))
    check("Cradle-to-gate AE", cradle_to_gate.get("AE", Decimal(0)), Decimal("0.011415723876"))
    check("Cradle-to-gate EP", cradle_to_gate.get("EP", Decimal(0)), Decimal("0.0001890"))

    print()
    if FAILURES:
        print(f"{len(FAILURES)} check(s) failed:")
        for label in FAILURES:
            print(f"  - {label}")
        return 1

    print("All reference computations match by-hand expectations.")
    print("Now compare these numbers against queries/09_lcia_calculation_validation.sql")
    print("and queries/10_supply_chain_rollup_examples.sql run against a live database.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
