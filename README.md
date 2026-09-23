# Data architecture case studies

Reconstructions of production data architecture work, each proven against a generated stand-in system. Client systems and code cannot be shared, so each case study rebuilds the problem from its constraints, reimplements the solution from scratch, and commits the evidence that it works.

| Case study | Problem | Stack | Status |
|---|---|---|---|
| [erp-hashdiff-sync](erp-hashdiff-sync/) | Nightly replication from a vendor ERP with no tombstones, unreliable modified dates, undeclared composite keys, a hard query timeout, and a query-text limit | T-SQL, SQL Server, linked server | Complete |
| Second case study | Agent-built analytics platform on a vendor insurance schema | dbt, Python | Planned |

## Claims and their evidence

| Claim | Where it is shown |
|---|---|
| Replaced a nightly ERP sync that failed silently with one that reconciles every table, every night | [Old against new](erp-hashdiff-sync/proofs/03-old-versus-new.md): the old process drifts in every incremental table with no errors; the new one is exact every night |
| Compares every row every night by key and row hash, and transfers only what changed | [Nightly correctness](erp-hashdiff-sync/proofs/02-nightly-correctness.md): all 1.2M keys compared nightly, about 1,900 rows fetched |
| Detects deletes although the ERP emits no tombstones | [Nightly correctness](erp-hashdiff-sync/proofs/02-nightly-correctness.md): every delete flagged, audited against the ERP |
| No missing or duplicate data, by construction | [Nightly correctness](erp-hashdiff-sync/proofs/02-nightly-correctness.md): 960 of 960 independent table audits clean; [the reconciliation step](erp-hashdiff-sync/sql/warehouse/30_sync_process.sql#L409) rolls back any table whose counts disagree |
| Works within the driver's query-length limit and hard timeout, with batched dynamic SQL generated per table from metadata | [Stand-in ERP](erp-hashdiff-sync/proofs/01-stand-in-erp.md) for the limits; [the batching step](erp-hashdiff-sync/sql/warehouse/30_sync_process.sql#L327) for the arithmetic |
| Handles tables over 250 columns | [Nightly correctness](erp-hashdiff-sync/proofs/02-nightly-correctness.md): tables up to 318 columns, with fewer keys per batch |
| Each row carries its load time and a delete flag; each run logs per-table counts and runtimes | [The replica tables and run log](erp-hashdiff-sync/sql/warehouse/30_sync_process.sql) |
| Ran unattended: failures retry, and a failed table leaves no partial data | [Failure and recovery](erp-hashdiff-sync/proofs/04-failure-and-recovery.md) |

## Layout

Each case study is a self-contained folder with its own README, infrastructure, and proofs. Nothing is shared between them, so either can be read, run, or removed on its own.

```
<case-study>/
  README.md    the problem, the design decisions, and links to proofs
  proofs/      committed output: the evidence, readable without running anything
  scripts/     start the environment and regenerate proofs
  ...          implementation (sql/, models/, and so on)
```

Proofs are generated, never hand-edited. Readers who do not run anything can still read the implementation and its proofs.
