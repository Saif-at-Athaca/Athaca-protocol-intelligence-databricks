import pymupdf

from pi_extraction.grounding import check_quote, confidence_for
from pi_extraction.pdf_text import (
    extract_sections,
    get_full_text_for_chain,
    sections_from_page_texts,
)
from pi_extraction.rows import to_protocol_field_rows
from pi_extraction.schema import (
    Blinding,
    NumberField,
    PrimaryEndpoint,
    ProtocolExtraction,
)
from pi_extraction.scoring import score_rows

PAGE_TEXTS = [
    "Title page. A Phase 3, Randomized, Double-Blind, Placebo-Controlled Study",
    "3.3 Number of Sites and Subjects\nUp to 260 subjects will be enrolled in the study.",
    "3.4.1.1 Primary Efficacy Endpoints\n•  Time to all-cause mortality or cardiac\n"
    "   hospitalization as adjudicated by the CEC",
    "4.1 Inclusion Criteria\n1.  Aged ≥ 18 years",
    "Filler page one.",
    "Filler page two.",
    "Appendix. Up to 260 subjects will be enrolled in the study.",
]
PAGES = sections_from_page_texts(PAGE_TEXTS)["_full_text"]["text"]
ENDPOINT = "Time to all-cause mortality or cardiac hospitalization as adjudicated by the CEC"


def _extraction(**overrides):
    fields = dict(
        enrollment=NumberField(value=260, raw_text="Up to 260 subjects", status="reported", page=2,
                               section="3.3 Number of Sites and Subjects",
                               quote="Up to 260 subjects will be enrolled in the study"),
        blinding=Blinding(masking="DOUBLE", raw_text="Double-Blind", status="reported", page=1,
                          section=None, quote="Randomized, Double-Blind, Placebo-Controlled"),
        primary_endpoints=[PrimaryEndpoint(
            measure=ENDPOINT, quote=ENDPOINT,
            is_composite=True, components=["all-cause mortality", "cardiac hospitalization"],
            page=3, section="3.4.1.1 Primary Efficacy Endpoints")],
        min_age_years=NumberField(value=18, raw_text="Aged ≥ 18 years", status="reported", page=4,
                                  section="4.1 Inclusion Criteria", quote="Aged ≥ 18 years"),
        max_age_years=NumberField(value=None, raw_text=None, status="not_applicable", page=None,
                                  section=None, quote=None),
    )
    fields.update(overrides)
    return ProtocolExtraction(**fields)


META = dict(protocol_id="VITAL", nct_id="NCT02312206", source_doc_id="protocol:vital:amendment3",
            extraction_method="pdf_text_llm", model_endpoint="databricks-claude-sonnet-5-5",
            prompt_version="test", extraction_run_id="run-1")


def test_extract_sections_numbers_pages_from_one():
    doc = pymupdf.open()
    for text in ("Protocol synopsis", "4.1 Inclusion Criteria"):
        doc.new_page().insert_text((72, 72), text)
    sections = extract_sections(doc.tobytes())
    assert sections["_page_count"] == 2
    assert sections["inclusion_criteria"]["start_page"] == 2
    text = get_full_text_for_chain(sections)
    assert text.startswith("[SECTION INDEX]")
    assert "inclusion_criteria: pages 2-2" in text
    assert "--- Page 2 ---" in text


def test_quote_found_on_claimed_page_is_verified():
    quote = "Up to 260 subjects will be enrolled"
    assert check_quote(quote, PAGES, cited_page=2) == ("verified", 2)


def test_quote_across_line_breaks_is_verified():
    assert check_quote(ENDPOINT, PAGES, cited_page=3) == ("verified", 3)


def test_quote_on_nearby_page_corrects_the_page():
    assert check_quote("Aged ≥ 18 years", PAGES, cited_page=3) == ("verified", 4)


def test_quote_far_from_cited_page_is_partially_verified():
    # PI rule: found more than 2 pages from the cited page.
    assert check_quote("Aged ≥ 18 years", PAGES, cited_page=7) == ("partially_verified", 4)


