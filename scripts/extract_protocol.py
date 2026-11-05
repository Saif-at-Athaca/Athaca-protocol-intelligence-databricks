"""Run the A03 extraction locally and write protocol_field rows to CSV.

Example:
    DATABRICKS_CONFIG_PROFILE=pi-poc python scripts/extract_protocol.py \\
        --pdf path/to/Prot_000.pdf --out docs/extraction/vital-sample-output.csv
"""

import argparse
import csv
import json
import sys
import time
import uuid
from dataclasses import replace
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from pi_extraction.config import ExtractionConfig  # noqa: E402
from pi_extraction.extract import extract_protocol, make_llm  # noqa: E402
from pi_extraction.pdf_text import (  # noqa: E402
    get_full_text_for_chain,
    read_pdf_sections,
)
from pi_extraction.rows import to_protocol_field_rows  # noqa: E402


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--pdf", required=True,
                    help="Protocol PDF (PI pdf_parser: PyMuPDF + section index)")
    ap.add_argument("--endpoint", help="Model Serving endpoint (default from config)")
    ap.add_argument("--out", required=True, help="CSV of protocol_field rows")
    ap.add_argument("--protocol-id", default="VITAL")
    ap.add_argument("--nct-id", default="NCT02312206")
    ap.add_argument("--source-doc-id", default="protocol:vital:amendment3")
    ap.add_argument("--mlflow-experiment", help="Log a trace to this Databricks experiment (AC1)")
    args = ap.parse_args()

    config = ExtractionConfig()
    if args.endpoint:
        config = replace(config, endpoint=args.endpoint)
    sections = read_pdf_sections(args.pdf)
    protocol_text = get_full_text_for_chain(sections)
    pdf_text = sections["_full_text"]["text"]

    trace_id = None
    if args.mlflow_experiment:
        import mlflow

        mlflow.set_tracking_uri("databricks")
        mlflow.set_experiment(args.mlflow_experiment)
        mlflow.langchain.autolog()

    start = time.monotonic()
    extraction = extract_protocol(protocol_text, make_llm(config))
    seconds = round(time.monotonic() - start, 1)
    if args.mlflow_experiment:
        trace_id = mlflow.get_last_active_trace_id()

    rows = to_protocol_field_rows(
        extraction, pdf_text,
        protocol_id=args.protocol_id, nct_id=args.nct_id, source_doc_id=args.source_doc_id,
        extraction_method="pdf_text_llm", model_endpoint=config.endpoint,
        prompt_version=config.prompt_version, extraction_run_id=str(uuid.uuid4()),
        mlflow_trace_id=trace_id,
    )
    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    with out.open("w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)
    out.with_suffix(".json").write_text(extraction.model_dump_json(indent=2), encoding="utf-8")
    print(json.dumps({"rows": len(rows), "seconds": seconds, "endpoint": config.endpoint}))


if __name__ == "__main__":
    main()
