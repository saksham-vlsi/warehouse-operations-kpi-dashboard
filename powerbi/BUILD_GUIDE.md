# Power BI Build Guide

Builds the four-page report from the published marts in `outputs/`. Assumes Power BI Desktop
(free) and about 45 minutes. Run `.\run_pipeline.ps1` first.

---

## 1 · Load the data (Power Query)

**Home → Get Data → Text/CSV**, load these from `outputs/`:

| Query | File | Rows | Role |
|---|---|---:|---|
| `FactOrders` | `fact_orders_flat.csv` | 99,441 | Main fact |
| `FactOrderLine` | *(built below)* | 112,650 | Seller/dispatch grain |
| `DimSellerNode` | `warehouse_performance.csv` | 611 | Node scorecard |
| `SellerScorecard` | `seller_dispatch_scorecard.csv` | 894 | SLA bands |
| `RegionPerf` | `region_performance.csv` | 27 | Map + heatmap |
| `CategoryPerf` | `category_performance.csv` | 72 | Treemap |
| `ProductMovement` | `product_movement_abc.csv` | 32,951 | ABC / fast-slow |
| `LeadTimeDecomp` | `leadtime_decomposition.csv` | 25 | Leg trend |
| `DeliveryBands` | `delivery_band_csat.csv` | 6 | CSAT cliff |
| `LanePerf` | `lane_performance.csv` | 25 | Lane matrix |
| `PaymentPerf` | `payment_method_analysis.csv` | 5 | Payment split |
| `DataQuality` | `data_quality_report.csv` | 19 | Governance page |

### Power Query steps applied to `FactOrders`

In the Power Query Editor, with `FactOrders` selected:

1. **Set data types explicitly** — do not trust auto-detect.
   `purchase_date` → Date · `item_revenue`, `freight_cost`, `leg*_days`, `total_lead_days` → Decimal
   Number · `is_delivered`, `is_on_time`, `is_cancelled`, `promised_days`, `variance_days`,
   `review_score` → Whole Number · everything else → Text.
2. **Add Column → Conditional Column** named `Service Status`:
   `is_delivered = 0` → `"Not delivered"`, else `is_on_time = 1` → `"On time"`, else `"Late"`.
3. **Add Column → Custom Column** named `Revenue Band`:
   ```
   if [item_revenue] >= 500 then "High (500+)"
   else if [item_revenue] >= 150 then "Mid (150-500)"
   else "Low (<150)"
   ```
4. **Home → Remove Rows → Remove Blank Rows.**
5. Rename the query to `FactOrders` and **Close & Apply**.

> Keep every transform in Power Query rather than DAX calculated columns — it folds into the load,
> keeps the model small, and is what makes the refresh reproducible.

### Build `FactOrderLine`

Line-grain data is not exported flat by default (it would be a 112k-row duplicate of much of
`FactOrders`). Add it by appending this to `sql/03_kpi_marts.sql` and re-running the pipeline:

```sql
COPY (SELECT order_id, line_no, seller_id, category, revenue, freight_cost,
             seller_state, seller_region, customer_state, lane_type,
             is_dispatch_on_time, dispatch_slack_days, chargeable_weight_kg
      FROM fct_order_line)
TO 'outputs/fact_order_line_flat.csv' (HEADER, DELIMITER ',');
```

---

## 2 · Date table

**Modeling → New Table:**

```dax
DimDate =
ADDCOLUMNS (
    CALENDAR ( DATE ( 2016, 9, 1 ), DATE ( 2018, 12, 31 ) ),
    "Year",        YEAR ( [Date] ),
    "Month Num",   MONTH ( [Date] ),
    "Month",       FORMAT ( [Date], "MMM" ),
    "Year Month",  FORMAT ( [Date], "YYYY-MM" ),
    "Quarter",     "Q" & FORMAT ( [Date], "Q" ),
    "Day Name",    FORMAT ( [Date], "ddd" ),
    "Is Weekend",  IF ( WEEKDAY ( [Date], 2 ) >= 6, TRUE, FALSE )
)
```

Then **Table tools → Mark as date table → `Date`**. Sort `Month` by `Month Num`.
Without this, every time-intelligence measure in `measures.dax` returns wrong results.

---

## 3 · Relationships (star schema)

| From | To | Cardinality | Direction |
|---|---|---|---|
| `FactOrders[purchase_date]` | `DimDate[Date]` | Many-to-one | Single |
| `FactOrderLine[order_id]` | `FactOrders[order_id]` | Many-to-one | Single |
| `FactOrders[customer_state]` | `RegionPerf[customer_state]` | Many-to-one | Single |
| `FactOrderLine[category]` | `CategoryPerf[category]` | Many-to-one | Single |
| `FactOrderLine[seller_id]` | `SellerScorecard[seller_id]` | Many-to-one | Single |

Keep all directions **single**. Bi-directional filters on a model this shape create ambiguous paths and
silently wrong totals.

---

## 4 · Measures

