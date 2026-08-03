-- =============================================================================
--  01_build_model.sql   |   STAGING -> STAR SCHEMA
-- =============================================================================
--  Builds the analytical model from the raw marketplace extract.
--
--  Design principle: ALL date arithmetic is resolved HERE, into plain numeric
--  columns. Every downstream analysis script is then pure portable SQL with no
--  engine-specific date functions -- which is why the same analysis files run
--  unchanged on DuckDB and (with sql/mysql/ staging) on MySQL 8.
--
--  Grain:
--    dim_*            one row per entity
--    fct_order_line   one row per order line   (112,650)
--    fct_order        one row per order        ( 99,441)
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 0. Raw landing views (read straight off the CSV extract)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW raw_orders     AS SELECT * FROM read_csv_auto('data/raw/olist_orders_dataset.csv', header=true);
CREATE OR REPLACE VIEW raw_items      AS SELECT * FROM read_csv_auto('data/raw/olist_order_items_dataset.csv', header=true);
CREATE OR REPLACE VIEW raw_payments   AS SELECT * FROM read_csv_auto('data/raw/olist_order_payments_dataset.csv', header=true);
CREATE OR REPLACE VIEW raw_reviews    AS SELECT * FROM read_csv_auto('data/raw/olist_order_reviews_dataset.csv', header=true);
CREATE OR REPLACE VIEW raw_products   AS SELECT * FROM read_csv_auto('data/raw/olist_products_dataset.csv', header=true);
CREATE OR REPLACE VIEW raw_customers  AS SELECT * FROM read_csv_auto('data/raw/olist_customers_dataset.csv', header=true);
CREATE OR REPLACE VIEW raw_sellers    AS SELECT * FROM read_csv_auto('data/raw/olist_sellers_dataset.csv', header=true);
CREATE OR REPLACE VIEW raw_cat_trans  AS SELECT * FROM read_csv_auto('data/raw/product_category_name_translation.csv', header=true);

-- -----------------------------------------------------------------------------
-- 1. DIM_PRODUCT
--    Adds the two things the raw feed does not give you but freight is billed on:
--      volumetric_weight_kg = (L x W x H) / 5000   [industry dim-weight divisor]
--      chargeable_weight_kg = GREATEST(actual, volumetric)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE dim_product AS
SELECT
    p.product_id,
    COALESCE(t.product_category_name_english, p.product_category_name, 'unclassified') AS category,
    COALESCE(p.product_weight_g, 0) / 1000.0                                            AS actual_weight_kg,
    COALESCE(p.product_length_cm, 0)                                                    AS length_cm,
    COALESCE(p.product_height_cm, 0)                                                    AS height_cm,
    COALESCE(p.product_width_cm, 0)                                                     AS width_cm,
    (COALESCE(p.product_length_cm,0) * COALESCE(p.product_height_cm,0)
       * COALESCE(p.product_width_cm,0)) / 5000.0                                       AS volumetric_weight_kg,
    GREATEST(COALESCE(p.product_weight_g,0)/1000.0,
             (COALESCE(p.product_length_cm,0)*COALESCE(p.product_height_cm,0)
                *COALESCE(p.product_width_cm,0))/5000.0)                                AS chargeable_weight_kg,
    COALESCE(p.product_photos_qty, 0)                                                   AS photos_qty,
    COALESCE(p.product_description_lenght, 0)                                           AS description_length
FROM raw_products p
LEFT JOIN raw_cat_trans t ON p.product_category_name = t.product_category_name;

