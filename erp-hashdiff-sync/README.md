# erp-hashdiff-sync

Nightly replication from a vendor ERP that emits no tombstones, has unreliable modified dates, and sits behind a driver with a hard query timeout and a query-text limit. Written in T-SQL on SQL Server, over a linked server, and proven against a generated stand-in ERP.

Work in progress. Proofs so far:

- [Infrastructure](proofs/00-infrastructure.md): the warehouse reaches the ERP only through a read-only linked server with a hard timeout, and that timeout is silent inside a procedure.
- [Stand-in ERP](proofs/01-stand-in-erp.md): 120 tables and 1.2M rows with undeclared composite keys, quoted key codes, and untrustworthy dates; a hand-kept key manifest; and the single wrapper that enforces the driver's text limit and hard timeout.

## Run it

Requires Docker (Docker Desktop or OrbStack). About three minutes from nothing to both proofs.

```sh
./scripts/up.sh            # start both SQL Server instances and install all SQL objects
./scripts/build-erp.sh     # generate the stand-in ERP (seed 7, about a minute)
./scripts/prove-infra.sh   # regenerate proofs/00-infrastructure.md
./scripts/prove-erp.sh     # regenerate proofs/01-stand-in-erp.md
docker compose down        # stop and remove the instances
```
