# Excel Build Guide

Builds a self-refreshing operations workbook from `outputs/`. Excel 2016+ or Microsoft 365.
Run `.\run_pipeline.ps1` first.

The workbook is not a copy of the Power BI report — it is the format operations teams actually
circulate: a one-page KPI sheet plus PivotTables they can slice themselves.

---

## 1 · Connect with Power Query (never paste CSVs)

**Data → Get Data → From File → From Folder** → point at `outputs\`.

Import these as connections. For each: **Transform Data**, set types, then
**Close & Load To… → Only Create Connection** *and tick* **Add this data to the Data Model**.

| Query | File | Load as |
|---|---|---|
| `FactOrders` | `fact_orders_flat.csv` | Data Model only (99,441 rows — too many for a sheet) |
| `Monthly` | `kpi_monthly.csv` | Table + Data Model |
| `Daily` | `kpi_daily.csv` | Data Model only |
| `Nodes` | `warehouse_performance.csv` | Table + Data Model |
| `Sellers` | `seller_dispatch_scorecard.csv` | Table + Data Model |
| `Regions` | `region_performance.csv` | Table + Data Model |
| `Categories` | `category_performance.csv` | Table + Data Model |
| `Movement` | `product_movement_abc.csv` | Data Model only |
| `LeadTime` | `leadtime_decomposition.csv` | Table + Data Model |
| `Bands` | `delivery_band_csat.csv` | Table + Data Model |
| `Quality` | `data_quality_report.csv` | Table |

**Why Power Query and not a paste:** the whole workbook refreshes with **Data → Refresh All** after the
pipeline reruns. A pasted workbook is stale the moment it is saved and has to be rebuilt by hand.

### Transform steps on `FactOrders`

1. **Set types explicitly** (dates → Date, `leg*_days`/revenue → Decimal, flags → Whole Number).
2. **Add Column → Conditional Column** `Service Status`: `is_delivered=0` → `Not delivered`;
   `is_on_time=1` → `On time`; else `Late`.
3. **Add Column → Custom Column** `Month`: `= Date.ToText([purchase_date], "yyyy-MM")`.
4. **Home → Remove Rows → Remove Errors.**

---

## 2 · Sheet 1 — KPI Dashboard

Build a card row using linked formulas off the `Monthly` table so it refreshes automatically.
With `Monthly` loaded as a table named `Monthly`:

```excel
Total Orders            =SUM(Monthly[orders])
Completed Orders        =SUM(Monthly[delivered])
Cancelled Orders        =SUM(Monthly[cancelled])
Revenue                 =SUM(Monthly[revenue])
Freight                 =SUM(Monthly[freight])
Average Order Value     =SUM(Monthly[revenue])/SUM(Monthly[orders])
Delayed Deliveries      =SUM(Monthly[delayed_deliveries])
On-Time Delivery %      =1-SUM(Monthly[delayed_deliveries])/SUM(Monthly[delivered])
Delivery Success Rate   =SUM(Monthly[delivered])/SUM(Monthly[orders])
Avg Delivery Days       =SUMPRODUCT(Monthly[avg_delivery_days],Monthly[delivered])/SUM(Monthly[delivered])
Avg Promised Days       =SUMPRODUCT(Monthly[avg_promised_days],Monthly[delivered])/SUM(Monthly[delivered])
Promise Buffer (days)   =[Avg Promised Days]-[Avg Delivery Days]
Avg CSAT                =SUMPRODUCT(Monthly[avg_csat],Monthly[orders])/SUM(Monthly[orders])
```

> Note the `SUMPRODUCT` weighting on every average. Taking `AVERAGE(Monthly[avg_delivery_days])` averages
> the months instead of the orders and quietly overweights low-volume months — a classic reporting bug
> that shows up as a KPI that disagrees with the SQL.

**Card formatting:** merge a 3×2 block per KPI, big number top, label beneath, thin border, white fill.
Apply **Conditional Formatting → Icon Sets** to On-Time Delivery %: green ≥ 0.95, amber ≥ 0.90, red below.

**Sparklines:** `Insert → Sparklines → Line`, data range `Monthly[on_time_pct]`, one per KPI card.

---

## 3 · Sheet 2 — PivotTables

**Insert → PivotTable → Use this workbook's Data Model.**

| PivotTable | Rows | Values | Chart |
|---|---|---|---|
| Monthly service | `Month` | Sum `orders`, Sum `delayed_deliveries`, Avg `on_time_pct` | Line + column combo |
| Node ranking | `fulfilment_node` | Avg `fulfilment_efficiency_score`, Sum `orders` | Bar, Top 10 filter |
| Seller SLA | `sla_band` | Count `seller_id`, Sum `order_lines`, Sum `revenue` | Stacked column |
| Region performance | `customer_state` | Sum `orders`, Avg `on_time_pct`, Avg `avg_delivery_days` | Bar |
| Category mix | `category` | Sum `revenue`, Avg `freight_pct_of_revenue` | Treemap |
| Movement class | `movement_class` | Count `product_id`, Sum `revenue` | Donut |
| Lead-time legs | `purchase_month` | Avg `leg1/leg2/leg3_days` | Stacked area |
| CSAT cliff | `delivery_band` | Sum `orders`, Avg `avg_csat`, Avg `pct_1_2_star` | Combo |

**Value Field Settings → Number Format** on every measure — set it once in the PivotTable, not by
formatting cells, or it resets on refresh.

---

## 4 · Slicers and timeline

**PivotTable Analyze → Insert Slicer:** `customer_region`, `Service Status`, `sla_band`, `category`.
**Insert Timeline:** `purchase_date`.

Then **Report Connections** on each slicer → tick every PivotTable, so one click filters the whole
workbook. Park the slicers down the left of Sheet 1.

---

## 5 · Conditional formatting that earns its place

| Range | Rule |
|---|---|
| `Nodes[dispatch_on_time_pct]` | 3-colour scale, red 60 → yellow 85 → green 100 |
| `Nodes[avg_dispatch_days]` | Data bars, shortest = best |
| `Regions[on_time_pct]` | Icon set, ▼ below 90 |
| `Sellers[sla_band]` | Custom rule: fill red where text = `D - Breach` |
| `Bands[pct_1_2_star]` | Data bars — makes the CSAT cliff visible without a chart |
| `Quality[status]` | Red fill where `FAIL` |

---

## 6 · Sheet 3 — Inventory / Assortment

From `Movement`:

- PivotTable: rows `abc_class`, values count of `product_id`, sum `revenue`, → **% of Grand Total** column
  to show the Pareto concentration.
- PivotTable: rows `movement_class` × `category`, values `units_sold` — the fast/slow matrix.
- Filtered table: `is_dormant_180d = 1` sorted by `revenue` descending — dead stock ranked by what it
  used to earn.

---

## 7 · Sheet 4 — Data Quality

Paste-link the `Quality` table. Add at the top:

```excel
=COUNTIFS(Quality[severity],"BLOCK",Quality[status],"FAIL") & " blocking rules failing"
```

Circulating an ops workbook without its quality tab is how a wrong number ends up in a leadership deck.

---

## 8 · Refresh

Re-run `.\run_pipeline.ps1`, then **Data → Refresh All**. Every card, pivot, chart and slicer updates —
nothing is rebuilt by hand.

**Save as `.xlsx`** (not `.xlsb`) so the Data Model and queries stay inspectable by reviewers.