-- -----------------------------------------------------------------------------
-- 2. DIM_SELLER / DIM_CUSTOMER  (+ region rollup)
--    Brazilian states are grouped into macro-regions so lane analysis has a
--    meaningful hierarchy (the direct analogue of Flipkart's zone model).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE MACRO region_of(st) AS
  CASE
    WHEN st IN ('SP','RJ','MG','ES')                     THEN 'Southeast'
    WHEN st IN ('PR','SC','RS')                          THEN 'South'
    WHEN st IN ('MT','MS','GO','DF')                     THEN 'Central-West'
    WHEN st IN ('BA','SE','AL','PE','PB','RN','CE','PI','MA') THEN 'Northeast'
    WHEN st IN ('AM','PA','AC','RO','RR','AP','TO')      THEN 'North'
    ELSE 'Unknown'
  END;

CREATE OR REPLACE TABLE dim_seller AS
SELECT seller_id,
       LOWER(TRIM(seller_city))    AS seller_city,
       UPPER(TRIM(seller_state))   AS seller_state,
       region_of(UPPER(TRIM(seller_state))) AS seller_region,
       seller_zip_code_prefix
FROM raw_sellers;

CREATE OR REPLACE TABLE dim_customer AS
SELECT customer_id, customer_unique_id,
       LOWER(TRIM(customer_city))  AS customer_city,
       UPPER(TRIM(customer_state)) AS customer_state,
       region_of(UPPER(TRIM(customer_state))) AS customer_region,
       customer_zip_code_prefix
FROM raw_customers;

-- -----------------------------------------------------------------------------
-- 3. Order-level helper aggregates (payments, reviews)
--    Reviews are 1:N against orders in the raw feed -> keep the LATEST only,
--    otherwise CSAT joins fan out and silently inflate order counts.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE agg_payment AS
SELECT order_id,
       SUM(payment_value)                                             AS payment_value,
       MAX(payment_installments)                                      AS max_installments,
       -- dominant payment method by value
       ARG_MAX(payment_type, payment_value)                           AS primary_payment_type,
       COUNT(*)                                                       AS payment_records
FROM raw_payments
GROUP BY order_id;

CREATE OR REPLACE TABLE agg_review AS
SELECT order_id, review_score, review_creation_date
FROM (
    SELECT order_id, review_score, review_creation_date,
           ROW_NUMBER() OVER (PARTITION BY order_id
                              ORDER BY review_answer_timestamp DESC, review_creation_date DESC) AS rn
    FROM raw_reviews
) q
WHERE rn = 1;

-- -----------------------------------------------------------------------------
-- 4. FCT_ORDER  -- the control-tower spine
--
--    Lead time is decomposed into the three legs the business can actually own:
--      leg 1  payment_approval_days : purchase   -> approved        (payments)
--      leg 2  dispatch_days         : approved   -> carrier handover(seller/FC)
--      leg 3  transit_days          : handover   -> customer        (carrier)
--
--    ON-TIME is evaluated at DATE grain: an order delivered at any time on the
--    promised calendar day is on time. (estimated_delivery_date carries a
--    00:00:00 time component, so a timestamp comparison would wrongly fail
--    every same-day delivery.)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE fct_order AS
SELECT
    o.order_id,
    o.customer_id,
    o.order_status,
    o.order_purchase_timestamp                                              AS purchase_ts,
    o.order_approved_at                                                     AS approved_ts,
    o.order_delivered_carrier_date                                          AS dispatch_ts,
    o.order_delivered_customer_date                                         AS delivered_ts,
    o.order_estimated_delivery_date                                         AS promised_ts,

    CAST(o.order_purchase_timestamp AS DATE)                                AS purchase_date,
    strftime(o.order_purchase_timestamp, '%Y-%m')                           AS purchase_month,
    EXTRACT(year  FROM o.order_purchase_timestamp)                          AS purchase_year,
    EXTRACT(dow   FROM o.order_purchase_timestamp)                          AS purchase_dow,
    EXTRACT(hour  FROM o.order_purchase_timestamp)                          AS purchase_hour,

    -- ---- lead-time legs (fractional days, computed from hours) -------------
    date_diff('hour', o.order_purchase_timestamp,      o.order_approved_at)              / 24.0 AS payment_approval_days,
    date_diff('hour', o.order_approved_at,             o.order_delivered_carrier_date)   / 24.0 AS dispatch_days,
    date_diff('hour', o.order_delivered_carrier_date,  o.order_delivered_customer_date)  / 24.0 AS transit_days,
    date_diff('hour', o.order_purchase_timestamp,      o.order_delivered_customer_date)  / 24.0 AS total_lead_days,

    -- ---- promise & variance (whole days, date grain) ----------------------
    date_diff('day', CAST(o.order_purchase_timestamp AS DATE),
                     CAST(o.order_estimated_delivery_date AS DATE))                      AS promised_days,
    date_diff('day', CAST(o.order_estimated_delivery_date AS DATE),
                     CAST(o.order_delivered_customer_date AS DATE))                      AS variance_days,
    date_diff('day', CAST(o.order_delivered_customer_date AS DATE),
                     CAST(o.order_estimated_delivery_date AS DATE))                      AS promise_buffer_days,

    -- ---- service flags -----------------------------------------------------
    CASE WHEN o.order_status = 'delivered'
          AND o.order_delivered_customer_date IS NOT NULL THEN 1 ELSE 0 END              AS is_delivered,
    CASE WHEN o.order_status = 'canceled'    THEN 1 ELSE 0 END                           AS is_cancelled,
    CASE WHEN o.order_status = 'unavailable' THEN 1 ELSE 0 END                           AS is_unavailable,
    CASE WHEN o.order_status = 'delivered'
          AND o.order_delivered_customer_date IS NOT NULL
          AND CAST(o.order_delivered_customer_date AS DATE)
              <= CAST(o.order_estimated_delivery_date AS DATE) THEN 1 ELSE 0 END         AS is_on_time,

    -- ---- basket ------------------------------------------------------------
    li.line_count, li.units, li.item_revenue, li.freight_cost,
    li.item_revenue + li.freight_cost                                                    AS order_value,
    li.chargeable_weight_kg, li.actual_weight_kg, li.volumetric_weight_kg,
    li.distinct_sellers,

    pay.primary_payment_type, pay.max_installments, pay.payment_value,
    rev.review_score,

    c.customer_state, c.customer_region, c.customer_city
FROM raw_orders o
LEFT JOIN (
    SELECT i.order_id,
           COUNT(*)                                   AS line_count,
           COUNT(*)                                   AS units,
           SUM(i.price)                               AS item_revenue,
           SUM(i.freight_value)                       AS freight_cost,
           SUM(dp.chargeable_weight_kg)               AS chargeable_weight_kg,
           SUM(dp.actual_weight_kg)                   AS actual_weight_kg,
           SUM(dp.volumetric_weight_kg)               AS volumetric_weight_kg,
           COUNT(DISTINCT i.seller_id)                AS distinct_sellers
    FROM raw_items i
    LEFT JOIN dim_product dp ON i.product_id = dp.product_id
    GROUP BY i.order_id
) li            ON o.order_id = li.order_id
LEFT JOIN agg_payment  pay ON o.order_id = pay.order_id
LEFT JOIN agg_review   rev ON o.order_id = rev.order_id
LEFT JOIN dim_customer c   ON o.customer_id = c.customer_id;

-- -----------------------------------------------------------------------------
-- 5. FCT_ORDER_LINE -- line grain, carries the SELLER dispatch SLA
--    shipping_limit_date is the seller's contractual handover deadline: the
--    single most useful column in the extract, because it separates "the seller
--    was late" from "the carrier was slow".
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE fct_order_line AS
SELECT
    i.order_id,
    i.order_item_id                                                          AS line_no,
    i.product_id,
    i.seller_id,
    o.customer_id,
    o.order_status,
    o.purchase_date,
    o.purchase_month,
    i.price                                                                  AS revenue,
    i.freight_value                                                          AS freight_cost,
    i.price + i.freight_value                                                AS line_value,
    CASE WHEN i.price > 0 THEN i.freight_value / i.price END                 AS freight_ratio,

    i.shipping_limit_date                                                    AS dispatch_deadline_ts,
    o.dispatch_ts,
    date_diff('hour', i.shipping_limit_date, o.dispatch_ts) / 24.0           AS dispatch_slack_days,
    CASE WHEN o.dispatch_ts IS NULL THEN NULL
         WHEN o.dispatch_ts <= i.shipping_limit_date THEN 1 ELSE 0 END       AS is_dispatch_on_time,

    o.is_delivered, o.is_on_time, o.is_cancelled,
    o.total_lead_days, o.dispatch_days, o.transit_days, o.variance_days,
    o.review_score, o.primary_payment_type,

    dp.category, dp.actual_weight_kg, dp.volumetric_weight_kg, dp.chargeable_weight_kg,
    CASE WHEN dp.chargeable_weight_kg > 0
         THEN i.freight_value / dp.chargeable_weight_kg END                  AS freight_per_chargeable_kg,

    ds.seller_state, ds.seller_region, ds.seller_city,
    o.customer_state, o.customer_region,
    ds.seller_state || ' -> ' || o.customer_state                            AS lane,
    ds.seller_region || ' -> ' || o.customer_region                          AS lane_region,
    CASE WHEN ds.seller_state = o.customer_state THEN 'Intra-State'
         WHEN ds.seller_region = o.customer_region THEN 'Intra-Region'
         ELSE 'Inter-Region' END                                             AS lane_type
FROM raw_items i
JOIN fct_order  o  ON i.order_id  = o.order_id
LEFT JOIN dim_product dp ON i.product_id = dp.product_id
LEFT JOIN dim_seller  ds ON i.seller_id  = ds.seller_id;

-- -----------------------------------------------------------------------------
-- 6. DIM_DATE -- generated from the observed order window
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE dim_date AS
SELECT d                                        AS full_date,
       CAST(strftime(d,'%Y%m%d') AS INTEGER)    AS date_key,
       strftime(d,'%Y-%m')                      AS year_month,
       EXTRACT(year    FROM d)                  AS year,
       EXTRACT(month   FROM d)                  AS month_num,
       strftime(d,'%B')                         AS month_name,
       EXTRACT(quarter FROM d)                  AS quarter,
       EXTRACT(dow     FROM d)                  AS day_of_week,
       strftime(d,'%A')                         AS day_name,
       CASE WHEN EXTRACT(dow FROM d) IN (0,6) THEN 1 ELSE 0 END AS is_weekend
FROM (SELECT UNNEST(generate_series(DATE '2016-09-01', DATE '2018-12-31', INTERVAL 1 DAY)) AS d);

-- -----------------------------------------------------------------------------
-- 7. Build receipt
-- -----------------------------------------------------------------------------
SELECT 'dim_product'    AS table_name, COUNT(*) AS rows FROM dim_product
UNION ALL SELECT 'dim_seller',    COUNT(*) FROM dim_seller
UNION ALL SELECT 'dim_customer',  COUNT(*) FROM dim_customer
UNION ALL SELECT 'dim_date',      COUNT(*) FROM dim_date
UNION ALL SELECT 'fct_order',     COUNT(*) FROM fct_order
UNION ALL SELECT 'fct_order_line',COUNT(*) FROM fct_order_line
ORDER BY 1;
