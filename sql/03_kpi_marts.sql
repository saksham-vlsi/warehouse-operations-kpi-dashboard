-- =============================================================================
--  03_kpi_marts.sql   |   PUBLISHED KPI MARTS  ->  outputs/*.csv
-- =============================================================================
--  One mart per dashboard page. Every file written here is what Power BI /
--  Excel consume, so the semantics are fixed HERE, not in a DAX measure.
--
--  DATA-QUALITY HANDLING (from 02_data_quality.sql):
--    * 1,359 orders have dispatch_ts < approved_ts and 23 have delivered_ts <
--      dispatch_ts -- physically impossible sequences. They are EXCLUDED from
--      lead-time decomposition (is_leadtime_valid=0) but RETAINED for volume,
--      revenue and on-time counting, because the purchase/delivery/promise
--      dates on those rows are still sound. Dropping them entirely would
--      understate order volume by 1.4%.
--    * Reviews were de-duplicated to the latest per order in 01_build_model.sql.
-- =============================================================================

CREATE OR REPLACE VIEW v_order AS
SELECT *,
    CASE WHEN payment_approval_days >= 0
          AND dispatch_days         >= 0
          AND transit_days          >= 0
          AND total_lead_days BETWEEN 0 AND 100
         THEN 1 ELSE 0 END AS is_leadtime_valid,
    -- Delay severity buckets: the CSAT cliff sits between these bands
    CASE WHEN is_delivered = 0            THEN 'Not delivered'
         WHEN variance_days <= -10        THEN 'Very early (>10d)'
         WHEN variance_days <=  -3        THEN 'Early (3-10d)'
         WHEN variance_days <=   0        THEN 'On time (0-3d)'
         WHEN variance_days <=   3        THEN 'Late 1-3d'
         WHEN variance_days <=   7        THEN 'Late 4-7d'
         ELSE                                  'Late >7d' END AS delivery_band
FROM fct_order;

-- =============================================================================
--  PAGE 1 -- EXECUTIVE DASHBOARD
-- =============================================================================
COPY (
SELECT
    COUNT(*)                                                            AS total_orders,
    SUM(is_delivered)                                                   AS completed_orders,
    SUM(is_cancelled)                                                   AS cancelled_orders,
    SUM(CASE WHEN order_status IN ('processing','approved','invoiced','created','shipped')
             THEN 1 ELSE 0 END)                                         AS pending_orders,
    SUM(is_unavailable)                                                 AS unavailable_orders,

    ROUND(SUM(item_revenue), 2)                                         AS total_revenue,
    ROUND(SUM(freight_cost), 2)                                         AS total_freight_cost,
    ROUND(SUM(item_revenue) / NULLIF(COUNT(*),0), 2)                    AS avg_order_value,
    SUM(units)                                                          AS total_units,

    ROUND(100.0 * SUM(is_delivered)      / COUNT(*), 2)                 AS delivery_success_rate_pct,
    ROUND(100.0 * SUM(is_on_time)        / NULLIF(SUM(is_delivered),0), 2) AS on_time_delivery_pct,
    SUM(is_delivered) - SUM(is_on_time)                                 AS delayed_deliveries,
    ROUND(AVG(CASE WHEN is_leadtime_valid=1 THEN total_lead_days END), 2)  AS avg_delivery_days,
    ROUND(AVG(CASE WHEN is_delivered=1 THEN promised_days END), 2)         AS avg_promised_days,
    ROUND(AVG(CASE WHEN is_delivered=1 THEN promise_buffer_days END), 2)   AS avg_promise_buffer_days,

    ROUND(AVG(review_score), 3)                                         AS avg_csat,
    ROUND(100.0 * AVG(CASE WHEN review_score <= 2 THEN 1.0 ELSE 0 END), 2) AS detractor_rate_pct,
    ROUND(100.0 * AVG(CASE WHEN review_score >= 4 THEN 1.0 ELSE 0 END), 2) AS promoter_rate_pct,

    -- Perfect Order Rate: delivered AND on time AND customer did not complain
    ROUND(100.0 * SUM(CASE WHEN is_on_time=1 AND COALESCE(review_score,5) >= 4
                           THEN 1 ELSE 0 END) / COUNT(*), 2)            AS perfect_order_rate_pct,

    COUNT(DISTINCT customer_state)                                      AS states_served,
    MIN(purchase_date) AS window_start, MAX(purchase_date) AS window_end
FROM v_order
) TO 'outputs/kpi_executive.csv' (HEADER, DELIMITER ',');

-- Monthly trend ---------------------------------------------------------------
COPY (
SELECT purchase_month,
       COUNT(*)                                                             AS orders,
       SUM(is_delivered)                                                    AS delivered,
       SUM(is_cancelled)                                                    AS cancelled,
       ROUND(SUM(item_revenue),2)                                           AS revenue,
       ROUND(SUM(freight_cost),2)                                           AS freight,
       ROUND(100.0*SUM(is_on_time)/NULLIF(SUM(is_delivered),0),2)           AS on_time_pct,
       SUM(is_delivered)-SUM(is_on_time)                                    AS delayed_deliveries,
       ROUND(AVG(CASE WHEN is_leadtime_valid=1 THEN total_lead_days END),2) AS avg_delivery_days,
       ROUND(AVG(CASE WHEN is_leadtime_valid=1 THEN payment_approval_days END),2) AS leg1_approval_days,
       ROUND(AVG(CASE WHEN is_leadtime_valid=1 THEN dispatch_days END),2)   AS leg2_dispatch_days,
       ROUND(AVG(CASE WHEN is_leadtime_valid=1 THEN transit_days END),2)    AS leg3_transit_days,
       ROUND(AVG(CASE WHEN is_delivered=1 THEN promised_days END),2)        AS avg_promised_days,
       ROUND(AVG(CASE WHEN is_delivered=1 THEN promise_buffer_days END),2)  AS avg_buffer_days,
       ROUND(AVG(review_score),3)                                           AS avg_csat
FROM v_order GROUP BY 1 ORDER BY 1
) TO 'outputs/kpi_monthly.csv' (HEADER, DELIMITER ',');

-- Daily operating rhythm -------------------------------------------------------
COPY (
SELECT purchase_date, COUNT(*) AS orders, ROUND(SUM(item_revenue),2) AS revenue,
       SUM(is_delivered) AS delivered,
       ROUND(100.0*SUM(is_on_time)/NULLIF(SUM(is_delivered),0),2) AS on_time_pct
FROM v_order GROUP BY 1 ORDER BY 1
) TO 'outputs/kpi_daily.csv' (HEADER, DELIMITER ',');

-- Intraday order profile (staffing / shift planning) ---------------------------
COPY (
SELECT purchase_hour, COUNT(*) AS orders,
       ROUND(100.0*COUNT(*)/SUM(COUNT(*)) OVER (),2) AS pct_of_orders
FROM v_order GROUP BY 1 ORDER BY 1
) TO 'outputs/orders_by_hour.csv' (HEADER, DELIMITER ',');

-- =============================================================================
--  PAGE 2 -- WAREHOUSE / FULFILMENT NODE PERFORMANCE
--  A fulfilment node = the origin city+state a shipment is picked, packed and
--  handed to the carrier from. See docs/02_data_dictionary.md for the mapping.
-- =============================================================================
COPY (
WITH node AS (
  SELECT l.seller_city || ', ' || l.seller_state AS fulfilment_node,
         l.seller_state, l.seller_region,
         COUNT(DISTINCT l.order_id)                                        AS orders,
         COUNT(*)                                                          AS order_lines,
         COUNT(DISTINCT l.seller_id)                                       AS sellers_at_node,
         ROUND(SUM(l.revenue),2)                                           AS revenue,
         ROUND(SUM(l.freight_cost),2)                                      AS freight,
         ROUND(100.0*AVG(l.is_dispatch_on_time),2)                         AS dispatch_on_time_pct,
         ROUND(100.0*AVG(CASE WHEN l.is_delivered=1 THEN l.is_on_time END),2) AS delivery_on_time_pct,
         ROUND(AVG(l.dispatch_days),2)                                     AS avg_dispatch_days,
         ROUND(AVG(l.transit_days),2)                                      AS avg_transit_days,
         ROUND(AVG(l.total_lead_days),2)                                   AS avg_lead_days,
         ROUND(AVG(l.review_score),3)                                      AS avg_csat
  FROM fct_order_line l
  WHERE l.seller_state IS NOT NULL
  GROUP BY 1,2,3
)
SELECT *,
       -- Fulfilment efficiency: blended dispatch reliability + delivery outcome
       ROUND(0.5*COALESCE(dispatch_on_time_pct,0) + 0.5*COALESCE(delivery_on_time_pct,0),2) AS fulfilment_efficiency_score,
       RANK() OVER (ORDER BY 0.5*COALESCE(dispatch_on_time_pct,0)+0.5*COALESCE(delivery_on_time_pct,0) DESC) AS efficiency_rank
FROM node WHERE orders >= 50 ORDER BY fulfilment_efficiency_score DESC
) TO 'outputs/warehouse_performance.csv' (HEADER, DELIMITER ',');

-- =============================================================================
--  PAGE 2b -- REGION / STATE PERFORMANCE  (map + heatmap source)
-- =============================================================================
COPY (
SELECT customer_state, customer_region,
       COUNT(*)                                                            AS orders,
       ROUND(SUM(item_revenue),2)                                          AS revenue,
       ROUND(SUM(freight_cost),2)                                          AS freight,
       ROUND(100.0*SUM(freight_cost)/NULLIF(SUM(item_revenue),0),2)        AS freight_pct_of_revenue,
       ROUND(100.0*SUM(is_on_time)/NULLIF(SUM(is_delivered),0),2)          AS on_time_pct,
       SUM(is_delivered)-SUM(is_on_time)                                   AS delayed_deliveries,
       ROUND(AVG(CASE WHEN is_leadtime_valid=1 THEN total_lead_days END),2)AS avg_delivery_days,
       ROUND(AVG(CASE WHEN is_leadtime_valid=1 THEN transit_days END),2)   AS avg_transit_days,
       ROUND(AVG(CASE WHEN is_delivered=1 THEN promised_days END),2)       AS avg_promised_days,
       ROUND(AVG(review_score),3)                                          AS avg_csat
FROM v_order WHERE customer_state IS NOT NULL
GROUP BY 1,2 ORDER BY orders DESC
) TO 'outputs/region_performance.csv' (HEADER, DELIMITER ',');

-- Lane analysis (origin region -> destination region) ---------------------------
COPY (
SELECT lane_region, lane_type,
       COUNT(*) AS order_lines,
       ROUND(SUM(revenue),2) AS revenue,
       ROUND(SUM(freight_cost),2) AS freight,
       ROUND(100.0*SUM(freight_cost)/NULLIF(SUM(revenue),0),2) AS freight_pct_of_revenue,
       ROUND(AVG(total_lead_days),2) AS avg_lead_days,
       ROUND(AVG(transit_days),2) AS avg_transit_days,
       ROUND(100.0*AVG(CASE WHEN is_delivered=1 THEN is_on_time END),2) AS on_time_pct
FROM fct_order_line WHERE seller_region IS NOT NULL AND customer_region IS NOT NULL
GROUP BY 1,2 HAVING COUNT(*) >= 100 ORDER BY order_lines DESC
) TO 'outputs/lane_performance.csv' (HEADER, DELIMITER ',');

-- =============================================================================
--  PAGE 3 -- INVENTORY / ASSORTMENT ANALYSIS
--  NOTE: the source extract carries no stock-on-hand column (see
--  docs/02_data_dictionary.md, "Known gaps"). This page therefore reports
--  MOVEMENT-based assortment health -- fast/slow movers, ABC concentration and
--  dormancy -- which is what is genuinely derivable. True stock-level KPIs
--  (turnover, days-of-cover, safety stock) are built in Project 2, on a dataset
--  that actually carries inventory positions.
-- =============================================================================
COPY (
WITH sku AS (
  SELECT l.product_id, l.category,
         COUNT(*)                                    AS units_sold,
         COUNT(DISTINCT l.order_id)                  AS orders,
         ROUND(SUM(l.revenue),2)                     AS revenue,
         MIN(l.purchase_date)                        AS first_sale,
         MAX(l.purchase_date)                        AS last_sale,
         date_diff('day', MAX(l.purchase_date), (SELECT MAX(purchase_date) FROM fct_order)) AS days_since_last_sale,
         ROUND(AVG(l.revenue),2)                     AS avg_selling_price
  FROM fct_order_line l GROUP BY 1,2
), ranked AS (
  SELECT *,
         SUM(revenue) OVER (ORDER BY revenue DESC ROWS UNBOUNDED PRECEDING)
           / SUM(revenue) OVER ()                    AS cum_revenue_share,
         ROW_NUMBER() OVER (ORDER BY revenue DESC)   AS revenue_rank
  FROM sku
)
SELECT product_id, category, units_sold, orders, revenue, avg_selling_price,
       first_sale, last_sale, days_since_last_sale, revenue_rank,
       ROUND(100.0*cum_revenue_share,2) AS cum_revenue_pct,
       CASE WHEN cum_revenue_share <= 0.80 THEN 'A'
            WHEN cum_revenue_share <= 0.95 THEN 'B' ELSE 'C' END AS abc_class,
       CASE WHEN units_sold >= 20 THEN 'Fast moving'
            WHEN units_sold >=  5 THEN 'Medium moving'
            WHEN units_sold >=  2 THEN 'Slow moving'
            ELSE 'Single-sale / dormant' END                     AS movement_class,
       CASE WHEN days_since_last_sale > 180 THEN 1 ELSE 0 END    AS is_dormant_180d
FROM ranked ORDER BY revenue DESC
) TO 'outputs/product_movement_abc.csv' (HEADER, DELIMITER ',');

-- Category performance ---------------------------------------------------------
COPY (
SELECT l.category,
       COUNT(DISTINCT l.product_id)                              AS active_skus,
       COUNT(*)                                                  AS units_sold,
       COUNT(DISTINCT l.order_id)                                AS orders,
       ROUND(SUM(l.revenue),2)                                   AS revenue,
       ROUND(100.0*SUM(l.revenue)/SUM(SUM(l.revenue)) OVER (),2) AS pct_of_revenue,
       ROUND(SUM(l.freight_cost),2)                              AS freight,
       ROUND(100.0*SUM(l.freight_cost)/NULLIF(SUM(l.revenue),0),2) AS freight_pct_of_revenue,
       ROUND(AVG(l.actual_weight_kg),3)                          AS avg_actual_kg,
       ROUND(AVG(l.volumetric_weight_kg),3)                      AS avg_volumetric_kg,
       ROUND(AVG(l.chargeable_weight_kg),3)                      AS avg_chargeable_kg,
       ROUND(100.0*AVG(CASE WHEN l.volumetric_weight_kg > l.actual_weight_kg THEN 1.0 ELSE 0 END),2) AS pct_dim_weight_billed,
       ROUND(AVG(l.total_lead_days),2)                           AS avg_lead_days,
       ROUND(100.0*AVG(CASE WHEN l.is_delivered=1 THEN l.is_on_time END),2) AS on_time_pct,
       ROUND(AVG(l.review_score),3)                              AS avg_csat
FROM fct_order_line l GROUP BY 1 ORDER BY revenue DESC
) TO 'outputs/category_performance.csv' (HEADER, DELIMITER ',');

-- =============================================================================
--  PAGE 4 -- DELIVERY ANALYSIS
-- =============================================================================
-- Delay attribution: which leg actually burned the promise?
COPY (
WITH base AS (
  SELECT purchase_month, delivery_band, variance_days,
         payment_approval_days, dispatch_days, transit_days, total_lead_days
  FROM v_order WHERE is_delivered=1 AND is_leadtime_valid=1
), norm AS (
  SELECT *,
    CASE WHEN total_lead_days > 0 THEN payment_approval_days/total_lead_days END AS sh_approval,
    CASE WHEN total_lead_days > 0 THEN dispatch_days        /total_lead_days END AS sh_dispatch,
    CASE WHEN total_lead_days > 0 THEN transit_days         /total_lead_days END AS sh_transit
  FROM base
)
SELECT purchase_month,
       COUNT(*) AS delivered_orders,
       ROUND(AVG(total_lead_days),2)      AS avg_lead_days,
       ROUND(AVG(payment_approval_days),2)AS leg1_approval_days,
       ROUND(AVG(dispatch_days),2)        AS leg2_dispatch_days,
       ROUND(AVG(transit_days),2)         AS leg3_transit_days,
       ROUND(100.0*AVG(sh_approval),1)    AS leg1_pct_of_leadtime,
       ROUND(100.0*AVG(sh_dispatch),1)    AS leg2_pct_of_leadtime,
       ROUND(100.0*AVG(sh_transit),1)     AS leg3_pct_of_leadtime,
       ROUND(AVG(CASE WHEN variance_days > 0 THEN transit_days END),2) AS transit_days_when_late,
       ROUND(AVG(CASE WHEN variance_days <=0 THEN transit_days END),2) AS transit_days_when_ontime
FROM norm GROUP BY 1 ORDER BY 1
) TO 'outputs/leadtime_decomposition.csv' (HEADER, DELIMITER ',');

-- Delivery band distribution + the CSAT cliff ----------------------------------
COPY (
SELECT delivery_band,
       COUNT(*)                                                        AS orders,
       ROUND(100.0*COUNT(*)/SUM(COUNT(*)) OVER (),2)                   AS pct_of_orders,
       ROUND(AVG(review_score),2)                                      AS avg_csat,
       ROUND(100.0*AVG(CASE WHEN review_score<=2 THEN 1.0 ELSE 0 END),1) AS pct_1_2_star,
       ROUND(100.0*AVG(CASE WHEN review_score>=4 THEN 1.0 ELSE 0 END),1) AS pct_4_5_star,
       ROUND(AVG(total_lead_days),2)                                   AS avg_lead_days,
       ROUND(SUM(item_revenue),2)                                      AS revenue_exposed
FROM v_order WHERE is_delivered=1 GROUP BY 1
ORDER BY CASE delivery_band WHEN 'Very early (>10d)' THEN 1 WHEN 'Early (3-10d)' THEN 2
                            WHEN 'On time (0-3d)' THEN 3 WHEN 'Late 1-3d' THEN 4
                            WHEN 'Late 4-7d' THEN 5 ELSE 6 END
) TO 'outputs/delivery_band_csat.csv' (HEADER, DELIMITER ',');

-- Seller dispatch SLA scorecard -------------------------------------------------
COPY (
WITH s AS (
  SELECT l.seller_id, ds.seller_state, ds.seller_city,
         COUNT(*)                              AS order_lines,
         ROUND(SUM(l.revenue),2)               AS revenue,
         ROUND(100.0*AVG(l.is_dispatch_on_time),2) AS dispatch_on_time_pct,
         ROUND(AVG(l.dispatch_slack_days),2)   AS avg_slack_days,
         ROUND(100.0*AVG(CASE WHEN l.is_delivered=1 THEN l.is_on_time END),2) AS delivery_on_time_pct,
         ROUND(AVG(l.review_score),3)          AS avg_csat
  FROM fct_order_line l JOIN dim_seller ds USING(seller_id)
  GROUP BY 1,2,3
)
SELECT *,
  CASE WHEN dispatch_on_time_pct >= 95 THEN 'A - Reliable'
       WHEN dispatch_on_time_pct >= 85 THEN 'B - Watch'
       WHEN dispatch_on_time_pct >= 70 THEN 'C - At risk'
       ELSE 'D - Breach' END AS sla_band
FROM s WHERE order_lines >= 20 ORDER BY dispatch_on_time_pct ASC, order_lines DESC
) TO 'outputs/seller_dispatch_scorecard.csv' (HEADER, DELIMITER ',');

-- Payment method vs fulfilment (approval friction) ------------------------------
COPY (
SELECT COALESCE(primary_payment_type,'unknown') AS payment_type,
       COUNT(*) AS orders,
       ROUND(100.0*COUNT(*)/SUM(COUNT(*)) OVER (),2) AS pct_of_orders,
       ROUND(AVG(CASE WHEN is_leadtime_valid=1 THEN payment_approval_days END)*24,2) AS avg_approval_hours,
       ROUND(100.0*SUM(is_on_time)/NULLIF(SUM(is_delivered),0),2) AS on_time_pct,
       ROUND(100.0*SUM(is_cancelled)/COUNT(*),2) AS cancellation_pct,
       ROUND(AVG(item_revenue),2) AS avg_order_value,
       ROUND(AVG(review_score),3) AS avg_csat
FROM v_order GROUP BY 1 ORDER BY orders DESC
) TO 'outputs/payment_method_analysis.csv' (HEADER, DELIMITER ',');

-- =============================================================================
--  FLAT EXPORT for Power BI / Excel Power Query
--  One wide, pre-joined table so the model can be built without re-deriving
--  anything. 99,441 rows.
-- =============================================================================
COPY (
SELECT order_id, purchase_date, purchase_month, purchase_hour, order_status,
       customer_state, customer_region, customer_city,
       line_count, units, item_revenue, freight_cost, order_value,
       chargeable_weight_kg, primary_payment_type, max_installments,
       is_delivered, is_cancelled, is_on_time, delivery_band,
       promised_days, variance_days, promise_buffer_days,
       CASE WHEN is_leadtime_valid=1 THEN ROUND(payment_approval_days,3) END AS leg1_approval_days,
       CASE WHEN is_leadtime_valid=1 THEN ROUND(dispatch_days,3) END         AS leg2_dispatch_days,
       CASE WHEN is_leadtime_valid=1 THEN ROUND(transit_days,3) END          AS leg3_transit_days,
       CASE WHEN is_leadtime_valid=1 THEN ROUND(total_lead_days,3) END       AS total_lead_days,
       review_score
FROM v_order ORDER BY purchase_date
) TO 'outputs/fact_orders_flat.csv' (HEADER, DELIMITER ',');

SELECT 'marts written' AS status;
