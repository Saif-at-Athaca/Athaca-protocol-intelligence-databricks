# Prod deploy: bind existing Unity Catalog objects

J07 created these under catalog **`pi`** (owner **`pi-poc-engineers`**). Run **once per target** before the first prod deploy so the bundle does not try to create duplicates.

Service principal for deploy: **`pi-poc-deployer`** (configured on the `prod` target in `databricks.yml`).

```bash
export DATABRICKS_HOST="https://dbc-dd9b2c35-13e6.cloud.databricks.com"
# Authenticate as pi-poc-deployer (OAuth) or your admin user with bind rights

databricks bundle deployment bind pi_silver pi.silver -t prod --auto-approve
databricks bundle deployment bind pi_public pi.public -t prod --auto-approve
databricks bundle deployment bind pi_outputs pi.outputs -t prod --auto-approve
databricks bundle deployment bind pi_restricted_test pi.restricted_test -t prod --auto-approve
databricks bundle deployment bind protocols pi.outputs.protocols -t prod --auto-approve
```

`pi.bronze` is bundle-managed unless JJ created it separately; bind with `pi_bronze pi.bronze` if it already exists.

Then:

```bash
databricks bundle deploy -t prod
```
