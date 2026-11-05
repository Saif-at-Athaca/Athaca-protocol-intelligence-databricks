"""Score protocol_field rows against the hand-checked expected values (A04)."""

import re


def _norm(value) -> str:
    if value is None:
        return ""
    if isinstance(value, float) and value.is_integer():
        value = int(value)
    text = re.sub(r"[^a-z0-9]+", " ", str(value).lower()).strip()
    return text


def _row_value(row) -> str:
    if row["value_number"] is not None:
        return _norm(row["value_number"])
    return _norm(row["value_text"])


def score_rows(rows: list[dict], expected: list[dict]) -> dict:
    by_key = {(r["field_path"], r["element_key"] or ""): r for r in rows}
    details = []
    for e in expected:
        key = (e["field_path"], e["element_key"] or "")
        row = by_key.get(key)
        want_pages = {int(p) for p in (e.get("pdf_pages") or "").split("|") if p}
        if row is None:
            details.append({"field_path": key[0], "element_key": key[1], "value_ok": False,
                            "page_ok": None, "got": "(no row)", "grounding": None})
            continue
        status_ok = row["value_status"] == e["value_status"]
        value_ok = status_ok and _row_value(row) == _norm(e["expected_value"])
        page_ok = row["page_number"] in want_pages if want_pages else None
        details.append({
            "field_path": key[0], "element_key": key[1], "value_ok": value_ok, "page_ok": page_ok,
            "got": row["value_number"] if row["value_number"] is not None else row["value_text"],
            "got_status": row["value_status"], "page": row["page_number"],
            "grounding": row["grounding_status"],
        })
    expected_keys = {(e["field_path"], e["element_key"] or "") for e in expected}
    extra = [k for k in by_key if k not in expected_keys]
    checked = [d for d in details if d["page_ok"] is not None]
    return {
        "values_correct": sum(d["value_ok"] for d in details),
        "values_total": len(details),
        "pages_correct": sum(bool(d["page_ok"]) for d in checked),
        "pages_checked": len(checked),
        "quotes_verified": sum(r["grounding_status"] == "verified" for r in rows),
        "rows": len(rows),
        "extra_rows": extra,
        "details": details,
    }
