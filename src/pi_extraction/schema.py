"""What the model returns: the four POC fields, each with its page, section and verbatim quote."""

from typing import Literal

from pydantic import BaseModel, Field

Status = Literal["reported", "not_applicable", "ambiguous", "missing"]


class Evidence(BaseModel):
    page: int | None = Field(None, description="File page number counting from 1, not the footer")
    section: str | None = Field(None, description="Section heading, e.g. '3.3 Number of Sites'")
    quote: str | None = Field(None, description="Exact text copied from that page, under 40 words")


class NumberField(Evidence):
    value: float | None = None
    raw_text: str | None = Field(None, description="The value as written")
    status: Status


class Blinding(Evidence):
    masking: Literal["NONE", "SINGLE", "DOUBLE", "TRIPLE", "QUADRUPLE"] | None = None
    raw_text: str | None = None
    status: Status


class PrimaryEndpoint(Evidence):
    measure: str = Field(description="Endpoint wording as written")
    is_composite: bool
    components: list[str] = Field(default_factory=list, description="Parts of a composite")


class ProtocolExtraction(BaseModel):
    enrollment: NumberField
    blinding: Blinding
    primary_endpoints: list[PrimaryEndpoint]
    min_age_years: NumberField
    max_age_years: NumberField