Create a blank table (**Home → Enter Data**, name it `_Measures`, delete the column, Load), then paste
each measure from [`measures.dax`](measures.dax). Hide every raw numeric column on `FactOrders` once the
measures exist so report users can only pick correct aggregations.

---

## 5 · Page build

### Page 1 — Executive Dashboard

**KPI cards (row of 6):** `Total Orders` · `Revenue` · `On-Time Delivery %` · `Avg Delivery Days` ·
`Perfect Order Rate %` · `Avg CSAT`.
On the On-Time card, set **Format → Callout value → Colour → fx → Field value → `On-Time Status Colour`**
so it turns amber below 95 and red below 90.

| Visual | Type | Fields |
|---|---|---|
| Orders & revenue trend | Line and clustered column | Axis `DimDate[Year Month]` · Column `Total Orders` · Line `Revenue` |
| Service trend | Line chart | Axis `Year Month` · Values `On-Time Delivery %`, `On-Time % 3M Avg` |
| Order status mix | Donut | Legend `Service Status` · Values `Total Orders` |
| Orders by hour | Column chart | Axis `purchase_hour` · Values `Total Orders` |
| Header | Card | `Report Header` |

**Slicers (sync across all pages):** `DimDate[Year Month]` (between), `customer_region`,
`Service Status`, `primary_payment_type`.

### Page 2 — Warehouse Performance

| Visual | Type | Fields |
|---|---|---|
| Top 10 nodes | Clustered bar | Axis `fulfilment_node` · Value `fulfilment_efficiency_score` · Filter Top 10 by value |
| Bottom 10 nodes | Clustered bar | Same, Bottom 10 — use a red theme colour |
| Node detail | Table | node · orders · dispatch_on_time_pct · delivery_on_time_pct · avg_dispatch_days · avg_csat |
| Seller SLA mix | Stacked column | Axis `sla_band` · Values `order_lines`, `revenue` |
| Region orders | Filled map | Location `customer_state` (Data category = State or Province) · Colour saturation `On-Time Delivery %` |

On the node detail table apply **conditional formatting → Background colour** to
`dispatch_on_time_pct` (red 60 → green 100).

### Page 3 — Inventory & Assortment

| Visual | Type | Fields |
|---|---|---|
| Category revenue | Treemap | Group `category` · Values `revenue` |
| Fast vs slow movers | Clustered bar | Axis `movement_class` · Values count of `product_id` |
| ABC concentration | Line + column | Axis `revenue_rank` (binned) · Column `revenue` · Line `cum_revenue_pct` |
| Dormant SKUs | Card + table | `is_dormant_180d = 1` |
| Freight intensity | Scatter | X `freight_pct_of_revenue` · Y `avg_chargeable_kg` · Size `revenue` · Details `category` |

> Label this page **Assortment & Movement**, not "Stock Levels" — the source carries no stock-on-hand
> column. See `docs/02_data_dictionary.md → Known gaps`.

### Page 4 — Delivery Analysis

| Visual | Type | Fields |
|---|---|---|
| Lead-time decomposition | Stacked area | Axis `purchase_month` · Values `leg1_approval_days`, `leg2_dispatch_days`, `leg3_transit_days` |
| Delay trend | Line | Axis `Year Month` · Values `Delayed Deliveries`, `On-Time Delivery %` (secondary axis) |
| **CSAT cliff** | Line and clustered column | Axis `delivery_band` · Column `orders` · Line `avg_csat` and `pct_1_2_star` |
| Lane matrix heatmap | Matrix | Rows `seller_region` · Columns `customer_region` · Values `On-Time Delivery %` with background colour scale |
| Revenue at risk | Card | `Revenue at Risk (Late)` |
| Bottleneck | Card | `Bottleneck Leg` |

The CSAT-cliff visual is the one to lead with in any walkthrough — it converts a logistics metric into a
customer-outcome metric on a single chart.

### Page 5 — Data Quality (governance)

Table over `DataQuality` — `rule_id`, `severity`, `rule_name`, `failing_rows`, `status`. Conditional-format
`status` red on `FAIL`. Add a card: `COUNTROWS(FILTER(DataQuality, [severity]="BLOCK" && [status]="FAIL"))`.

Most dashboards hide their data quality. Showing it is the single fastest way to establish that the
numbers on the other four pages can be trusted.

---

## 6 · Polish

- **Theme:** View → Themes → Customize — one accent, a red/amber/green semantic set, white canvas.
- **Tooltips:** create a hidden tooltip page with node/lane detail; set page size to Tooltip.
- **Drill-through:** target page filtered by `fulfilment_node`, so any node in any bar chart drills to detail.
- **Bookmarks:** "Service view" / "Cost view" toggle on the executive page.
- **Performance:** hide unused columns, set `FactOrders` to Import, and avoid calculated columns —
  the model should load in under 5 seconds.

## 7 · Refresh

Re-run `.\run_pipeline.ps1`, then **Home → Refresh** in Power BI. Because every transform lives in
Power Query and every semantic in DAX, no visual needs rebuilding.
