# erp-hashdiff-sync

Nightly replication from a vendor ERP that emits no tombstones, has unreliable modified dates, and sits behind a driver with a hard query timeout and a query-text limit. Written in T-SQL on SQL Server, over a linked server, and proven against a generated stand-in ERP.

Work in progress. Proofs so far:

- [Infrastructure](proofs/00-infrastructure.md): the warehouse reaches the ERP only through a read-only linked server with a hard timeout, and that timeout is silent inside a procedure.
- [Stand-in ERP](proofs/01-stand-in-erp.md): 120 tables and 1.2M rows with undeclared composite keys, quoted key codes, and untrustworthy dates; a hand-kept key manifest; and the single wrapper that enforces the driver's text limit and hard timeout.
- [Nightly correctness](proofs/02-nightly-correctness.md): the first load and seven nights of inserts, updates, untraceable deletes, and re-created keys. After every run, an independent audit compared every row of every table with the ERP: 960 of 960 table audits clean.
- [Old process against new](proofs/03-old-versus-new.md): the old SSIS-style process, run against the same ERP on the same nights. After seven nights it had 9 tables wrong, 48,973 rows missing, and 17,872 duplicated keys, and had raised no errors.

## Run it

Requires Docker (Docker Desktop or OrbStack). About three minutes from nothing to the first two proofs; the nightly proofs take about an hour more.

```sh
./scripts/up.sh            # start both SQL Server instances and install all SQL objects
./scripts/build-erp.sh     # generate the stand-in ERP (seed 7, about a minute)
./scripts/prove-infra.sh   # regenerate proofs/00-infrastructure.md
./scripts/prove-erp.sh     # regenerate proofs/01-stand-in-erp.md
./scripts/sync.sh          # run one sync of every manifest table
./scripts/prove-nightly.sh 7  # rebuild the ERP; first load and 7 nights, new and old process, audit both (about an hour)
docker compose down        # stop and remove the instances
```
