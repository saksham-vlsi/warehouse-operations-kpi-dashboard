# Data Dictionary

## Source system

Eight CSV extracts from a Brazilian marketplace platform (Olist), covering Sep 2016 – Oct 2018.
Real transactional data, published under CC BY-NC-SA 4.0.

| File | Grain | Rows | Role |
|---|---|---:|---|
| `olist_orders_dataset.csv` | order | 99,441 | Order lifecycle timestamps — the spine |
| `olist_order_items_dataset.csv` | order line | 112,650 | Price, freight, seller, dispatch deadline |
| `olist_products_dataset.csv` | product | 32,951 | Category, weight, dimensions |
| `olist_sellers_dataset.csv` | seller | 3,095 | Origin city/state — the fulfilment node |
| `olist_customers_dataset.csv` | customer | 99,441 | Destination city/state |
| `olist_order_payments_dataset.csv` | payment | 103,886 | Method, instalments, value |
| `olist_order_reviews_dataset.csv` | review | 105,764 | 1–5 score — the CSAT signal |
| `product_category_name_translation.csv` | category | 71 | PT → EN category names |

---

## The five timestamps that drive everything

`olist_orders_dataset` carries the complete order lifecycle. Every service metric in this project is
derived from the gaps between these five columns.

| Column | Meaning | Owned by |
|---|---|---|
| `order_purchase_timestamp` | Customer places the order | — |
| `order_approved_at` | Payment cleared | Payments |
| `order_delivered_carrier_date` | Seller hands the parcel to the carrier | **Seller / fulfilment node** |
| `order_delivered_customer_date` | Parcel reaches the customer | **Carrier** |
| `order_estimated_delivery_date` | Date promised to the customer at checkout | Planning |

**Lead-time decomposition** — the analytical core of the project:

```
purchase ──leg1──▶ approved ──leg2──▶ carrier handover ──leg3──▶ delivered
         approval          dispatch                     transit
        (payments)      (seller/node)                  (carrier)
```

Splitting total lead time this way is what allows the March 2018 collapse to be attributed to transit
rather than to sellers. Without it, "deliveries are late" is unactionable.

The sixth critical column lives on the order line:

| Column | Meaning |
|---|---|
| `shipping_limit_date` | The seller's **contractual** handover deadline for that line |

This is a genuine SLA present in the source data. Comparing `order_delivered_carrier_date` against it
gives a real seller dispatch-compliance measure rather than a derived proxy.

---

## Model layer

### `fct_order` — 99,441 rows, one per order

| Column | Type | Definition |
|---|---|---|
| `order_id` | text | Primary key |
| `order_status` | text | `delivered` / `shipped` / `canceled` / `unavailable` / `invoiced` / `processing` / `created` / `approved` |
| `purchase_date`, `purchase_month`, `purchase_hour` | date/text/int | Calendar attributes |
| `payment_approval_days` | decimal | Leg 1 — purchase → approved |
| `dispatch_days` | decimal | Leg 2 — approved → carrier handover |
| `transit_days` | decimal | Leg 3 — handover → customer |
| `total_lead_days` | decimal | Purchase → customer |
| `promised_days` | int | Purchase → promised date (date grain) |
| `variance_days` | int | Promised → actual. **Negative = early** |
| `promise_buffer_days` | int | Actual → promised. **Positive = unused buffer** |
| `is_delivered` / `is_cancelled` / `is_unavailable` | 0/1 | Status flags |
| `is_on_time` | 0/1 | Delivered on or before the promised **date** |
| `line_count`, `units`, `item_revenue`, `freight_cost`, `order_value` | numeric | Basket rollup |
| `actual_weight_kg`, `volumetric_weight_kg`, `chargeable_weight_kg` | decimal | Freight basis |
| `primary_payment_type`, `max_installments`, `payment_value` | mixed | Dominant payment method by value |
| `review_score` | int | 1–5, de-duplicated to the latest review per order |
| `customer_state`, `customer_region`, `customer_city` | text | Destination |

### `fct_order_line` — 112,650 rows, one per order line

Adds the seller dimension and the dispatch SLA:

| Column | Definition |
|---|---|
| `seller_id`, `seller_city`, `seller_state`, `seller_region` | Fulfilment node |
| `revenue`, `freight_cost`, `line_value` | Line economics |
| `freight_ratio` | `freight_cost / revenue` |
| `dispatch_deadline_ts` | `shipping_limit_date` — the contractual deadline |
| `dispatch_slack_days` | Handover minus deadline. **Negative = met the SLA** |
| `is_dispatch_on_time` | 0/1 against `shipping_limit_date` |
| `freight_per_chargeable_kg` | Freight normalised by billable weight |
| `lane`, `lane_region`, `lane_type` | `seller_state → customer_state`; `Intra-State` / `Intra-Region` / `Inter-Region` |
| `category` | English category name |

### Derived weight columns

Freight is billed on whichever is greater — actual or volumetric weight:

```
volumetric_weight_kg = (length_cm × height_cm × width_cm) / 5000
chargeable_weight_kg = GREATEST(actual_weight_kg, volumetric_weight_kg)
```

5000 is the standard industry dim-weight divisor for road freight. `category_performance.csv` reports
`pct_dim_weight_billed` — the share of lines where volumetric weight exceeds actual, i.e. where the
business is paying to ship air.

### Region rollup

Brazilian states are grouped into five macro-regions so lane analysis has a hierarchy:

| Region | States |
|---|---|
| Southeast | SP, RJ, MG, ES |
| South | PR, SC, RS |
| Central-West | MT, MS, GO, DF |
| Northeast | BA, SE, AL, PE, PB, RN, CE, PI, MA |
| North | AM, PA, AC, RO, RR, AP, TO |

---

## Mappings and their justification

The project brief specifies fields that a marketplace feed does not carry under those names. Each
mapping below is a documented modelling decision, not a silent substitution.

| Brief field | Mapped to | Justification |
|---|---|---|
| **Warehouse ID** | `seller_city, seller_state` (fulfilment node) | This is a marketplace — shipments originate from seller locations, which *are* the fulfilment nodes. 3,095 nodes; 611 carry ≥50 orders. |
| **Order Status** | `order_status` | Direct. Pending = `processing` + `approved` + `invoiced` + `created` + `shipped`. |
| **Delivery Date** | `order_delivered_customer_date` | Direct. |
| **Quantity** | Order-line count per order | Each line is one unit in this feed; `units` = `line_count`. |
| **Region** | `customer_state` → macro-region | Direct, with rollup. |
| **Customer Satisfaction** | `review_score` (1–5) | Direct, real. |

## Known gaps

| Brief field | Status | What is done instead |
|---|---|---|
| **Inventory Level** | Not in source | Movement-based assortment health only (fast/slow movers, ABC, dormancy). True stock KPIs are built in the companion Inventory & Supply Chain Analytics project, on a dataset that carries stock positions. |
| **Delivery Partner** | Not in source | Carrier performance measured via `transit_days` and by lane, not by named partner. |
| **Return Status** | Not in source | 1–2★ reviews used as a **dissatisfaction** signal, explicitly labelled. Never reported as a return rate. |
| **Damaged Orders** | Not in source | Not reported. |

Reporting a metric the data cannot support would be worse than reporting the gap.
