# Metric Definitions

Every KPI published by this project, with its exact formula, its denominator, and the judgement calls
behind it. If two people compute "on-time delivery %" differently they will argue forever — this file
exists so that cannot happen.

---

## Order KPIs

| Metric | Formula | Denominator |
|---|---|---|
| Total Orders | `COUNT(order_id)` | — |
| Completed Orders | `SUM(is_delivered)` | — |
| Cancelled Orders | `SUM(is_cancelled)` where `order_status='canceled'` | — |
| Pending Orders | `order_status IN ('processing','approved','invoiced','created','shipped')` | — |
| Unavailable Orders | `order_status='unavailable'` | — |
| Delivery Success Rate | `SUM(is_delivered) / COUNT(*)` | All orders |
| Cancellation Rate | `SUM(is_cancelled) / COUNT(*)` | All orders |
| Average Order Value | `SUM(item_revenue) / COUNT(*)` | All orders. **Excludes freight** |

> `unavailable` is kept separate from `canceled`. They look similar but mean different things: cancelled
> is a customer/payment outcome, unavailable is a **supply** failure. Merging them hides a stock problem.

---

## Delivery KPIs

### On-Time Delivery %

```
on_time_delivery_pct = SUM(is_on_time) / SUM(is_delivered)

is_on_time = 1  WHEN order_status = 'delivered'
             AND order_delivered_customer_date IS NOT NULL
             AND CAST(order_delivered_customer_date AS DATE)
                 <= CAST(order_estimated_delivery_date AS DATE)
```

**Two decisions worth stating:**

1. **Date grain, not timestamp.** `order_estimated_delivery_date` carries a `00:00:00` time component.
   Comparing timestamps would mark an order promised for the 10th and delivered at 09:15 on the 10th as
   *late*. Every same-day delivery would fail. The comparison is therefore made on calendar date.

2. **Denominator is delivered orders, not all orders.** An order still in transit is not "late" — it has
   no outcome yet. Mixing undelivered orders into the denominator makes the metric drift with volume
   rather than with performance. Delivery *success* rate (over all orders) is reported separately so
   nothing is hidden.

| Metric | Formula |
|---|---|
| Delayed Deliveries | `SUM(is_delivered) - SUM(is_on_time)` |
| Average Delivery Time | `AVG(total_lead_days)` where `is_leadtime_valid = 1` |
| Average Promised Days | `AVG(promised_days)` over delivered orders |
| Promise Buffer | `AVG(promise_buffer_days)` — positive means delivered *before* promise |
| Delivery Variance | `variance_days` — negative early, positive late |

### Lead-time legs

```
leg1_approval_days = (order_approved_at            - order_purchase_timestamp)     / 24h
leg2_dispatch_days = (order_delivered_carrier_date - order_approved_at)            / 24h
leg3_transit_days  = (order_delivered_customer_date- order_delivered_carrier_date) / 24h
total_lead_days    = (order_delivered_customer_date- order_purchase_timestamp)     / 24h
```

Computed in hours then divided by 24 to preserve fractional days — `leg1` averages ~0.4 days, so whole-day
arithmetic would round the payments leg to zero and hide it entirely.

### `is_leadtime_valid`

```
is_leadtime_valid = 1 WHEN leg1 >= 0 AND leg2 >= 0 AND leg3 >= 0
                     AND total_lead_days BETWEEN 0 AND 100
```

1,382 orders in the real feed have physically impossible timestamp sequences (dispatch before approval,
or delivery before dispatch) and 64 have lead times beyond 100 days. These are **excluded from lead-time
averages** but **retained for volume, revenue and on-time counting**, because their purchase, delivery and
promise dates are still sound. Dropping them outright would understate order volume by 1.4%.

---

## Seller / node KPIs

### Dispatch On-Time % — the real SLA

```
is_dispatch_on_time = 1 WHEN order_delivered_carrier_date <= shipping_limit_date
dispatch_on_time_pct = AVG(is_dispatch_on_time)          -- order-line grain
dispatch_slack_days  = (order_delivered_carrier_date - shipping_limit_date) / 24h
```

