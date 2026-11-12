# Insurance Claims Operations Analytics

An end-to-end operational analytics portfolio project evaluating claims processing efficiency, workflow transitions, and lifecycle durations using real-world motor insurance process event logs.

---

## Project Overview

This project simulates the analytical workflows of a **Claims Department Data Analyst** within a property & casualty (P&C) insurer. The primary operational objective is to examine cycle-time distributions, analyze workflow transitions between process states, evaluate the empirical relationships between document volume and lifecycle duration, and identify potential areas for operational investigation.

The project is structured in modular phases:
1. **Phase 1: Exploratory Data Analysis (EDA) in Python** *(Completed)*
2. **Phase 2: Relational Database Modeling & Advanced SQL Analytics** *(Completed)*
3. **Phase 3: Executive BI Dashboards (Power BI / Tableau)** *(Upcoming)*

---

## Dataset & Provenance

- **Source:** Levich, Sergej (2023), *Claims Management Log Dataset with Digital Documents*, Mendeley Data, Version 1.  
  [https://doi.org/10.17632/kdcspz6xtn.1](https://doi.org/10.17632/kdcspz6xtn.1)
- **Domain:** Historical operational event logs from a German motor insurance company.
- **Volume:** 5,131 distinct insurance claims (`instance_id`), comprising 32,058 recorded process events.
- **Coverage Window:** January 2014 through January 2020.

### Schema Overview

| Field Name | Type | Description |
|---|---|---|
| `timestamp` | UTC Timestamp | Event occurrence timestamp (ISO 8601 parsed to `datetime64[ns, UTC]`). |
| `instance_id` | Integer | Unique identifier for each claim file. |
| `state` | Integer | Numeric identifier for the process event stage. |
| `state_name` | String | Descriptive name of the process state (12 distinct categories). |
| `type` | Integer | Numeric damage category code. |
| `type_name` | String | Descriptive damage category (6 distinct categories). |
| `file_name` | String | Distinct document filename attachment (where applicable; 16,132 unique files). |
| `n_pages` | Float | Number of pages in the attached document (1 to 10 pages; mean 2.43). |
| `time_since_last_event` | Integer | Elapsed interval in seconds since the immediately preceding event for that claim. |
| `log_time_since_last_event`| Float | Natural log transform: $\ln(\text{seconds} + 1)$. |

---

## Important Analytical Scope & Data Limitations

1. **Process-Event Log vs. Financial Claims Database:**  
   The dataset captures operational event logs. It does **not** contain claim indemnity payments, loss reserves, deductible amounts, adjuster identities, adjuster caseloads, underwriting profitability, or verified fraud labels. Metrics regarding loss ratios or adjuster productivity cannot be imputed.
2. **Event-Level vs. Claim-Level Observations:**  
   Event logs record discrete system interactions (32,058 rows across 5,131 claims; median 6.0 events/claim). Aggregations must explicitly distinguish between event frequencies and unique claim volumes.
3. **Preceding Event Interval vs. Stage Duration:**  
   `time_since_last_event` records the elapsed time since the *prior* event. Grouping this interval by the *current* event state reflects the interval elapsed prior to recording that state, **not** the operational duration spent actively working inside that state.
4. **Recorded Lifecycle Duration vs. Actual Settlement/Closure:**  
   Lifecycle duration is calculated as the span between the first and last recorded events for an `instance_id`. It must **not** be equated with final legal settlement or claim closure. Furthermore, claims terminating in states other than payment or audit cannot be assumed to be open at the observation cutoff without explicit metadata.
5. **Observational Gaps in Long-Duration Lifecycles:**  
   Claims spanning >1 year are characterized by lengthy gaps between recorded events (hundreds of days with no logged events) rather than active, continuous processing delays.
6. **Document Metadata Scope:**  
   Missing values in `file_name` and `n_pages` indicate that no digital document attachment was logged for that specific event; it does not establish that the entire claim was document-free in physical reality.
7. **Descriptive Empirical Findings:**  
   Correlations and group differences represent empirical associations within observational process logs. They do not demonstrate causal mechanisms.

---

## Project Structure

```text
Insurance Claims Operations Analytics/
├── .venv/                         # Preserved Python virtual environment
├── data/
│   ├── raw/                       # Immutable source dataset
│   │   └── process_log.csv
│   └── processed/                 # Cleaned and aggregated operational datasets
│       ├── cleaned_process_log.csv
│       └── claim_summary.csv
├── EDA/                           # Dedicated exploratory data analysis module
│   ├── claims_operations_eda.ipynb # Comprehensive, reproducible EDA report notebook
│   ├── data_exploration.ipynb     # In-sync reproducible exploratory notebook
│   └── archive/                   # Preserved original exploratory notebook
│       └── data_exploration_initial.ipynb
├── sql/                           # Relational modeling & advanced SQL analytics suite
│   ├── 00_schema_and_ingestion.sql          # DDL, relational constraints & bulk COPY
│   ├── 01_window_functions_deep_dive.sql    # Sequencing, ranking, lead/lag, rolling & NTILE
│   ├── 02_ctes_and_process_mining.sql       # Multi-stage CTEs, transition matrices & rework loops
│   ├── 03_cohort_and_temporal_trends.sql    # Time series, monthly MoM/YoY & SLA aging tiers
│   ├── 04_advanced_aggregations_and_kpis.sql# GROUPING SETS, ROLLUP, CUBE, FILTER & Z-scores
│   └── 05_reporting_views.sql               # Semantic reporting layer for BI (Power BI/Tableau)
├── reports/                       # Exported figures and analytics deliverables
│   └── figures/                   # Standalone 300 DPI charts (fig1 through fig9)
├── .gitignore                     # Git configuration ignoring virtualenv & caches
├── README.md                      # Comprehensive project documentation
└── requirements.txt               # Pinned dependencies for reproducible execution
```

---

## Environment Setup & Reproducibility

### 1. Prerequisites
- Python 3.10+ (configured on Python 3.13)
- PowerShell (Windows) or Bash (macOS/Linux)

### 2. Activate Virtual Environment
```powershell
# Windows PowerShell
.venv\Scripts\Activate.ps1
```

### 3. Install Pinned Dependencies
```powershell
pip install -r requirements.txt
```

### 4. Running the EDA Notebook
Open Jupyter Lab or Jupyter Notebook:
```powershell
jupyter lab
```
Navigate to `EDA/claims_operations_eda.ipynb` and execute cells sequentially. The notebook dynamically resolves paths relative to the project root or local `EDA/` folder.

### 5. Headless PDF Export (No LaTeX Required)
The notebook is configured for automated PDF export via `jupyter nbconvert` using its WebPDF engine (powered by Playwright and headless Chromium):
```powershell
jupyter nbconvert --to webpdf --allow-chromium-download EDA/claims_operations_eda.ipynb
```
*(Alternatively, uncomment and execute the designated cell at the bottom of the notebook.)*

---

## Key Analytical Findings (EDA Phase)

- **Portfolio Composition:** Glass damage (38.5%, 1,976 claims) and Rodent bites (40.9%, 2,098 claims) account for **79.4%** of all claim files. Animal damage (6.2%) and Parking damage (13.6%) represent higher-complexity categories, while Scorch damage (0.3%) and Hit & run (0.4%) are rare.
- **Initial Notification Interval:** 99.0% of claims begin with `Notification of claim`. The observed median transition interval from `Notification of claim` to `Processing` is **0.035 days (approximately 2.1 minutes)**, with a mean of 0.024 days.
- **Observed Transition Intervals:** Among high-volume transitions, the interval between `Document request` and receipt of `Damage documents` exhibits a median of **8.020 days (192.5 hours)** and a mean of **12.446 days** across 696 observed transitions.
- **Skewed Lifecycle Durations:** Overall claim lifecycles are heavily right-skewed ($\text{skew} = 8.16$). The portfolio median duration is **4.40 days** (IQR = 14.17 days), whereas the arithmetic mean is **14.06 days**, heavily influenced by four claims with multi-hundred-day observational gaps between events.
- **Statistical Associations (Non-Parametric Testing):**
  - Kruskal-Wallis testing indicates statistically significant differences in rank distributions across damage categories for lifecycle duration ($H = 367.45$, $p_{\text{holm}} < 10^{-76}$, $\eta^2_H = 0.071$), total document pages ($H = 389.48$, $p_{\text{holm}} < 10^{-81}$, $\eta^2_H = 0.075$), and event touchpoints ($H = 94.73$, $p_{\text{holm}} < 10^{-18}$, $\eta^2_H = 0.018$).
  - Post-hoc pairwise Mann-Whitney $U$ tests with Holm correction confirm that Animal damage (median 15.29 days) and Parking damage (median 13.13 days) have significantly longer lifecycle durations than Glass damage (median 2.96 days) and Rodent bites (median 3.88 days), while the difference between Glass and Rodent claims is not statistically significant ($p_{\text{holm}} = 0.366$).
  - Total document pages per claim show a moderate positive monotonic association with lifecycle duration (Spearman $\rho = 0.349$, $p < 10^{-140}$).

---

## Potential Areas for Operational Investigation

*The following areas represent operational hypotheses for leadership inquiry, clearly separated from the empirical findings of the process logs:*

1. **Document Request and Submission Workflows:**
   - *Observation:* The observed interval between `Document request` and `Damage documents` has a median of 8.02 days and a 90th percentile of 25.68 days.
   - *Area for Investigation:* Claims leadership could evaluate whether implementing digital upload options, mobile document capture, or automated follow-up reminders could help reduce turnaround times for requested documentation.
2. **Workflow Triage by Claim Category:**
   - *Observation:* Glass damage and rodent bites comprise 79.4% of total claims and exhibit relatively short median lifecycles (2.96 and 3.88 days). Animal and parking damage involve longer lifecycles (15.29 and 13.13 days) and higher page counts.
   - *Area for Investigation:* Investigate whether routing high-volume, lower-complexity claims through streamlined handling paths could free up adjuster capacity for more complex claim types.
3. **Handling of Long-Gap Claims:**
   - *Observation:* Outlier claims (>365 days) exhibit multi-month gaps between recorded events.
   - *Area for Investigation:* Review organizational policies regarding claim status tracking, file dormancy thresholds, and periodic status checks to ensure claims with extended inactivity are appropriately categorized.

---

## Phase 2: Relational Database Modeling & Advanced SQL Analytics

The [`sql/`](sql/) directory implements the relational modeling and analytical queries for PostgreSQL 14+. Operational process logs are converted into a relational star schema and queried across an extensive range of SQL functions:

### Database Star Schema Architecture

```text
                  ┌──────────────────────┐
                  │   dim_damage_type    │
                  ├──────────────────────┤
                  │ damage_type_id (PK)  │
                  │ damage_type_name     │
                  │ complexity_tier      │
                  └──────────┬───────────┘
                             │
                             │ 1:N
                             ▼
┌────────────────────────┐      ┌───────────────────────────────┐
│     claim_summary      │      │        process_events         │
├────────────────────────┤      ├───────────────────────────────┤
│ instance_id (PK)       │      │ event_id (PK, BIGSERIAL)      │
│ damage_type            │◄─────┤ instance_id (FK)              │
│ first_event            │      │ event_timestamp               │
│ last_event             │      │ state_id (FK)                 │
│ first_state            │      │ state_name                    │
│ last_state             │      │ type_id (FK)                  │
│ event_count            │      │ type_name                     │
│ total_docs             │      │ file_name                     │
│ total_pages            │      │ n_pages                       │
│ duration_days          │      │ time_since_last_event_sec     │
│ page_bracket           │      │ log_time_since_last_event     │
└────────────────────────┘      └──────────────┬────────────────┘
                                               │
                                               │ N:1
                                               ▼
                                ┌───────────────────────────────┐
                                │       dim_process_state       │
                                ├───────────────────────────────┤
                                │ state_id (PK)                 │
                                │ state_name                    │
                                │ phase_category                │
                                │ is_terminal                   │
                                └───────────────────────────────┘
```

---

### SQL Suite Modules & Techniques

| Script | Core SQL Concepts | Operational Focus |
|---|---|---|
| **[`sql/00_schema_and_ingestion.sql`](sql/00_schema_and_ingestion.sql)** | DDL, PK/FK constraints, CHECK constraints, composite indexes, staging tables, bulk `COPY` | Star-schema creation, referential integrity, and automated CSV ingestion. |
| **[`sql/01_window_functions_deep_dive.sql`](sql/01_window_functions_deep_dive.sql)** | `ROW_NUMBER()`, `RANK()`, `DENSE_RANK()`, `LAG()`, `LEAD()`, `FIRST_VALUE()`, `LAST_VALUE()`, `NTILE(4/10)`, `CUME_DIST()`, `PERCENT_RANK()`, rolling frames (`ROWS BETWEEN ...`) | Lifecycle touchpoint sequencing, inter-event latency extraction, cumulative page accrual, moving averages, and duration quartile/decile triage. |
| **[`sql/02_ctes_and_process_mining.sql`](sql/02_ctes_and_process_mining.sql)** | Chained CTEs, Conditional Aggregation (Markov pivot), `WITH RECURSIVE` path traversal | Directed transition pairs, state transition probability matrix, bottleneck impact ranking, rework/ping-pong loop detection, and full workflow path reconstruction. |
| **[`sql/03_cohort_and_temporal_trends.sql`](sql/03_cohort_and_temporal_trends.sql)** | `DATE_TRUNC`, `EXTRACT(ISODOW/HOUR)`, `TO_CHAR`, rolling 3-month window, MoM/YoY growth via `LAG()` | Monthly intake cohorts, day-of-week staffing analysis, hourly intake heatmaps, and SLA aging distribution brackets (`< 24h` to `> 365d`). |
| **[`sql/04_advanced_aggregations_and_kpis.sql`](sql/04_advanced_aggregations_and_kpis.sql)** | `GROUPING SETS`, `ROLLUP`, `CUBE`, `FILTER (WHERE ...)`, `PERCENTILE_CONT`, `IQR`, `CORR`, Z-score anomaly detection | Multi-dimensional rollups, single-pass executive scorecards, non-parametric dispersion metrics, correlation matrices, and $+3\sigma$ outlier detection. |
| **[`sql/05_reporting_views.sql`](sql/05_reporting_views.sql)** | Semantic reporting layer DDL (`CREATE OR REPLACE VIEW`), derived KPI flags | Production views for BI dashboards: `v_claim_master`, `v_process_transitions`, `v_transition_bottlenecks`, `v_damage_scorecard`, and `v_monthly_intake_trend`. |

---

### Key Operational Findings from SQL Analytics

1. **Rework Loop Penalty:**  
   50.3% of claims experience rework loops (re-entering stages or repeat document requests). Claims with rework have a median lifecycle duration of **7.77 days** vs. **1.32 days** for clean linear paths (**5.9x duration increase**).
2. **Top Workflow Bottleneck:**  
   The transition from `Document request` to `Damage documents` consumes **8,662.1 cumulative portfolio days** across 696 transitions, with a median customer turnaround latency of **8.02 days** ($P_{90} = 25.67$ days).
3. **Straight-Through Processing (STP) Feasibility:**  
   Touchless straight-through processing is viable for **21.9% of Glass claims** and **18.6% of Rodent claims** (averaging 4.06 to 4.95 days), but drops to under 9.5% for Parking and Animal damage due to manual inspection requirements.
4. **Intake Seasonality & Staffing:**  
   Tuesday (1,005 claims) and Monday/Wednesday (870 claims each) represent peak claims intake days; weekends account for less than 15%. System activity peaks between 11:00 and 15:00 UTC.
5. **Document Burden Scaling:**  
   Claims with 1–5 pages resolve with a median of **0.99 days**, 6–10 pages take **4.30 days**, 11–20 pages take **13.71 days**, and 21+ pages take **19.97 days**. Page count exhibits a strong positive correlation with touchpoints ($r = 0.54 - 0.69$).

---

### Database Execution & Reproducibility

```bash
# 1. Run schema creation and ingestion
docker exec -i devcontainer-db-1 psql -U postgres -d claims_analytics < sql/00_schema_and_ingestion.sql

# 2. Run window functions suite
docker exec -i devcontainer-db-1 psql -U postgres -d claims_analytics < sql/01_window_functions_deep_dive.sql

# 3. Run CTEs & process mining suite
docker exec -i devcontainer-db-1 psql -U postgres -d claims_analytics < sql/02_ctes_and_process_mining.sql

# 4. Run temporal & cohort trends suite
docker exec -i devcontainer-db-1 psql -U postgres -d claims_analytics < sql/03_cohort_and_temporal_trends.sql

# 5. Run advanced aggregations & KPIs suite
docker exec -i devcontainer-db-1 psql -U postgres -d claims_analytics < sql/04_advanced_aggregations_and_kpis.sql

# 6. Deploy semantic reporting views for BI tools
docker exec -i devcontainer-db-1 psql -U postgres -d claims_analytics < sql/05_reporting_views.sql
```
