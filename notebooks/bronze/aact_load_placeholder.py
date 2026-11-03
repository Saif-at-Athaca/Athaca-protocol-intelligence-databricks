# Databricks notebook source
# MAGIC %md
# MAGIC # AACT → `pi.bronze` (S03)
# MAGIC
# MAGIC Implement after **J07** (catalog grants) and **S02** (snapshot on disk or Volume).
# MAGIC
# MAGIC Reference manifest: `docs/data/aact-snapshot.md`

# COMMAND ----------

dbutils.widgets.text("snapshot_manifest", "docs/data/aact-snapshot.md")

# COMMAND ----------

manifest = dbutils.widgets.get("snapshot_manifest")
print(f"Placeholder — load AACT using manifest: {manifest}")
