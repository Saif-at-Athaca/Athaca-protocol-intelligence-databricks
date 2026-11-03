from pathlib import Path


def test_aact_manifest_template():
    path = Path(__file__).resolve().parents[1] / "docs" / "data" / "aact-snapshot.md"
    text = path.read_text(encoding="utf-8")
    assert "## Recorded snapshot" in text
    assert "AC2" in text
    assert "S03" in text
