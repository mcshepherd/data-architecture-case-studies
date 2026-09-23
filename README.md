# Data architecture case studies

Reconstructions of production data architecture work, each proven against a generated stand-in system. Client systems and code cannot be shared, so each case study rebuilds the problem from its constraints, reimplements the solution from scratch, and commits the evidence that it works.

| Case study | Problem | Stack | Status |
|---|---|---|---|
| [erp-hashdiff-sync](erp-hashdiff-sync/) | Nightly replication from a vendor ERP with no tombstones, unreliable modified dates, a hard query timeout, and a query-text limit | T-SQL, SQL Server, linked server | In progress |
| Second case study | Agent-built analytics platform on a vendor insurance schema | dbt, Python | Planned |

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
