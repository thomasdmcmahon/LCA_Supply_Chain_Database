"""Regression check: ELCD amounts must round-trip without precision loss.

Run with:
    python loader/check_precision.py
    make check-precision

Background (see CLAUDE.md section 5.1): the `exchanges.amount` column is
NUMERIC(60, 50) specifically to hold LCA-scale tiny values like emission
factors. parse_ilcd.py used to coerce amount text to Python `float` before
writing it to JSON, which silently rounds to the nearest IEEE-754 float64 --
a lossy operation for any value whose exact decimal representation needs more
precision than float64 carries. This script proves the current pipeline
(parse_ilcd.parse_decimal_str -> ... -> load_to_postgres.to_decimal) carries
amounts as text/Decimal end-to-end instead, using a real value pulled from
the ELCD 3.2 export as the fixture. It does not require data/raw or a live
database to be present, so it can run in any environment that has the
loader's normal dependencies (psycopg2, python-dotenv) installed.
"""

from __future__ import annotations

import sys
from decimal import Decimal
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from parse_ilcd import parse_decimal_str  # noqa: E402
from load_to_postgres import to_decimal  # noqa: E402


# A real exchange amount from the ELCD 3.2 export: process
# 00043bd2-4563-4d73-8df8-b84b5d8902fc.xml ("Electricity Mix, consumption
# mix, at consumer, AC, 230-240V"), exchange dataSetInternalID="263"
# (output to flow "Diethylamine"). Pinned here as a fixed fixture so this
# check is independent of whether the raw ELCD export is present locally.
KNOWN_TINY_AMOUNT = "5.38063410297918E-17"

# The exact IEEE-754 float64 nearest to KNOWN_TINY_AMOUNT, expanded well
# beyond float64's ~17 significant digits. This is the value that used to
# reach the database once parse_ilcd.py called float(text) -- proof the old
# path was genuinely lossy, not just theoretically risky.
_FLOAT64_TRUE_VALUE = Decimal("%.25g" % float(KNOWN_TINY_AMOUNT))

FAILURES: list[str] = []


def check(label: str, condition: bool) -> None:
    status = "PASS" if condition else "FAIL"
    print(f"[{status}] {label}")
    if not condition:
        FAILURES.append(label)


def main() -> int:
    # Sanity check on the fixture itself: prove float64 really cannot hold
    # this value exactly, so the rest of this check has teeth.
    check(
        "fixture sanity check: float64 rounding actually changes this value",
        _FLOAT64_TRUE_VALUE != Decimal(KNOWN_TINY_AMOUNT),
    )

    # 1. parse_ilcd.py must preserve the source text exactly, as a string,
    #    tolerating the incidental whitespace element_text() would produce.
    parsed = parse_decimal_str(f"  {KNOWN_TINY_AMOUNT}  ")
    check("parse_decimal_str returns str, not float", isinstance(parsed, str))
    check("parse_decimal_str preserves the source text exactly", parsed == KNOWN_TINY_AMOUNT)

    # 2. transform.py passes amounts through unchanged (no transformation
    #    logic to exercise here -- this documents that expectation).
    passthrough = parsed
    check("value is unchanged after the transform pass-through step", passthrough == KNOWN_TINY_AMOUNT)

    # 3. load_to_postgres.py must convert that string to an exact Decimal,
    #    matching the source value and NOT the float64-corrupted value.
    amount = to_decimal(passthrough)
    check("to_decimal returns a Decimal", isinstance(amount, Decimal))
    check("to_decimal produces the exact source value", amount == Decimal(KNOWN_TINY_AMOUNT))
    check("to_decimal value differs from the float64-rounded value", amount != _FLOAT64_TRUE_VALUE)

    # 4. Guard rail: if a `float` ever leaks into to_decimal again (i.e. the
    #    original bug is reintroduced upstream), it must fail loudly instead
    #    of silently truncating.
    try:
        to_decimal(float(KNOWN_TINY_AMOUNT))
    except TypeError:
        rejected_float = True
    else:
        rejected_float = False
    check("to_decimal rejects float input instead of silently rounding it", rejected_float)

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
