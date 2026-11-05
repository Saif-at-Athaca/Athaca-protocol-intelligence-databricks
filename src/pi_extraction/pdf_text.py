"""Section-aware PDF text. Ported from PI `backend/app/pdf_parser.py` (reuse map #1, Reuse).

Kept as in PI: PyMuPDF text per page, `--- Page N ---` markers (file page from 1, not the
printed footer), the regex section index, and `get_full_text_for_chain`. Not ported: the
pdfplumber SOA tables and the vision fallback (A03 doesn't use the schedule of assessments).
The page loop is split out as `sections_from_page_texts` so it can be tested without a PDF.
"""

from __future__ import annotations

import re
from pathlib import Path
from typing import Any

import pymupdf

# Section headers to detect (case-insensitive, allow minor variations)
SECTION_PATTERNS = [
    (r"(?i)\b(synopsis|protocol\s+summary)\b", "synopsis"),
    (r"(?i)\b(inclusion\s+criteria|eligibility\s*[:\s]*inclusion)\b", "inclusion_criteria"),
    (r"(?i)\b(exclusion\s+criteria|eligibility\s*[:\s]*exclusion)\b", "exclusion_criteria"),
    (
        r"(?i)\b("
        r"schedule\s+of\s+assessments"
        r"|schedule\s+of\s+activities"
        r"|schedule\s+of\s+evaluations"
        r"|schedule\s+of\s+events"
        r"|schedule\s+of\s+procedures"
        r"|schedule\s+of\s+study\s+(?:procedures|activities|assessments|visits|evaluations)"
        r"|time\s+and\s+events?\s+(?:table|schedule)"
        r"|study\s+(?:procedures?|activities|assessments?)\s+(?:schedule|table|flow\s*chart)"
        r"|table\s+of\s+(?:study\s+)?(?:procedures|activities|events|assessments)"
        r"|(?:study\s+)?visit\s+schedule"
        r"|assessment\s+schedule"
        r"|SOA"
        r")\b",
        "schedule_of_assessments",
    ),
    (r"(?i)\b(primary\s+endpoint|primary\s+outcome|endpoints?)\b", "endpoints"),
    (r"(?i)\b(statistical\s+considerations|statistics?)\b", "statistical_considerations"),
    (r"(?i)\b(background|introduction)\b", "background"),
]

# Compile once
SECTION_REGEXES = [(re.compile(pat), name) for pat, name in SECTION_PATTERNS]


def extract_sections(pdf_bytes: bytes) -> dict[str, dict[str, Any]]:
    """
    Extract full text per page and identify sections. Returns a dict:
    section_name -> {"text": str, "start_page": int (1-based), "end_page": int}.
    Page numbers are 1-based for citation grounding.
    """
    doc = pymupdf.open(stream=pdf_bytes, filetype="pdf")
    try:
        return sections_from_page_texts([doc[i].get_text() for i in range(len(doc))])
    finally:
        doc.close()


def sections_from_page_texts(full_text_by_page: list[str]) -> dict[str, dict[str, Any]]:
    # Build one concatenated text with page markers for section detection
    combined = ""
    for i, t in enumerate(full_text_by_page):
        combined += f"\n\n--- PAGE {i + 1} ---\n\n{t}"

    # Collect all section header positions
    header_positions: list[tuple[int, str]] = []
    for regex, name in SECTION_REGEXES:
        for m in regex.finditer(combined):
            header_positions.append((m.start(), name))
    header_positions.sort(key=lambda x: x[0])

    sections: dict[str, dict[str, Any]] = {}
    for idx, (pos, name) in enumerate(header_positions):
        if name in sections:
            continue
        # Resolve start page
        chunk_before = combined[:pos]
        page_matches = list(re.finditer(r"--- PAGE (\d+) ---", chunk_before))
        start_page = int(page_matches[-1].group(1)) if page_matches else 1
        # End = start of next section header, or end of document
        if idx + 1 < len(header_positions):
            end_pos = header_positions[idx + 1][0]
        else:
            end_pos = len(combined)
        section_text = combined[pos:end_pos].strip()
        end_page_matches = list(re.finditer(r"--- PAGE (\d+) ---", section_text))
        end_page = int(end_page_matches[-1].group(1)) if end_page_matches else start_page
        sections[name] = {"text": section_text, "start_page": start_page, "end_page": end_page}

    # Add full text key for downstream (all pages)
    full_text = "\n\n".join(
        f"--- Page {i + 1} ---\n{t}" for i, t in enumerate(full_text_by_page)
    )
    n_pages = len(full_text_by_page)
    sections["_full_text"] = {"text": full_text, "start_page": 1, "end_page": n_pages}
    sections["_page_count"] = n_pages
    return sections


def get_full_text_for_chain(sections: dict[str, dict[str, Any]]) -> str:
    """
    Build the text blob for the Extract chain.

    Always returns the full document text (with page markers) so Claude sees the
    entire protocol. Prepends a section index so Claude knows where key sections are.
    """
    full = (sections.get("_full_text") or {}).get("text", "")

    # Build a section index header so Claude knows where to look
    named = {k: v for k, v in sections.items() if not k.startswith("_")}
    if named:
        index_lines = ["[SECTION INDEX]"]
        for name, data in named.items():
            start = data.get("start_page", "?")
            end = data.get("end_page", start)
            index_lines.append(f"  {name}: pages {start}-{end}")
        index_lines.append("")
        return "\n".join(index_lines) + "\n" + full

    return full


def read_pdf_sections(path: str | Path) -> dict[str, dict[str, Any]]:
    return extract_sections(Path(path).read_bytes())
