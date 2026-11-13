# Insurance Claims Operations Analytics

## Project Overview

An end-to-end analytics project examining motor insurance claims operations using event-log data. The project uses Python, PostgreSQL, and Power BI to analyze claim volumes, processing times, workflow transitions, document requirements, and operational bottlenecks.

## Dataset

**Source:** Levich, Sergej (2023). *Claims Management Log Dataset with Digital Documents*. Mendeley Data, V1. https://doi.org/10.17632/kdcspz6xtn.1

- 32,058 process events
- 5,131 claims
- Observation period: January 2014–January 2020
- Source file: `data/raw/process_log.csv`

Only `process_log.csv` is used in this project.

## Repository Structure

```text
.
├── .devcontainer/
│   ├── .env
│   ├── Dockerfile
│   ├── devcontainer.json
│   └── docker-compose.yml
├── .github/
│   └── dependabot.yml
├── .vscode/
│   └── settings.json
├── data/
│   ├── raw/
│   │   └── process_log.csv
│   └── processed/
│       ├── claim_summary.csv
│       └── cleaned_process_log.csv
├── notebooks/
│   └── claims_operations_eda.ipynb
├── power_bi/
│   └── claims_operations_dashboard.pbix
├── reports/
│   ├── claims_operations_eda_report.pdf
│   └── sql_outputs/
│       ├── 01_window_functions_deep_dive.txt
│       ├── 02_ctes_and_process_mining.txt
│       ├── 03_cohort_and_temporal_trends.txt
│       ├── 04_advanced_aggregations_and_kpis.txt
│       └── 05_reporting_views.txt
├── sql/
│   ├── 00_schema_and_ingestion.sql
│   ├── 01_window_functions_deep_dive.sql
│   ├── 02_ctes_and_process_mining.sql
│   ├── 03_cohort_and_temporal_trends.sql
│   ├── 04_advanced_aggregations_and_kpis.sql
│   └── 05_reporting_views.sql
├── .gitignore
├── README.md
└── requirements.txt
```

## Technology Stack

- **Python:** data cleaning, aggregation, exploratory data analysis, and statistical testing.
- **PostgreSQL:** workflow analysis, process transitions, temporal analysis, advanced aggregations, and reporting views.
- **Power BI:** interactive dashboard and operational reporting.
- **Docker / VS Code Dev Containers:** reproducible development environment.
- **Jupyter Notebook:** reproducible analysis and reporting.

## Exploratory Data Analysis

The Python analysis examines claim characteristics, lifecycle durations, document volumes, and relationships between damage types and processing outcomes.

Key findings:

- Glass damage and rodent bites account for 79.4% of claims.
- 99.0% of claims begin with a notification event.
- Median claim lifecycle duration is 4.40 days; the mean is 14.06 days, reflecting a heavily right-skewed distribution.
- Document request to damage documents has a median transition time of 8.02 days.
- Document volume is positively associated with claim duration (Spearman ρ = 0.349).

Statistical tests indicate differences in lifecycle duration and document volume across damage types. These are observational associations, not evidence of causation.

## SQL Analysis

Six SQL scripts cover:

1. Schema creation and data ingestion.
2. Window functions and claim-level sequencing.
3. CTEs and process mining.
4. Cohort analysis and temporal trends.
5. Advanced aggregations and operational KPIs.
6. Reporting views.

Key findings:

- 50.3% of claims exhibit repeated state patterns, used as a proxy for potential rework.
- Claims with repeated state patterns have a median lifecycle of 7.77 days, compared with 1.32 days for claims following linear paths.
- Document request to damage documents accounts for 8,662.1 cumulative days across 696 transitions.
- Lifecycle duration increases across document-page brackets.

The repeated-state measure identifies potential process inefficiency; it does not establish that every repeated state represents rework.

## Power BI Dashboard

The Power BI dashboard presents claim volume, processing duration, event counts, document volume, and breakdowns by claim characteristics.

File: `power_bi/claims_operations_dashboard.pbix`

## Data Processing

- `process_log.csv` is retained as the original source.
- `cleaned_process_log.csv` contains the cleaned and standardized event-level data.
- `claim_summary.csv` contains one aggregated record per claim.
- The claim-level dataset includes claim identifiers, damage types, first and last events, event counts, document totals, lifecycle duration, and page brackets.

## Limitations

- The dataset represents historical process logs from one insurance context.
- Lifecycle duration can include long observational gaps and should not automatically be interpreted as active processing time.
- Repeated state patterns are a proxy for potential rework, not a verified rework classification.
- Statistical associations between claim characteristics and processing outcomes do not establish causation.
- The dataset does not provide sufficient evidence to verify actual automation or straight-through processing.

## Reproducibility

1. Open the repository in VS Code.
2. Select **Reopen in Container** to build and start the development environment.
3. Run `notebooks/claims_operations_eda.ipynb` for the Python analysis.
4. Execute the SQL scripts in numerical order, beginning with `00_schema_and_ingestion.sql`.
5. Open `power_bi/claims_operations_dashboard.pbix` to explore the dashboard.

SQL execution outputs are included in `reports/sql_outputs/`. The rendered exploratory analysis is available at `reports/claims_operations_eda_report.pdf`.