# Warehouse Operations KPI Dashboard

**An operations control tower for a marketplace fulfilment network — built on 99,441 real customer orders.**

This project answers the question a warehouse manager actually asks every morning:
*"Where did we lose service yesterday, which node caused it, and what is it costing us?"*

It is built end-to-end on a **real, public e-commerce logistics dataset** — not generated data — with a
data-quality gate in front of every published number.

| | |
|---|---|
| **Dataset** | [Brazilian E-Commerce Public Dataset by Olist](https://www.kaggle.com/datasets/olistbr/brazilian-ecommerce) (real transactions, CC BY-NC-SA 4.0) |
| **Scale** | 99,441 orders · 112,650 order lines · 3,095 fulfilment nodes · 32,951 SKUs · 27 states · 25 months |
| **Stack** | SQL (portable ANSI, runs on DuckDB) · Power BI · DAX · Power Query · Excel |
| **Run it** | `.\run_pipeline.ps1` — downloads data, builds the model, publishes 15 KPI marts |

---

## Headline results

| KPI | Value |
|---|---:|
| Total orders | **99,441** |
| Delivery success rate | **97.01%** |
| On-time delivery (vs. customer promise) | **93.23%** |
| Delayed deliveries | **6,534** |
| Average delivery time | **12.52 days** |
| Average promise given to customer | **24.37 days** |
| **Unused promise buffer** | **11.88 days** |
| Perfect Order Rate | **74.47%** |
| Average CSAT | **4.07 / 5** |
| Revenue | **R$ 13.59 M** |
| Freight cost | **R$ 2.25 M** (16.6% of revenue) |

---

## The four findings that matter

### 1 · A single late day triples customer dissatisfaction — the CSAT cliff

Delivery lateness does not degrade satisfaction gradually. It falls off a cliff the moment the promise breaks.

| Delivery outcome | Orders | % of orders | Avg CSAT | 1–2★ rate |
|---|---:|---:|---:|---:|
| Very early (>10d) | 61,849 | 64.1% | 4.31 | 9.1% |
| Early (3–10d) | 23,783 | 24.7% | 4.23 | 10.1% |
| On time (0–3d) | 4,304 | 4.5% | 4.09 | 12.1% |
| **Late 1–3d** | 1,870 | 1.9% | **3.28** | **32.4%** |
| **Late 4–7d** | 1,802 | 1.9% | **2.09** | **68.1%** |
| **Late >7d** | 2,862 | 3.0% | **1.69** | **79.5%** |

Slipping from on-time to just **1–3 days late** takes the 1–2★ rate from 12.1% → **32.4%** (2.7×).
Slipping past 7 days takes it to **79.5%**.

**Why it matters:** the 6,534 late orders carry **R$ 985,924** of revenue and generate the overwhelming
majority of detractors. Lateness is not a logistics metric — it is the single largest controllable driver
of customer satisfaction in this dataset.

### 2 · The Feb–Mar 2018 service collapse was a *carrier* failure, not a seller failure

On-time delivery fell to **81.04%** in March 2018 — 12 points below baseline. Decomposing the lead time
into its three owned legs isolates the cause immediately:

| Month | On-time | Leg 2 · Dispatch (seller) | Leg 3 · Transit (carrier) | Total lead time |
|---|---:|---:|---:|---:|
| 2018-01 | 94.3% | 3.16 d | 10.48 d | 14.08 d |
| **2018-02** | **85.9%** | 3.17 d | **13.30 d** | 16.87 d |
| **2018-03** | **81.0%** | 2.98 d | **12.96 d** | 16.29 d |
| 2018-04 | 95.5% | 2.21 d | 8.67 d | 11.50 d |

**Dispatch performance never moved** (3.16 → 2.98 days). Transit inflated by **+27%**. Escalating to
sellers would have been the wrong call — the failure was entirely downstream of carrier handover.

### 3 · Customers are over-promised by ~12 days

Average delivery is **12.5 days** against an average promise of **24.4 days** — a permanent **11.9-day
buffer**. In e-commerce, quoted delivery date is a conversion lever: a padded promise protects the
on-time metric while suppressing the sale.

The dataset shows the buffer is also the leading indicator of failure — the two worst service months
(Feb/Mar 2018) are exactly the months where the buffer had been cut to **8.29** and **6.43** days.
Tightening the promise without fixing transit is what caused the breach.

**Recommendation:** move from a flat promise to a lane-and-tier-specific promise (the model in
`outputs/lane_performance.csv` supports this), releasing buffer only where transit variance is proven low.

### 4 · 186 sellers put R$ 2.06 M of revenue at dispatch risk

Measuring each seller against their **contractual handover deadline** (`shipping_limit_date`) — a real SLA
in the source data, not a derived proxy:

| SLA band | Sellers | Order lines | Revenue |
|---|---:|---:|---:|
| A · Reliable (≥95%) | 466 | 46,029 | R$ 5.02 M |
| B · Watch (85–95%) | 242 | 35,623 | R$ 4.26 M |
| **C · At risk (70–85%)** | **119** | **11,999** | **R$ 1.39 M** |
| **D · Breach (<70%)** | **67** | **6,560** | **R$ 0.68 M** |

The worst fulfilment nodes are concentrated and therefore fixable: `santana de parnaiba, SP` dispatches
on time only **57.2%** of the time across 146 orders; `sao luis, MA` **68.2%** across 392 orders.

---

## Dashboard pages

| Page | Answers | Source mart |
|---|---|---|
| **Executive** | Are we hitting service and revenue targets? | `kpi_executive.csv`, `kpi_monthly.csv`, `kpi_daily.csv` |
| **Warehouse Performance** | Which nodes are best/worst, and why? | `warehouse_performance.csv`, `seller_dispatch_scorecard.csv` |
| **Inventory & Assortment** | What is moving, what is dead? | `product_movement_abc.csv`, `category_performance.csv` |
| **Delivery Analysis** | Where is the time going, and what does lateness cost? | `leadtime_decomposition.csv`, `delivery_band_csat.csv`, `region_performance.csv`, `lane_performance.csv` |

Visuals: KPI cards · clustered bar · line · donut · treemap · filled map · matrix heatmap · slicers.
Build instructions: [`powerbi/BUILD_GUIDE.md`](powerbi/BUILD_GUIDE.md) · [`excel/BUILD_GUIDE.md`](excel/BUILD_GUIDE.md).

A static, self-contained preview of the executive page is in [`dashboard/index.html`](dashboard/index.html)
(open in any browser — no server, no dependencies).

---

## Architecture

```
data/raw/*.csv                 8 real source files
        │
        ▼
sql/01_build_model.sql         star schema: dim_product · dim_seller · dim_customer
        │                      dim_date · fct_order (99,441) · fct_order_line (112,650)
        │                      ALL date arithmetic resolved here into numeric columns
        ▼
sql/02_data_quality.sql        19 rules · BLOCK vs WARN · outputs/data_quality_report.csv
        │
        ▼
sql/03_kpi_marts.sql           15 published marts -> outputs/*.csv
        │
        ├──▶ Power BI  (powerbi/measures.dax — 40+ measures)
        ├──▶ Excel     (Power Query + PivotTables)
        └──▶ dashboard/index.html
```

**Why date maths lives in the model layer:** every lead-time leg is computed once, in
`01_build_model.sql`, into plain numeric columns. Downstream analysis SQL contains **no engine-specific
date functions**, so the same files port to MySQL or SQL Server by swapping only the staging script.

---

## Data quality — what the gate caught

The pipeline refuses to publish a number it has not checked. 19 rules run before any mart is written
(`outputs/data_quality_report.csv`). Real defects found in this dataset:

| Rule | Severity | Rows | How it is handled |
|---|---|---:|---|
| Dispatched before order approval | BLOCK | 1,359 | Excluded from lead-time metrics, **retained** for volume/revenue — dropping them would understate order count by 1.4% |
| Orders with >1 review | BLOCK | 555 | De-duplicated to the latest review; left unhandled this fans out CSAT joins and inflates order counts |
| Delivered before dispatch | BLOCK | 23 | Excluded from lead-time metrics |
| Status `delivered` with no delivery timestamp | BLOCK | 8 | Not counted as delivered |
| Missing carrier handover timestamp | WARN | 1,783 | Leg 2/3 null-safe; order still counted |
| Products with no category | WARN | 610 | Mapped to `unclassified` rather than dropped |

Handling these correctly is the difference between a 93.23% on-time figure and a wrong one.

---

## Known gaps (stated, not hidden)

The source extract is a real marketplace feed and does not contain everything a WMS would:

- **No stock-on-hand column.** True inventory KPIs — turnover, days-of-cover, safety stock, reorder point —
  are therefore *not* claimed here. The Inventory page reports movement-based assortment health
  (fast/slow movers, ABC concentration, dormancy), which is genuinely derivable.
  Stock-level analytics live in the companion project,
  **[Inventory & Supply Chain Analytics](../inventory-supply-chain-analytics)**, on a dataset that carries
  real inventory positions.
- **No carrier/delivery-partner ID.** Carrier performance is measured at the transit-leg level
  (`leg3_transit_days`) and by lane, not by named partner.
- **No returns table.** Post-delivery returns are not in the feed. 1–2★ reviews are used as a
  *dissatisfaction* signal and are labelled as such — never presented as a return rate.
- **"Warehouse" = fulfilment node.** This is a marketplace: shipments originate from seller locations, so a
  fulfilment node is defined as origin `city, state`. The mapping is documented in
  [`docs/02_data_dictionary.md`](docs/02_data_dictionary.md).

---

## Reproduce

```powershell
git clone https://github.com/saksham-vlsi/warehouse-operations-kpi-dashboard.git
cd warehouse-operations-kpi-dashboard
.\run_pipeline.ps1
```

Downloads the raw data, fetches a portable DuckDB binary, builds the model, runs the quality gate and
publishes every mart in `outputs/`. Takes about a minute. No database server, no Python, no admin rights.

---

## Repository map

```
sql/            01 model · 02 quality gate · 03 KPI marts
outputs/        15 published marts (committed — inspect without running anything)
powerbi/        measures.dax · BUILD_GUIDE.md · data model spec
excel/          BUILD_GUIDE.md — Power Query, PivotTables, conditional formatting
dashboard/      index.html — self-contained executive view
docs/           business problem · data dictionary · metric definitions · findings
data/           download_data.ps1 (raw CSVs are gitignored)
```

---

## Metric definitions

Every KPI is defined precisely in [`docs/03_metric_definitions.md`](docs/03_metric_definitions.md),
including the two decisions that most affect the headline numbers:

- **On-time** is evaluated at **date** grain, not timestamp — the promise carries a `00:00:00` component,
  so a timestamp comparison would wrongly fail every same-day delivery.
- **Perfect Order Rate** = delivered **and** on time **and** CSAT ≥ 4 — a customer-outcome definition,
  not a warehouse-only one.

---

*Data: Olist (CC BY-NC-SA 4.0). Analysis and code: MIT.*
