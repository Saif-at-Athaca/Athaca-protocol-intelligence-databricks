"""Ask the model for the four POC fields. Ported from PI's extract chain (prompts.py, chains.py)."""

from langchain_core.output_parsers import PydanticOutputParser
from langchain_core.prompts import ChatPromptTemplate

from pi_extraction.config import ExtractionConfig
from pi_extraction.schema import ProtocolExtraction

SYSTEM = """You are a clinical protocol parser. Extract four design fields from the protocol text.
Output only what the text states.

CRITICAL GROUNDING: For every field give the page, the section heading and a short quote copied
exactly from that page (under 40 words, no ellipses, no paraphrase). Never invent content. If the
protocol does not state a field, set status to "missing" and leave value, page and quote empty.

Page numbers: use the FILE page number from the "--- Page N ---" markers, counting from 1 at the
first page of the PDF, NOT the printed page number in the footer. Prefer the main body section
over the synopsis when both state the value.

Fields:
- enrollment: total planned number of subjects across all arms. Not the per-arm number and not
  the sample-size calculation if a different planned total is stated. raw_text as written.
- blinding: masking as one of NONE (open label), SINGLE, DOUBLE, TRIPLE, QUADRUPLE, from the
  protocol's own wording (e.g. "double-blind" = DOUBLE). raw_text is the wording used.
- primary_endpoints: each PRIMARY endpoint. A composite endpoint (e.g. "time to all-cause
  mortality OR cardiac hospitalization") is ONE endpoint with is_composite true and its parts in
  components, even if the word "composite" is not used. Key secondary endpoints are not primary.
- min_age_years / max_age_years: age limits from the inclusion criteria, in years. If there is
  no upper limit, max_age_years has status "not_applicable" with no value. An exclusion that
  applies only to some older subjects is not an age limit."""

HUMAN = "{format_instructions}\n\nProtocol text:\n\n{protocol_text}"

# The serving endpoint rejects structured output for newer Anthropic models (it needs forced tool
# use), so the model returns JSON as text and the parser validates it against the schema.
parser = PydanticOutputParser(pydantic_object=ProtocolExtraction)
prompt = ChatPromptTemplate.from_messages([("system", SYSTEM), ("human", HUMAN)]).partial(
    format_instructions=parser.get_format_instructions()
)


def make_llm(config: ExtractionConfig):
    from databricks_langchain import ChatDatabricks

    return ChatDatabricks(
        endpoint=config.endpoint,
        max_tokens=config.max_tokens,
        timeout=config.timeout_seconds,
    )


def extract_protocol(protocol_text: str, llm) -> ProtocolExtraction:
    """protocol_text: `get_full_text_for_chain` output (section index + page-marked text)."""
    chain = prompt | llm | parser
    return chain.invoke({"protocol_text": protocol_text})
