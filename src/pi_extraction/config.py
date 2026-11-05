"""Extraction settings. The model endpoint comes from config, never from code (J03, AC7)."""

import os
from dataclasses import dataclass

PROMPT_VERSION = "a03.2026-11-05"


@dataclass(frozen=True)
class ExtractionConfig:
    endpoint: str = os.environ.get("PI_EXTRACTION_ENDPOINT", "databricks-claude-sonnet-5-5")
    # Long protocols (VITAL is 137 pages) need the long timeout and output budget PI used.
    max_tokens: int = 16384
    timeout_seconds: int = 600
    prompt_version: str = PROMPT_VERSION
