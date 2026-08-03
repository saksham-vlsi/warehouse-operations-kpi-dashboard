# Business Problem

## Context

A marketplace fulfilment network moves ~100,000 orders through 3,095 origin nodes to 27 states. Orders
are picked and dispatched by sellers, handed to carriers, and delivered against a date promised to the
customer at checkout.

Operations leadership has plenty of raw data and almost no answers. The recurring failure is not a lack
of reporting — it is that reporting stops at *"deliveries were late this month"*, which nobody can act on.

## The questions this dashboard has to answer

1. **Are we hitting service?** On-time delivery, delivery success, cancellations, perfect orders — daily
   and monthly, with trend.
2. **When service breaks, which leg broke?** Payments, seller dispatch, or carrier transit. Without this,
   every incident produces the same generic escalation.
3. **Which fulfilment nodes are underperforming, and is it their fault?** A node handing over on time
   into a slow lane is not the same problem as a node missing its cut-off.
4. **What is poor service actually costing?** In revenue exposed and in customer satisfaction — not in
   abstract percentage points.
5. **Where is freight leaking?** Freight is the second-largest cost line after goods; it needs to be
   attributable to category and lane.

## Why the leg decomposition is the core of the design

The single design decision this project rests on is splitting total lead time into three separately-owned
legs:

```
purchase ──▶ approved ──▶ carrier handover ──▶ delivered
   payments      seller / fulfilment node        carrier
```

Aggregate lead time is a number you can only watch. Decomposed lead time is a number you can assign.
The March 2018 service collapse (on-time down to 81.0%) looks like a seller problem in aggregate; the
decomposition shows dispatch was *improving* while transit inflated 27%. Those two readings lead to
completely different, mutually exclusive corrective actions — and only one of them would have worked.

## Success criteria

| Criterion | Met |
|---|---|
| Every published KPI passes a documented quality gate before release | 19 rules, `outputs/data_quality_report.csv` |
| Service failures can be attributed to an owning function | Leg decomposition, `outputs/leadtime_decomposition.csv` |
| Node ranking is fair to nodes that do not own their lane | Blended fulfilment efficiency score |
| Cost of poor service is quantified, not asserted | R$ 985,924 revenue exposed; 3,317 excess detractors |
| Metrics the data cannot support are declared, not faked | `docs/02_data_dictionary.md` → Known gaps |

## Scope boundary

This project covers **outbound fulfilment and delivery performance**. Stock positions, replenishment and
supplier lead times are out of scope here because the source feed carries no inventory columns — those
are built in the companion project, *Inventory & Supply Chain Analytics*, on a dataset that does.
