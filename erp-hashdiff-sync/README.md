# erp-hashdiff-sync

Nightly replication of a vendor ERP that emits no tombstones, has untrustworthy modified dates, declares none of its keys, and sits behind a proprietary driver with a hard query timeout and a query-text limit. Written in T-SQL, run over a real SQL Server linked server, and proven against a generated stand-in ERP.

This is a clean-room reconstruction of a system I designed and ran in production: roughly 700 tables and 2 billion rows, reconciled every night. The client's code and data cannot be shared, so this repository rebuilds the problem from its constraints, reimplements the solution from scratch, and commits the evidence that it works.

## Results

| | Old process | This process |
|---|---|---|
| Tables correct after 7 nights | 111 of 120 | **120 of 120, every night** ([proof](proofs/02-nightly-correctness.md)) |
| Rows missing, duplicated, stale, or deleted but still present | 71,362, growing every night | **0** ([proof](proofs/03-old-versus-new.md)) |
| Errors raised about any of it | 0 | — |
| Deletes detected, with no tombstones | none | every one |
| Rows fetched per night | about 560,000: most tables reloaded in full | about 1,900: only what changed, after comparing all 1.2M keys |
| Minutes per night, at this scale | about 0.7 | about 0.6 |
| A table that fails mid-run | — | left untouched, caught up the next night ([proof](proofs/04-failure-and-recovery.md)) |

The old process failed silently. That is the problem this design solves: not speed, but a copy of the ERP that can be trusted without checking it.

## The problem

The ERP was reachable only through a SQL Server linked server, backed by the vendor's proprietary driver:

- **A 15-minute hard timeout** on every query, with no exceptions.
- **A limit on query-text length**, which capped how much could be said in one statement.
- **Read-only access.** Nothing could be created on the vendor's side: no staging tables, no temp tables, no views.
- **No tombstones.** A deleted row simply disappears.
- **Create and modify dates that cannot be trusted:** sometimes missing, sometimes not updated when a row changes.
- **Undeclared keys.** The catalog marks no primary keys. The real keys are composite (an int, usually codes, sometimes a date) and had to be read from the vendor's data dictionary.

The inherited process was two SSIS packages. One fully reloaded the tables small enough to reload: correct, but most of a 9-hour window. The other ran incremental upserts on the large tables, filtered by those unreliable dates and keyed on the wrong columns, because whoever built it had not understood the composite keys. The result was missed changes, collapsed and duplicated rows, and deletes that were never seen, with no errors anywhere.

## The design

