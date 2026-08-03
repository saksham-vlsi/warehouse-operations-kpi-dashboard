# Findings & Recommendations

Five findings, each with the evidence that produced it, the quantified exposure, and a recommendation
that names an owner. Every number here comes from `outputs/` and is reproducible with `.\run_pipeline.ps1`.

---

## Finding 1 — Lateness causes ~3,300 excess detractors a year

**Evidence** — `outputs/delivery_band_csat.csv`

| Delivery outcome | Orders | Avg CSAT | 1–2★ rate |
|---|---:|---:|---:|
| On time (0–3d) | 4,304 | 4.09 | 12.1% |
| Late 1–3d | 1,870 | 3.28 | 32.4% |
| Late 4–7d | 1,802 | 2.09 | 68.1% |
| Late >7d | 2,862 | 1.69 | 79.5% |

**Quantification.** 6,534 orders were delivered late and produced

```
(1,870 × 32.4%) + (1,802 × 68.1%) + (2,862 × 79.5%)  =  4,108 detractors
```

Had those same orders arrived on time, the expected detractor count at the on-time baseline rate is
`6,534 × 12.1% = 791`. Lateness therefore generates **3,317 excess 1–2★ reviews** — roughly **22% of all
detractors in the dataset**, from just **6.8% of delivered orders**.

**Recommendation.** Treat the promise-break as the primary CX incident, not a logistics footnote.
Any order whose projected delivery crosses its promise date should raise an intervention (expedite,
proactive notification, goodwill credit) *before* the breach, not after the review lands. The severity
banding shows where to spend: an order already 4+ days late has a 68–80% chance of becoming a detractor,
so recovery effort is worth far more there than a blanket policy.
**Owner:** Customer Operations + Last-Mile.

---

## Finding 2 — The Feb–Mar 2018 collapse was carrier-side; escalating to sellers would have failed

**Evidence** — `outputs/leadtime_decomposition.csv`, `outputs/kpi_monthly.csv`

| Month | Orders | On-time | Leg 1 approval | Leg 2 dispatch | Leg 3 transit | Total |
|---|---:|---:|---:|---:|---:|---:|
| 2018-01 | 7,069 | 94.3% | 0.43 d | 3.16 d | 10.48 d | 14.08 d |
| **2018-02** | 6,728 | **85.9%** | 0.40 d | 3.17 d | **13.30 d** | 16.87 d |
| **2018-03** | 7,211 | **81.0%** | 0.36 d | 2.98 d | **12.96 d** | 16.29 d |
| 2018-04 | 6,798 | 95.5% | 0.62 d | 2.21 d | 8.67 d | 11.50 d |

**Reading it.** Dispatch — the leg sellers and fulfilment nodes own — was *flat to improving*
(3.16 → 3.17 → 2.98 days). Transit inflated **+27%** and accounts for essentially all of the 13-point
on-time drop. Order volume was not the trigger either: March 2018 (7,211 orders) ran at almost exactly
January's volume (7,069) with 13 points worse service.

**Why this matters operationally.** The instinctive response to a service drop is a seller escalation
programme. On this data that would have consumed weeks and fixed nothing.

**Recommendation.** Make leg-level attribution the first slide of every service review. Set separate
control limits per leg (dispatch ≈ 3.0 d, transit ≈ 8.7 d baseline) and alert on the *leg*, not the total.
**Owner:** Network Planning.

---

## Finding 3 — 11.9 days of promise buffer is being spent on nothing

**Evidence** — `outputs/kpi_executive.csv`, `outputs/kpi_monthly.csv`

Average delivery is **12.52 days** against an average promise of **24.37 days**. The business is quoting
roughly **double** the delivery time it actually achieves, on every order, permanently.

That buffer is not free — in e-commerce the quoted date is a conversion lever, and a padded date
suppresses the sale that funds the network.

**But the buffer is also the early-warning signal.** The two worst service months are exactly the months
where the buffer had already been compressed:

| Month | Avg buffer | On-time |
|---|---:|---:|
| 2017-12 | 13.01 d | 92.5% |
| 2018-02 | 8.29 d | 85.9% |
| **2018-03** | **6.43 d** | **81.0%** |
| 2018-04 | 12.93 d | 95.5% |

