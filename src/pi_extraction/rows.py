"""Turn an extraction into rows in the A02 pi.silver.protocol_field shape."""

from datetime import UTC, datetime

from pi_extraction.grounding import check_quote, confidence_for
from pi_extraction.schema import Evidence, ProtocolExtraction


def _row(field_path, element_key, value, value_type, status, raw, ev: Evidence, pdf_text, meta):
    reported = status == "reported"
    if status == "not_applicable" and not ev.quote:
        grounding, page, confidence = "not_applicable", ev.page, None
    else:
        grounding, page = check_quote(ev.quote, pdf_text, ev.page)
        confidence = confidence_for(grounding, page_moved=page != ev.page)
    return {
        "protocol_id": meta["protocol_id"],
        "nct_id": meta["nct_id"],
        "source_doc_id": meta["source_doc_id"],
        "field_path": field_path,
        "element_key": element_key,
        "value_text": None if not reported or value_type == "number" else str(value),
        "value_number": float(value) if reported and value_type == "number" else None,
        "value_raw": raw,
        "value_type": value_type,
        "value_status": status,
        "page_number": page,
        "section": ev.section,
        "quote": ev.quote,
        "extraction_method": meta["extraction_method"],
        "model_endpoint": meta["model_endpoint"],
        "prompt_version": meta["prompt_version"],
        "confidence": confidence,
        "grounding_status": grounding,
        "reviewer_status": "unreviewed",
        "extraction_run_id": meta["extraction_run_id"],
        "mlflow_trace_id": meta.get("mlflow_trace_id"),
        "data_tier": "public",
        "extracted_at": meta.get("extracted_at") or datetime.now(UTC).isoformat(),
    }


def _number_status(field):
    # The A02 rule: a value is stored exactly when the status is reported.
    if field.status == "reported" and field.value is None:
        return "missing"
    return field.status


def to_protocol_field_rows(x: ProtocolExtraction, pdf_text: str, **meta) -> list[dict]:
    rows = []
    for path, field in (
        ("design.enrollment", x.enrollment),
        ("population.min_age_years", x.min_age_years),
        ("population.max_age_years", x.max_age_years),
    ):
        status = _number_status(field)
        rows.append(_row(path, "", field.value, "number", status, field.raw_text, field, pdf_text,
                         meta))

    b = x.blinding
    status = "missing" if b.status == "reported" and b.masking is None else b.status
    rows.append(_row("design.masking", "", b.masking, "string", status, b.raw_text, b, pdf_text,
                     meta))
    blinded = None if b.masking is None else str(b.masking != "NONE").lower()
    rows.append(_row("design.is_blinded", "", blinded, "boolean", status, b.raw_text, b, pdf_text,
                     meta))

    for i, ep in enumerate(x.primary_endpoints, start=1):
        key = f"PRIMARY:{i}"
        rows.append(_row("endpoint.type", key, "PRIMARY", "string", "reported", None, ep, pdf_text,
                         meta))
        rows.append(_row("endpoint.measure", key, ep.measure, "text", "reported", ep.measure, ep,
                         pdf_text, meta))
        rows.append(_row("endpoint.is_composite", key, str(ep.is_composite).lower(), "boolean",
                         "reported", None, ep, pdf_text, meta))
        for j, part in enumerate(ep.components if ep.is_composite else [], start=1):
            part_ev = Evidence(page=ep.page, section=ep.section, quote=part)
            rows.append(_row("endpoint.component", f"{key}:C{j}", part, "string", "reported", part,
                             part_ev, pdf_text, meta))
    return rows
