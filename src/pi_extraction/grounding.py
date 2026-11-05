"""Quote check against the PDF text. Ported from PI `backend/app/grounding.py` (reuse map #11).

Kept as in PI: rapidfuzz partial_ratio at 80 %, several snippet lengths, the best page found
from the `--- Page N ---` blocks, and the status rules (verified within 2 pages of the cited
page, partially_verified further away or with no page, unverified when not found).
Extended for the four POC fields (A03): quotes can be short (an age criterion is ~15
characters), whitespace is collapsed because PDF lines break mid-sentence, and when the quote
appears on several pages (synopsis, body, amendment summary) the page nearest the cited one wins
the tie (PI took the first). Not ported: the
eligibility-flag `validate` wrapper and its disclaimer, which depend on PI's schemas.
Added: rule-based confidence from the check (the model's own confidence is not used).
"""

from __future__ import annotations

import re

from rapidfuzz import fuzz

MATCH_THRESHOLD = 80  # percent; criterion text must match PDF at least this much
PAGE_TOLERANCE = 2
MIN_SNIPPET = 8  # PI used 20 for eligibility criteria

_CRITERION_PREFIX = re.compile(
    r"^(?:INCLUSION|EXCLUSION)\s*:\s*\d+\.?\s*", re.IGNORECASE,
)
_PAGE_BLOCK = re.compile(r"--- Page (\d+) ---", re.IGNORECASE)


def _ws(text: str) -> str:
    return re.sub(r"\s+", " ", text)


def _extract_match_snippets(criterion: str) -> list[str]:
    """Extract multiple search snippets from a criterion for more robust matching.

    Strips leading "INCLUSION: N." or "EXCLUSION: N." prefixes so the fuzzy
    matcher focuses on the actual criterion text from the PDF.
    """
    c = _CRITERION_PREFIX.sub("", _ws(criterion).strip())
    if not c:
        return []
    snippets = [c[:300]]
    if len(c) > 300:
        snippets.append(c[:150])
    if len(c) > 80:
        snippets.append(c[: c.index(" ", 60) if " " in c[60:120] else 80])
    return [s for s in snippets if len(s) >= MIN_SNIPPET]


def _find_criterion_in_text(
    criterion: str, pdf_text: str, prefer_page: int | None = None
) -> tuple[bool, int | None]:
    """
    Fuzzy match criterion snippet against pdf_text. Return (found, best_page).
    Uses multiple snippet lengths for robustness with long criteria.
    Page inferred from "--- Page N ---" blocks in pdf_text.
    """
    if not criterion or not criterion.strip() or not pdf_text:
        return False, None
    snippets = _extract_match_snippets(criterion)
    if not snippets:
        return False, None
    pdf_lower = _ws(pdf_text[:600000]).lower()
    found = False
    for snippet in snippets:
        ratio = fuzz.partial_ratio(snippet.lower(), pdf_lower)
        if ratio >= MATCH_THRESHOLD:
            found = True
            break
    if not found:
        return False, None
    blocks = list(_PAGE_BLOCK.finditer(pdf_text))
    if not blocks:
        return True, None
    best_page: int | None = None
    best_ratio = 0.0
    search_snippet = snippets[0].lower()
    for i, m in enumerate(blocks):
        start = m.end()
        end = blocks[i + 1].start() if i + 1 < len(blocks) else len(pdf_text)
        chunk = _ws(pdf_text[start:end][:8000]).lower()
        r = fuzz.partial_ratio(search_snippet, chunk)
        page = int(m.group(1))
        nearer = (
            prefer_page is not None and best_page is not None
            and abs(page - prefer_page) < abs(best_page - prefer_page)
        )
        if r > best_ratio or (r == best_ratio and nearer):
            best_ratio = r
            best_page = page
    return True, best_page


def check_quote(quote: str | None, pdf_text: str, cited_page: int | None):
    """Return (grounding_status, page), using PI's status rules."""
    found, page = _find_criterion_in_text(quote or "", pdf_text, prefer_page=cited_page)
    if not found:
        return "unverified", cited_page
    if page is None:
        return "partially_verified", cited_page
    if cited_page is not None and abs(cited_page - page) > PAGE_TOLERANCE:
        return "partially_verified", page
    return "verified", page


def confidence_for(grounding_status: str, page_moved: bool) -> float:
    levels = {"verified": 0.9, "partially_verified": 0.6, "unverified": 0.2}
    base = levels.get(grounding_status, 0.5)
    return round(base - 0.15, 2) if page_moved and grounding_status != "unverified" else base