**Recommendation.** Replace the flat promise with a **lane-and-tier promise** driven by
`outputs/lane_performance.csv` and `outputs/region_performance.csv`. Release buffer only where transit
variance is demonstrably low — Southeast intra-region lanes deliver in a fraction of the time quoted to
North/Northeast lanes, yet both receive similar padding. Track `avg_buffer_days` as a **leading**
indicator: when it drops below ~8 days the network is running without protection and a breach follows.
**Owner:** Planning + Pricing.

---

## Finding 4 — 186 sellers hold R$ 2.06 M of revenue at dispatch risk

**Evidence** — `outputs/seller_dispatch_scorecard.csv`

Measured against `shipping_limit_date`, the seller's real contractual deadline:

| Band | Sellers | Order lines | Revenue |
|---|---:|---:|---:|
| A · Reliable (≥95%) | 466 | 46,029 | R$ 5.02 M |
| B · Watch (85–95%) | 242 | 35,623 | R$ 4.26 M |
| **C · At risk (70–85%)** | **119** | **11,999** | **R$ 1.39 M** |
| **D · Breach (<70%)** | **67** | **6,560** | **R$ 0.68 M** |

The failure is concentrated, which makes it tractable — 186 of 894 measurable sellers (21%) carry the
problem, and the worst nodes are geographically clustered:

| Fulfilment node | Orders | Dispatch on-time |
|---|---:|---:|
| santana de parnaiba, SP | 146 | 57.2% |
| laranjal paulista, SP | 226 | 65.3% |
| dracena, SP | 228 | 65.0% |
| foz do iguacu, PR | 180 | 68.0% |
| sao luis, MA | 392 | 68.2% |

**Recommendation.** Run a banded seller programme rather than a uniform one: Band D goes to
mandatory remediation or delisting from same-day/express promise eligibility; Band C gets pick-up
window changes and cut-off coaching. Note that three of the five worst nodes are in São Paulo — the
densest, best-connected state — which points at **local cut-off and pick-up scheduling**, not distance.
**Owner:** Seller Operations.

---

## Finding 5 — Freight is 16.6% of revenue, and part of it is spent shipping air

**Evidence** — `outputs/category_performance.csv`, `outputs/lane_performance.csv`

Total freight is **R$ 2.25 M on R$ 13.59 M of revenue (16.6%)**. Freight is billed on chargeable weight —
`GREATEST(actual, (L×H×W)/5000)` — and across every major category the **volumetric weight exceeds the
actual weight**, meaning the parcel's box, not its contents, sets the bill.

Freight intensity is highly uneven by category (freight as % of revenue):

| Category | Freight % of revenue |
|---|---:|
| electronics | 29.1% |
| office_furniture | 25.0% |
| furniture_decor | 23.7% |
| housewares | 23.1% |
| telephony | 22.0% |

`electronics` is the sharpest case: light items (0.78 kg average) billed at 1.12 kg volumetric — the
category pays a **44% weight premium purely on packaging dimensions**.

**Recommendation.** Prioritise packaging redesign by `pct_dim_weight_billed × freight spend`, not by
parcel count. The categories above are small in unit terms but carry the highest freight leakage per
rupee of revenue. Pair this with lane-level review: `Inter-Region` lanes carry materially higher freight
ratios than `Intra-State`, so origin-node placement for high-dim categories is the second lever.
**Owner:** Packaging Engineering + Network Design.

---

## Priority

| # | Finding | Effort | Impact | Sequence |
|---|---|---|---|---|
| 2 | Leg-level attribution & alerting | Low | High | **First** — costs nothing, prevents mis-directed escalations |
| 4 | Banded seller programme | Medium | High | Second — concentrated and addressable |
| 1 | Pre-breach intervention | Medium | High | Third — depends on 2 for prediction |
| 3 | Lane-specific promise | High | High | Fourth — needs 2 and 4 stable first |
| 5 | Packaging / dim-weight | High | Medium | Ongoing |

Finding 3 is deliberately sequenced last despite being the largest opportunity: tightening the promise
before transit is under control is precisely what produced the March 2018 breach.
