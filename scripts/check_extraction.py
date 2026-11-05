"""Check an extraction output (protocol_field CSV) against the VITAL expected values (A04).

Example:
    python scripts/check_extraction.py --expected docs/extraction/vital-expected-values.csv \\
        --rows docs/extraction/vital-sample-output.csv
"""

import argparse
import csv
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from pi_extraction.scoring import score_rows  # noqa: E402


def _read(path: str) -> list[dict]:
    with open(path, newline="", encoding="utf-8") as f:
        rows = list(csv.DictReader(f))
    for r in rows:
        for k, v in r.items():
            if v == "":
                r[k] = None
        if r.get("value_number") is not None:
            r["value_number"] = float(r["value_number"])
        if r.get("page_number") is not None:
            r["page_number"] = int(float(r["page_number"]))
    return rows


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--expected", required=True)
    ap.add_argument("--rows", required=True)
    args = ap.parse_args()
    expected = _read(args.expected)
    for e in expected:
        e["expected_value"] = e["expected_value"] or ""
        e["element_key"] = e["element_key"] or ""
    r = score_rows(_read(args.rows), expected)

    print(f"Values correct: {r['values_correct']}/{r['values_total']}")
    print(f"Pages correct: {r['pages_correct']}/{r['pages_checked']}")
    print(f"Quotes verified in code: {r['quotes_verified']}/{r['rows']}")
    for d in r["details"]:
        mark = "OK " if d["value_ok"] else "BAD"
        page = "" if d["page_ok"] is None else (" page ok" if d["page_ok"] else " page wrong")
        got = d["got"] if d["got"] is not None else d.get("got_status", "")
        print(f"{mark} {d['field_path']} {d['element_key']}: {got} "
              f"(p{d.get('page')}, {d['grounding']}){page}")
    if r["extra_rows"]:
        print(f"Unexpected rows: {r['extra_rows']}")
    sys.exit(0 if r["values_correct"] == r["values_total"] else 1)


if __name__ == "__main__":
    main()
