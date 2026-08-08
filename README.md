# Unified Quarterly Churn — BigQuery

A production-shaped BigQuery pipeline that produces **one unified quarterly churn view** across
two separate product lines — coupons and cashback — where a person who uses both is counted
**once**. Ships with the full data model, a nine-page Looker Studio report design, and 21
data-quality assertions.

Built on fully synthetic data for a coupon-and-cashback platform (66 users, 2025 Q1–Q4).

---

## The problem this solves

Churn arithmetic is easy. Three things about this domain make it hard, and the model is shaped
around all three:

1. **The same person arrives twice.** Coupon and cashback are separate systems with separate
   user ids. Across 2025, activity arrives under **111 source identities that belong to 66
   people**. Count the identities and the active base is overstated by 68%.
2. **The two channels disagree about time.** Coupon activity is dated by `event_date`, cashback
   by `purchase_date` — and cashback also carries a `status_updated_date` that looks like a date
   column but records *paperwork*, not behaviour. Dating activity by it would migrate purchases
   into whichever quarter the affiliate network got around to approving them.
3. **The newest quarter is always incomplete.** A share of each quarter's cashback is still
   `pending` at quarter close. Exclude it and the latest quarter shows a churn spike that heals
   by itself six weeks later.

---

## What's inside

```
sql/00_dataset_and_raw_tables.sql      dataset, raw contracts, UDFs, quarter spine
sql/01_staging.sql                     type / trim / de-duplicate / classify status
sql/02_unified_events.sql              identity resolution → one activity event stream
sql/03_fct_user_quarter_activity.sql   THE unified user-quarter table
sql/04_mart_churn_transitions.sql      Q1→Q2, Q2→Q3, Q3→Q4 + definition sensitivity
sql/05_mart_q1_cohort.sql              confirmed churn + Q3 reactivation
sql/06_mart_source_and_dq_checks.sql   six-source profiling + 21 DQ assertions
sql/07_pending_maturity_and_asof.sql   pending exposure, maturity curve, as-of restatement
sql/08_trace_single_user.sql           walkthrough: one user, raw → classification
sql/09_summary_export.sql              tidy summary block for the workbook
sql/10_looker_studio_views.sql         reporting views (wide → long, monitoring)

scripts/run_pipeline.ps1               orchestration: create, load, build, verify
scripts/export_workbook_to_csv.py      xlsx → csv, no cleaning (that belongs in SQL)
data/                                  CSV extracts of the three source sheets

docs/data_model.html                   data model: ER, lineage, every column + rationale
docs/looker_studio_report_design.html  9-page report design, wireframes + per-tile specs
```

Both files in `docs/` are self-contained HTML — open them in a browser, no build step.

---

## Quickstart

```bash
gcloud auth login && gcloud config set project <PROJECT_ID>
```

```bash
pwsh ./scripts/run_pipeline.ps1 -ProjectId <PROJECT_ID> -Location EU
```

That creates the dataset, loads the three CSVs, builds every model in order, then prints the
data-quality results and the headline churn numbers.

- `-SkipLoad` rebuilds the models without re-loading the CSVs
- `-Dataset sahseh_churn_dev` builds an isolated copy — the script rewrites the dataset name, so
  the SQL files are never edited for an environment
- `python scripts/export_workbook_to_csv.py` regenerates `data/` if the source workbook changes

---

## How it works

```
raw_identity_map ─────────────┐
raw_coupon_activity ──► stg_coupon_events ────────┐
raw_cashback_transactions ──► stg_cashback_transactions ─┤
                              stg_identity_map ──────────┤
                                                         ▼
                                        int_unified_activity_events
                                                         │
                                                         ▼
                                        fct_user_quarter_activity   ← the deliverable
                                             │ (v_user_quarter_active: adds definition dim)
             ┌───────────────┬───────────────┼───────────────┬──────────────────┐
             ▼               ▼               ▼               ▼                  ▼
   mart_quarterly_    mart_quarter_    mart_q1_cohort_  mart_pending_    dq_check_results
      active_base      transitions       summary          exposure       + source profile
                             │                                │
                             └──► mart_definition_sensitivity ┘ ──► mart_report_summary
```

### The grain is dense, not sparse

`fct_user_quarter_activity` is one row per `unified_user_id × quarter`, materialised over a
**spine** of 66 users × 4 quarters = **264 rows, always**. A person with no Q3 activity still
occupies a Q3 row carrying `is_active = FALSE`.