`shipping_limit_date` is the seller's contractual handover deadline, present in the source data. This
separates *"the seller was slow"* from *"the carrier was slow"* — the distinction the whole delay
attribution rests on. Negative slack = SLA met.

### Fulfilment Efficiency Score

```
fulfilment_efficiency_score = 0.5 × dispatch_on_time_pct + 0.5 × delivery_on_time_pct
```

Deliberately blended. Ranking nodes on dispatch alone rewards a node that hands over on time into a
lane that always fails; ranking on delivery alone punishes a node for carrier problems it does not own.
Nodes with fewer than 50 orders are excluded from ranking — small samples produce meaningless 100%s.

### SLA bands

| Band | Dispatch on-time |
|---|---|
| A · Reliable | ≥ 95% |
| B · Watch | 85 – 95% |
| C · At risk | 70 – 85% |
| D · Breach | < 70% |

Applied only to sellers with ≥20 order lines.

---

## Customer KPIs

| Metric | Formula |
|---|---|
| Average CSAT | `AVG(review_score)`, 1–5 |
| Detractor Rate | `% of orders with review_score <= 2` |
| Promoter Rate | `% of orders with review_score >= 4` |

Reviews are de-duplicated to the **latest** per order before joining. 555 orders carry more than one
review in the raw feed; joining without de-duplication fans out the order grain and silently inflates
every count downstream.

### Perfect Order Rate

```
perfect_order_rate = COUNT(is_on_time = 1 AND COALESCE(review_score,5) >= 4) / COUNT(all orders)
```

A customer-outcome definition: the order arrived, it arrived on time, and the customer did not complain.
Orders without a review are given the benefit of the doubt (`COALESCE(...,5)`) — silence is not a
complaint. The denominator is **all** orders, so cancellations and unavailable stock correctly count
against it.

### Delivery bands

Used for the CSAT-cliff analysis:

| Band | `variance_days` |
|---|---|
| Very early | ≤ −10 |
| Early | −10 to −3 |
| On time | −3 to 0 |
| Late 1–3d | 0 to 3 |
| Late 4–7d | 3 to 7 |
| Late >7d | > 7 |

---

## Assortment KPIs

| Metric | Formula |
|---|---|
| ABC class | Cumulative revenue share: **A** ≤ 80%, **B** ≤ 95%, **C** remainder |
| Movement class | Units sold: Fast ≥ 20, Medium ≥ 5, Slow ≥ 2, else Single-sale/dormant |
| Dormant (180d) | No sale in the final 180 days of the window |
| Days Since Last Sale | `max(purchase_date in dataset) − max(purchase_date for SKU)` |

> These are **movement** metrics, not stock metrics. The source has no stock-on-hand column, so inventory
> turnover, days-of-cover and safety stock are deliberately **not** published here — see
> [`02_data_dictionary.md`](02_data_dictionary.md#known-gaps).

---

## Freight KPIs

| Metric | Formula |
|---|---|
| Freight % of Revenue | `SUM(freight_cost) / SUM(item_revenue)` |
| Volumetric Weight | `(L × H × W) / 5000` cm → kg |
| Chargeable Weight | `GREATEST(actual_weight_kg, volumetric_weight_kg)` |
| % Dim-Weight Billed | `% of lines where volumetric > actual` — the share paying to ship air |
| Freight per Chargeable Kg | `freight_cost / chargeable_weight_kg` |

---

## Conventions

- Percentages are stored as numbers out of 100 (`93.23`), not fractions, so Power BI cards need no
  extra formatting step.
- All currency is Brazilian Real (R$), the source currency. No FX conversion is applied.
- `NULLIF(...,0)` guards every denominator; a division by zero returns null, never a silent zero.
- Rankings exclude small samples (nodes <50 orders, sellers <20 lines, lanes <100 lines).
