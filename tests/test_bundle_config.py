from pathlib import Path

import yaml


def test_databricks_yml_parses():
    root = Path(__file__).resolve().parents[1]
    data = yaml.safe_load((root / "databricks.yml").read_text(encoding="utf-8"))
    assert data["bundle"]["name"] == "protocol-intelligence-databricks"
    assert "dev" in data["targets"]
    assert "prod" in data["targets"]


def test_resource_includes_exist():
    root = Path(__file__).resolve().parents[1]
    for name in ("schemas.yml", "volumes.yml", "jobs.yml"):
        assert (root / "resources" / name).is_file()