def test_quote_on_two_pages_keeps_the_cited_one():
    quote = "Up to 260 subjects will be enrolled in the study"
    assert check_quote(quote, PAGES, cited_page=7) == ("verified", 7)


def test_tied_pages_pick_the_one_nearest_the_cited_page():
    # The model sometimes cites the printed footer page, a couple off the file page.
    quote = "Up to 260 subjects will be enrolled in the study"
    assert check_quote(quote, PAGES, cited_page=6) == ("verified", 7)


def test_invented_quote_is_unverified():
    status, page = check_quote("Up to 999 participants aged 12 or older", PAGES, cited_page=2)
    assert status == "unverified"
    assert page == 2


def test_missing_quote_is_unverified():
    assert check_quote(None, PAGES, cited_page=2) == ("unverified", 2)


def test_confidence_follows_the_check():
    on_page = confidence_for("verified", page_moved=False)
    moved = confidence_for("verified", page_moved=True)
    assert on_page > moved > confidence_for("unverified", page_moved=False)


def test_rows_follow_protocol_field_shape():
    rows = to_protocol_field_rows(_extraction(), PAGES, **META)
    keys = {(r["field_path"], r["element_key"]) for r in rows}
    assert keys == {
        ("design.enrollment", ""), ("design.masking", ""), ("design.is_blinded", ""),
        ("endpoint.type", "PRIMARY:1"), ("endpoint.measure", "PRIMARY:1"),
        ("endpoint.is_composite", "PRIMARY:1"),
        ("endpoint.component", "PRIMARY:1:C1"), ("endpoint.component", "PRIMARY:1:C2"),
        ("population.min_age_years", ""), ("population.max_age_years", ""),
    }
    by_key = {(r["field_path"], r["element_key"]): r for r in rows}
    enrollment = by_key[("design.enrollment", "")]
    assert enrollment["value_number"] == 260
    assert enrollment["grounding_status"] == "verified"
    assert enrollment["reviewer_status"] == "unreviewed"
    assert enrollment["data_tier"] == "public"
    assert by_key[("design.is_blinded", "")]["value_text"] == "true"


def test_value_only_when_reported():
    rows = to_protocol_field_rows(_extraction(), PAGES, **META)
    for r in rows:
        has_value = r["value_text"] is not None or r["value_number"] is not None
        assert has_value == (r["value_status"] == "reported"), r
        if r["value_status"] == "reported":
            assert r["page_number"] is not None, r
    max_age = next(r for r in rows if r["field_path"] == "population.max_age_years")
    assert max_age["grounding_status"] == "not_applicable"


def test_score_counts_values_and_pages():
    expected = [
        {"field_path": "design.enrollment", "element_key": "", "expected_value": "260",
         "value_status": "reported", "pdf_pages": "2|5"},
        {"field_path": "population.max_age_years", "element_key": "", "expected_value": "",
         "value_status": "not_applicable", "pdf_pages": ""},
        {"field_path": "design.masking", "element_key": "", "expected_value": "DOUBLE",
         "value_status": "reported", "pdf_pages": "1"},
    ]
    rows = to_protocol_field_rows(_extraction(), PAGES, **META)
    result = score_rows(rows, expected)
    assert result["values_correct"] == 3
    assert result["pages_correct"] == 2
    assert result["pages_checked"] == 2


def test_score_flags_wrong_and_missing_values():
    wrong = _extraction(enrollment=NumberField(value=236, raw_text="236", status="reported", page=2,
                                               section=None, quote="Up to 260 subjects"))
    rows = [r for r in to_protocol_field_rows(wrong, PAGES, **META)
            if r["field_path"] != "design.masking"]
    expected = [
        {"field_path": "design.enrollment", "element_key": "", "expected_value": "260",
         "value_status": "reported", "pdf_pages": "2"},
        {"field_path": "design.masking", "element_key": "", "expected_value": "DOUBLE",
         "value_status": "reported", "pdf_pages": "1"},
    ]
    result = score_rows(rows, expected)
    assert result["values_correct"] == 0
    assert {d["field_path"] for d in result["details"] if not d["value_ok"]} == {
        "design.enrollment", "design.masking"}