One path for every table, every night, including the first load. Each table runs as its own procedure, [`sync.usp_sync_table`](sql/warehouse/30_sync_process.sql#L173), started in parallel by a thin runner that stands in for the original SSIS package.

1. **Pull every key and a hash of its whole row, in one query.** The hash is computed on the ERP's side, so only keys and 32-character hashes cross the wire. At 500 million rows, this pull still finished inside the timeout. ([step 1](sql/warehouse/30_sync_process.sql#L291))
2. **Guard against a short pull.** If the pulled key count falls more than a small allowance below the replica's active rows, stop before comparing anything. ([step 2](sql/warehouse/30_sync_process.sql#L297))
3. **Compare against the replica.** New: the key is not in the replica. Changed: the hash differs, or a deleted key has come back. Deleted: active in the replica, missing from the pull. ([step 3](sql/warehouse/30_sync_process.sql#L308))
4. **Prune to a request list** of new and changed keys only.
5. **Send the keys back to the ERP inside the query text.** Nothing can be created on the vendor's side, so the only place to put a list of keys is the statement itself: a `VALUES` list of escaped literal tuples, joined on every key column. Batch sizes come from arithmetic on the statement: its fixed text, mostly the select list, plus each key's literal must fit the text limit, with at most 5,000 rows per batch. ([step 5](sql/warehouse/30_sync_process.sql#L327))
6. **Stage everything, then apply it in one transaction:** flag the deletes, remove the changed rows, insert the fetched ones. ([step 6](sql/warehouse/30_sync_process.sql#L396))
7. **Reconcile every count before committing.** The replica must end up holding exactly the keys that were pulled, or the transaction rolls back. ([step 7](sql/warehouse/30_sync_process.sql#L409))

### Why each piece is there

- **One hash query, not a filtered pull.** The dates cannot be trusted, so nothing short of comparing every row finds every change, and comparing hashes makes that cheap. Pulling every key is also the only way to see a delete when the source leaves no trace of one.
- **Cast by type before hashing.** Default conversions round money to two decimals, float to six significant digits, and datetime to the minute. Each type gets an explicit style that keeps full precision: [`sync.fn_hash_piece`](sql/warehouse/30_sync_process.sql#L124).
- **NULL becomes a character no text contains**, so NULL and an empty string hash differently.
- **`varchar(max)` from the first character.** Without it, SQL Server silently truncates the concatenation at 8,000 characters, or at 4,000 once an `nvarchar` column joins in, and changes past that point go unseen. I hit this bug in the original, and this rebuild hit it again independently.
- **The ERP's hash is stored on each replica row**, and the next night compares against it. The warehouse never reproduces the ERP's casting, so a local hash can never disagree with the source's.
- **Keys go back as literals because there is no other way in.** Every quote in a key code is doubled; one unescaped quote breaks the batch.
- **Delete then insert, rather than update.** Simpler dynamic SQL across hundreds of different table shapes, and a table's whole change lands at once.
- **Nothing is applied until everything is staged.** A table that fails is left exactly as it was, and the next run picks up what it missed. Retries are nested: three per batch inside the procedure, three per table in the runner.
- **The variance guard** exists because a short pull looks exactly like mass deletion. Without it, a partial restore on the vendor's side would soft-delete thousands of rows.
- **One alert email per bad run.** The original SSIS package ran a Send Mail task on failure. Here the runner calls [`sync.usp_alert_run`](sql/warehouse/60_alerts.sql), which sends one email through Database Mail if any table ended the run failed, and calls out a variance-guard stop separately, because that needs a person to look before the next run. A table that failed once and then succeeded is not an alert.
- **Keys come from a manifest**, not the catalog, because the catalog declares none. Replicating another table means adding one row to it.

## Proofs

Every proof is generated by a script and committed. None is edited by hand.

| Proof | Shows |
|---|---|
| [00 Infrastructure](proofs/00-infrastructure.md) | The warehouse reaches the ERP only through a read-only linked server with a hard timeout. Also a finding: through Microsoft's provider, that timeout is silent inside a procedure. |
| [01 Stand-in ERP](proofs/01-stand-in-erp.md) | 120 tables and 1.2M rows with undeclared composite keys, 100,000 keys containing quotes, untrustworthy dates, 14 data types, and tables over 300 columns wide. |
| [02 Nightly correctness](proofs/02-nightly-correctness.md) | The first load and 7 nights of inserts, updates, untraceable deletes, and re-created keys, with an independent audit after every run: 960 of 960 table audits clean. |
| [03 Old against new](proofs/03-old-versus-new.md) | The old SSIS-style process on the same nights: silent drift in every incremental table, growing every night. |
| [04 Failure and recovery](proofs/04-failure-and-recovery.md) | Injected timeouts, a table failing for a whole night, a short pull stopped by the guard, a full wipe and reload, and the alert emails those runs sent. |
| [05 Hashing edge cases](proofs/05-hashing-edge-cases.md) | Six one-row changes an obvious first-draft hash misses, all caught. |

**The audit is independent of the sync.** It reads the ERP through its own linked server, with no timeout and no text limit, and fingerprints rows with SQL Server's JSON rendering and SHA-256 instead of the sync's cast-by-type MD5. A bug in the sync's hashing cannot hide from it: [`audit.usp_audit_table`](sql/warehouse/40_audit.sql#L34).

## What is real and what is simulated

- **Real:** SQL Server 2022, a linked server, `EXEC ... AT`, a read-only login that rejects any DDL or write, and a query timeout enforced by the provider.
- **Simulated, and the only simulated constraint: the text limit.** SQL Server does not cap statement length the way the vendor driver did, so the single door to the ERP, [`sync.erp_exec_at`](sql/warehouse/10_sync_objects.sql#L95), rejects statements over 15,000 characters. The original limit was about 10,000; the stand-in's widest table needs about 12,700 characters for its single hash statement.
- **Restored: the timeout error.** Microsoft's provider reports a timeout as an informational message and returns no rows, with no error to catch ([proof 00](proofs/00-infrastructure.md)). The vendor driver raised a hard error, so the wrapper does too.
- **Scaled down:** 1.2 million rows instead of 2 billion, and a 30-second timeout instead of 15 minutes. The slowest statement uses about a third of the timeout.
- **Replaced:** SSIS only started one procedure per table, retried failures, and sent the failure email. A shell script starts and retries here, and the email is T-SQL; all the work is in the T-SQL.
- **Caught, not delivered:** alert emails go out through real Database Mail to Mailpit, a local mail server that keeps every message and delivers none.
- **The stand-in ERP** is generated in T-SQL from a seed, in a database the warehouse cannot see, and simulates nightly business activity: inserts, updates, deletes, re-created keys, and updates that leave the modified date alone.

## What I would change

- **Encode lengths instead of delimiting.** The original put a single pipe between fields; this rebuild uses `$|$`, which a value would have to contain to cause a collision. Prefixing each value with its length removes the possibility entirely.
- **Keep history for re-created keys.** A key that is deleted and later re-created replaces its old row. That was right for this use, but a consumer that needs to see the deletion would want both versions kept.
- **Guard growth as well as shrinkage.** The variance guard catches a short pull. A sudden large growth is rarer, but worth a look before loading.
- **Learn the thresholds.** Batch sizes and the variance allowance are set by hand. Each table's history of pull sizes and batch timings could set them instead.

## About this rebuild

The original was written in T-SQL on SQL Server and orchestrated by SSIS; its code stayed with the client. This version was written from my account of that design, with Claude Code, and checked against the stand-in by the proofs above. Two details are recalled rather than recorded: the exact text limit, and the variance guard's implementation, which is reconstructed from its behavior.

## Run it

Requires Docker (Docker Desktop or OrbStack). About three minutes to the first two proofs; the rest take about an hour and a half.

```sh
./scripts/up.sh                # start both SQL Server instances and Mailpit, and install all SQL objects
./scripts/build-erp.sh         # generate the stand-in ERP (seed 7, about a minute)
./scripts/prove-infra.sh       # proofs/00
./scripts/prove-erp.sh         # proofs/01
./scripts/sync.sh              # one sync of every manifest table
./scripts/prove-nightly.sh 7   # proofs/02 and 03: first load and 7 nights, new and old process (about an hour)
./scripts/prove-resilience.sh  # proofs/04 and 05: failures, recovery, edge cases (about 20 minutes)
docker compose down            # stop and remove everything
```

Alert emails land in Mailpit's inbox at http://127.0.0.1:18025.

## Layout

```
sql/erp/          the stand-in ERP: login, generator, nightly activity, test scenarios
sql/warehouse/    linked servers, the driver wrapper, the manifest, the sync, the audit, the old process, alerts
sql/proofs/       the queries that write the proofs
scripts/          start, build, run, and prove
proofs/           committed output
```
