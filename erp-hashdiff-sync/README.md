# erp-hashdiff-sync

Nightly replication from a vendor ERP that emits no tombstones, has unreliable modified dates, and sits behind a driver with a hard query timeout and a query-text limit. Written in T-SQL on SQL Server, over a linked server, and proven against a generated stand-in ERP.

Work in progress. Proofs so far:

- [Infrastructure](proofs/00-infrastructure.md): the warehouse reaches the ERP only through a read-only linked server with a hard timeout, and that timeout is silent inside a procedure.

## Run it

Requires Docker (Docker Desktop or OrbStack).

```sh
./scripts/up.sh            # start both SQL Server instances, create the linked server
./scripts/prove-infra.sh   # regenerate proofs/00-infrastructure.md
docker compose down        # stop and remove the instances
```