This is the most consequential choice in the model. Churn is a statement about *absence*, and
absence cannot be aggregated if it is a missing row. On a sparse table, `LEAD()` skips silent
quarters and jumps to the next active one — reporting near-perfect retention for users who
disappeared for six months. Densifying once, at the fact layer, makes every mart above it a
plain `COUNTIF`.

### The churn definition is a dimension, not a fork

| definition | coupon | cashback |
|---|---|---|
| `baseline` | eligible `coupon_copy` | status `approved` **or** `pending` |
| `approved_only` | eligible `coupon_copy` | status `approved` |

`rejected` and `cancelled` never count, under either definition.

The fact table carries `is_active_baseline` and `is_active_approved_only` side by side;
`v_user_quarter_active` unpivots them into a `definition_name` column. So *"what changes if only
approved transactions count"* is a `GROUP BY`, not a second copy of the pipeline that drifts from
the first. Every mart is produced for both definitions in the same query, from the same rows.

### Where each rule lives

| Rule | Implemented in |
|---|---|
| Analysis period 2025Q1–2025Q4 | `dim_quarter` spine + `is_in_analysis_period` (02) |
| Coupon activity dated by `event_date` | `int_unified_activity_events.activity_date` (02) |
| Cashback activity dated by `purchase_date` | same column, same grammar (02) |
| Rejected / cancelled excluded | `counts_as_activity_*` flags (02) |
| De-duplicate repeated event / transaction ids | `QUALIFY ROW_NUMBER() = 1` (01) |
| Identity map resolves source ids to `unified_user_id` | `LEFT JOIN stg_identity_map` (02) |
| Six affiliate sources combined before aggregation | union in staging, profiled in 06 |
| Count each person once | primary key = (person, quarter), enforced by grain |

`status_updated_date` is **never** used to date activity. It is used only for the pending
maturity model in 07; 06 counts how many decisions land in a later quarter than the purchase —
exactly the rows that would migrate between quarters if anyone ever dated activity by it.

---

## Results

Reproduced independently in Python before the SQL was written, so the SQL has something to be
checked against.

**Active base per quarter**

| definition | 2025Q1 | 2025Q2 | 2025Q3 | 2025Q4 |
|---|---|---|---|---|
| baseline | 45 | 37 | 38 | 46 |
| approved_only | 45 | 36 | 37 | 43 |

**Quarter-to-quarter churn (baseline)**

| transition | active base | retained | churned | churn rate |
|---|---|---|---|---|
| Q1→Q2 | 45 | 26 | 19 | **42.22%** |
| Q2→Q3 | 37 | 26 | 11 | **29.73%** |
| Q3→Q4 | 38 | 36 | 2 | **5.26%** |

**Q1 cohort — 45 users**

| metric | baseline | approved_only |
|---|---|---|
| lapsed in Q2 | 19 | 20 |
| confirmed churn (silent in Q2 **and** Q3) | **12** (26.67%) | 12 (26.67%) |
| reactivated in Q3 | **7** | 8 |
| reactivation rate among Q2-lapsed | **36.84%** | 40.00% |

**Effect of counting only approved cashback:** churn rises in every transition (+2.2, +3.6,
+2.8 pp). Five user-quarters flip, each traceable in `mart_definition_disagreements` — `U055`
(Q2), `U054` (Q3), `U053`/`U056`/`U066` (Q4). The effect concentrates in **Q4**, the newest and
least-matured quarter, which is the whole argument against `approved_only`.

---

## Data quality

21 assertions in `dq_check_results`, graded `error` (blocks publication) or `warn` (publish with
a footnote). Three families:

- **Input defects** — duplicates, unmapped ids, unknown status values, impossible date orders
- **Grain integrity** — the fact table is unique and complete; approved-only actives are a strict
  subset of baseline actives
- **Reconciliation identities** — `retained + churned = active_base`,
  `confirmed_churn + reactivated = lapsed_in_q2`, and an independent recount of the active base
  straight from the event stream

The reconciliation checks are the valuable ones: input checks catch bad data, identity checks
catch **bad code**. A refactor that breaks the arithmetic fails here before it reaches anyone's
model.

**Three checks fail by design on this extract** — one duplicate coupon event, one duplicate
transaction (both `warn`, handled correctly by staging), and one unmapped cashback user id
(`error` — `B9999` genuinely needs an identity-map fix). Every excluded row is listed in
`dq_excluded_events`.

---

## Trace one user

`sql/08_trace_single_user.sql` walks any `unified_user_id` from raw rows to final classification.
**U055** is the case to demo:

| quarter | event | baseline | approved_only |
|---|---|---|---|
| Q1 | coupon copy `CE0067` | active | active |
| Q2 | cashback `CB0070`, **pending** | active | **inactive** |
| Q3 | coupon copy `CE0068` | active | active |
| Q4 | cashback `CB0071`, approved | active | active |

Same person, same raw data, one rule changed: under `baseline` U055 is *retained* in Q1→Q2; under
`approved_only` they are *churned* in Q1→Q2 and then counted as a *Q3 reactivation*. Nothing about
their behaviour changed — only an affiliate network's paperwork.

---

## Recommendation

**Use two-quarter confirmed churn on the `baseline` (approved + pending) definition.** Report
single-quarter lapse as a leading indicator, not as churn.

- **Two quarters, because one quarter is not evidence of leaving.** 36.8% of the Q1 users who
  went silent in Q2 were back in Q3. Booking all 19 as churn overstates permanent loss by more
  than a third and pushes LTV down accordingly.
- **Pending must count, because excluding it measures the affiliate networks, not the users.**
  A pending transaction is a purchase that happened. Measured as it looked at quarter close,
  `approved_only` opens Q1 at **43 active users and recovers to 45 within 30 days**, while
  `baseline` reads 45 from day one. That is a systematic downward bias exactly where the
  financial model is most sensitive.
- **Carry the band, not just the point.** `[approved_only, baseline]` is the honest uncertainty
  range while a quarter is immature; `mart_pending_exposure.share_of_active_base_at_risk` sizes it.

### Validating it on real historical data

1. **Hazard curve** — for every historical cohort, measure P(returns | *n* silent quarters).
   Choose *n* where the return probability drops below materiality (<5–10%). If real data shows
   meaningful returns after two silent quarters, the definition moves to three; the pipeline
   change is one line in 05.
2. **Revenue back-test** — compare cohort revenue predicted by the churn curve against realised
   revenue 4–8 quarters out. A definition that is right about people but wrong about money is
   still wrong for a financial model.
3. **Restatement magnitude** — `tvf_user_quarter_activity_as_of` rebuilds each quarter as it
   looked at T+0/+30/+45/+90. Average absolute restatement is the error bar to publish with the
   latest quarter.
4. **Independent reconciliation** — active base against app sessions, marketing MAU and the
   finance payout file. A churn number that disagrees with all three is measuring the pipeline,
   not the users.
5. **Seasonality** — quarterly buckets can turn a reliable annual shopper into a churner. Test on
   a rolling-12-month window, and check Ramadan/Eid and end-of-year promotions before trusting a
   quarter-over-quarter delta.

### Handling the latest quarter while transactions are pending

1. **Fixed reporting lag.** `mart_cashback_approval_maturity` gives, per affiliate source, the
   share of transactions decided within 30/45/60/90 days. Publish at the lag where ≥95% are
   decided — **T+45 on this data** — and label anything earlier *provisional*.
2. **Count pending as activity in the meantime**, so a slow network cannot manufacture churn.
3. **Publish the exposure with the number.** `share_of_active_base_at_risk` is the footnote that
   belongs beside the newest quarter, every time.
4. **Measure restatements instead of arguing about them.** `v_ls_vintage_active_base` re-measures
   every quarter at T+0/+30/+45/+90. Note `CB0094`: purchased 2025-08-10, not approved until
   2025-10-19 — invisible at Q3 close, present six weeks later.

> On this synthetic extract, `mart_churn_vintage_comparison` (the same effect measured on the
> Q2→Q3 *churn rate*) shows **no movement at all** — the late-decided transactions happen to
> belong to users who were not in the Q2 base. The restatement is real but lands on the **active
> base**, which is why `v_ls_vintage_active_base` exists and why the report visualises that
> instead.

---

## Source-level checks on real affiliate data

The six networks are unioned **before** user-quarter aggregation, so one bad feed silently moves
the churn number. `mart_cashback_source_profile` computes per source × quarter: volume, distinct
users, duplicate rate, unmapped-user rate, status mix, approval rate, decision latency (p50/max)
and QoQ volume change. On real data the checks that matter:

- **Feed continuity** — a network that quietly stops delivering is indistinguishable from a wave
  of churn. Alert on deviation from the source's own trailing baseline.
- **Status vocabulary drift** — each network has its own words (`validated`, `paid`, `declined`).
  An unmapped value must fail loudly, never default to "not activity".
