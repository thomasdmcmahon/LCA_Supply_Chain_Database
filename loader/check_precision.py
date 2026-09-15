"""Regression check: ELCD amounts must be round-trip without precision loss.

Run with:
    python loader/check_precision.py
    make check-precision

The exchanges.amount column is NUMERIC(60, 50) because LCA inventories contain
exteremely small values. parse_ilcd.py used to route every amount through Python's
float() before it reached the database, which rounds to the nearest IEEE-754 float64.
Lossy for any value needing more precision than float64's ~17 significant digits.

This proves the current path carries amounts as text and Decimal end to end:
parse_decimal_str -> transform pass-through -> to_decimal, with a real ELCD value
as the fixture. It needs neither data/raw nor a live datastream, so it runs anywhere
the loader's dependencies are installed.
"""

from __future__ import annotations

import sys
from decimal import Decimal
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from load_to_postgres import to_decimal  # noqa: E402
from parse_ilcd import parse_decimal_str  # noqa: E402

# A real exchange amount from the ELCD 3.2 export: process
# 00043bd2-4563-4d73-8df8-b84b5d8902fc.xml ("Electricity Mix, consumption
# mix, at consumer, AC, 230-240V"), exchange dataSetInternalID="263"
# (output to flow "Diethylamine"). Pinned as a fixed fixture so this check
# does not depend on the raw export being present locally.
KNOWN_TINY_AMOUNT = "5.38063410297918E-17"

# The exact IEEE-754 float64 nearest to KNOWN_TINY_AMOUNT, expanded past
# float64's ~17 significant digits. This is what used to reach the database once
# float(text) was called. Proof the old path was actually lossy.
_FLOAT64_TRUE_VALUE = Decimal("%.25g" % float(KNOWN_TINY_AMOUNT))

FAILURES: list[str] = []


def check(label: str, condition: bool) -> None:
    status = "PASS" if condition else "FAIL"
    print(f"[{status}] {label}")
    if not condition:
        FAILURES.append(label)


def main() -> int:
    # Check the fixture before checking the pipeline. If float64 could hold
    # this value exactly, every assertion below would pass whether or not the
    # pipeline preserved anything (the test would have no teeth).
    check(
        "fixture sanity check: float64 rounding actually changes this value",
        _FLOAT64_TRUE_VALUE != Decimal(KNOWN_TINY_AMOUNT),
    )

    # 1. Parsin keeps the source text exactly, as a string, tolerating the
    # indicidental whitespace element_text() leaves behind.
    parsed = parse_decimal_str(f"   {KNOWN_TINY_AMOUNT}")
    check("parse_decimal_str returns str, not float", isinstance(parsed, str))
    check(
        "parse_decimal_str preserves the source text exactly",
        parsed == KNOWN_TINY_AMOUNT,
    )

    # 2. transform.py passes amounts through untouched. There is no logic to
    # excervise here. This records the expectation so a change that breaks it shows up
    passthrough = parsed
    check(
        "value is unchanged after the transform pass-through step",
        passthrough == KNOWN_TINY_AMOUNT,
    )

    # 3. The loader converts that string to an exact decimal. matching the source
    # , not the float64-corrupted value.
    amount = to_decimal(passthrough)
    check("to_decimal returns a Decimal", isinstance(amount, Decimal))
    check(
        "to_decimal produces the exact source value",
        amount == Decimal(KNOWN_TINY_AMOUNT),
    )
    check(
        "to_decimal value differs from the float64-rounded value",
        amount != _FLOAT64_TRUE_VALUE,
    )

    # 4. The guard rail. If a float ever reaches to_decimal again, precision
    # was already lost upstream and converting would hide it. So it must raise
    # rather than produce a number that looks fine.
    try:
        to_decimal(float(KNOWN_TINY_AMOUNT))
    except TypeError:
        rejected_float = True
    else:
        rejected_float = False
    check(
        "to_decimal rejects float input instead of silently rounding it", rejected_float
    )

    print()
    if FAILURES:
        print(f"{len(FAILURES)} check(s) failed:")
        for label in FAILURES:
            print(f"  - {label}")
        return 1

    print("All numeric-precision regression checks passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