- **Identity coverage** — unmapped `source_user_id` rate per source; a spike means the identity
  feed broke for that partner and their users vanish from the active base.
- **Cross-source double counting** — same user, merchant, day and amount from two networks. Ids
  differ, so id-level de-duplication cannot see it (`dq_cross_source_duplicate_suspects`).
- **Timezone and quarter boundaries** — normalise purchase timestamps at ingestion; transactions
  near quarter end are the ones that move.
- **Late arrival** — share of a quarter's transactions delivered after quarter close, per source.
  This drives the reporting lag.
- **Financial reconciliation** — counts and amounts against the network's own reports and the
  finance payout file.

---

## Reporting layer

[`docs/looker_studio_report_design.html`](docs/looker_studio_report_design.html) specifies a
nine-page Looker Studio report: **68 tiles, 19 data sources, zero blends**. Every tile names its
source, dimensions, metrics, filters and sort, and every wireframe uses real pipeline output — so
a correct replication matches tile for tile.

| # | Page | Focus |
|---|---|---|
| 1 | Executive Summary | Headline scorecards, transitions, sensitivity, DQ gate |
| 2 | Active Base & Channel Mix | Channel decomposition that proves "counted once" |
| 3 | Churn Transitions | The three quarter-to-quarter transitions |
| 4 | Q1 Cohort | Confirmed churn and Q3 reactivation |
| 5 | Definition Sensitivity | Baseline vs approved-only, with the 5 users that flip |
| 6 | Pending Exposure | Vintage re-measurement, approval maturity, reporting lag |
| 7 | Affiliate Source Monitoring | Feed continuity, approval rates, decision latency |
| 8 | **Data Quality & Monitoring** | Publish gate, 21 assertions, row-count drift, runbook |
| 9 | User Trace | One person, raw events → classification, both definitions |

`sql/10_looker_studio_views.sql` adds five reporting views — no new logic, just reshaping the
wide marts into the long form charts need, plus row-count drift and build-freshness monitoring.

---

## Assumptions

1. **Unmapped source ids are excluded and reported, not guessed.** `B9999` (transaction `CB0098`,
   approved, 85 SAR, Q2) has no identity-map row. Inventing a unified id would put a fabricated
   person in the denominator; dropping it silently would hide a broken identity feed.
2. **Duplicate ids are collapsed deterministically.** `CE0009` and `CB0001` each appear twice with
   identical payloads. Staging keeps one and flags `was_duplicated_in_raw`. A duplicate id with a
   *different* payload is a separate, higher-severity check — that is an integration bug, not a replay.
3. **The user universe is the identity map** (66 users), not just users with activity, so "never
   active in 2025" is representable. Churn rates are unaffected: the denominator is always users
   active in the *from* quarter.
4. **Only `coupon_copy` is eligible coupon activity.** It is the only `event_type` present; the
   filter is kept as a flag column so a rule change is a one-line edit.
5. **Quarter membership is calendar-based** (`DATE_TRUNC(date, QUARTER)`), no fiscal offset.

---

## At production scale

The build is a linear DAG of idempotent `CREATE OR REPLACE` statements, so any orchestrator works.
In **Dataform**, files 01–07 map one-to-one to `.sqlx` definitions with `ref()` replacing the
hard-coded names, and the checks in 06 become `assertions` that block publication. As a plain
**BigQuery scheduled query**, concatenate 01–07 and 09–10 into one script, schedule it at the
chosen reporting lag, and gate the mart refresh on
`COUNTIF(check_status = 'FAIL' AND severity = 'error') = 0`.

Three things would change with real volume: staging and the event stream become incremental on
activity month with a reprocess window sized by `max_days_to_decision`; the identity map becomes a
type-2 dimension with validity ranges (which forces an explicit answer to *does a merge restate
history?*); and the assertions become gates rather than a table. Partitioning and clustering are
already declared for shape — they buy nothing at 264 rows and start paying immediately at scale.

Full reasoning, every column definition, and seven design decisions with their rejected
alternatives are in [`docs/data_model.html`](docs/data_model.html).

---

## Source data

All records and identifiers are **fully synthetic** and contain no real customer data. The
workbook models 66 users across four quarters, six fictional affiliate networks, and deliberately
includes duplicate ids, an unmapped user id, rejected/cancelled transactions, and decisions that
land in a later quarter than the purchase.

The SQL has not been executed against a live BigQuery instance — the churn logic is validated
against an independent Python reproduction of the same rules, but expect to shake out a syntax
typo or two on the first run.
