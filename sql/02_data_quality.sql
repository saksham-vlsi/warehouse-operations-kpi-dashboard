-- =============================================================================
--  02_data_quality.sql   |   DATA QUALITY GATE
-- =============================================================================
--  Runs BEFORE any KPI is published. Every rule returns a row; severity BLOCK
--  means the number would be wrong if you ignored it.
--
--  This is the layer most portfolio projects skip -- and it is the reason the
--  headline numbers in this repo can be trusted. Three of these rules changed
--  the reported KPI (see docs/03_data_quality_findings.md).
-- =============================================================================

CREATE OR REPLACE TABLE dq_report AS
WITH checks AS (

    -- 1. Referential integrity -------------------------------------------------
    SELECT 'REF-01' AS rule_id, 'BLOCK' AS severity, 'Order lines with no parent order' AS rule_name,
           COUNT(*) AS failing_rows
    FROM raw_items i LEFT JOIN raw_orders o USING(order_id) WHERE o.order_id IS NULL

    UNION ALL SELECT 'REF-02','BLOCK','Order lines referencing a missing product',COUNT(*)
    FROM raw_items i LEFT JOIN raw_products p USING(product_id) WHERE p.product_id IS NULL

    UNION ALL SELECT 'REF-03','BLOCK','Order lines referencing a missing seller',COUNT(*)
    FROM raw_items i LEFT JOIN raw_sellers s USING(seller_id) WHERE s.seller_id IS NULL

    UNION ALL SELECT 'REF-04','WARN','Orders with no order lines (no revenue attached)',COUNT(*)
    FROM raw_orders o LEFT JOIN raw_items i USING(order_id) WHERE i.order_id IS NULL

    -- 2. Grain / duplication ---------------------------------------------------
    UNION ALL SELECT 'GRN-01','BLOCK','Duplicate order_id in orders (breaks order grain)',
           COUNT(*) FROM (SELECT order_id FROM raw_orders GROUP BY 1 HAVING COUNT(*)>1)

    UNION ALL SELECT 'GRN-02','BLOCK','Orders with >1 review (fans out CSAT joins)',
           COUNT(*) FROM (SELECT order_id FROM raw_reviews GROUP BY 1 HAVING COUNT(*)>1)

    -- 3. Timestamp logic -------------------------------------------------------
    UNION ALL SELECT 'TIM-01','BLOCK','Delivered before it was dispatched',COUNT(*)
    FROM raw_orders WHERE order_delivered_customer_date < order_delivered_carrier_date

    UNION ALL SELECT 'TIM-02','BLOCK','Dispatched before the order was approved',COUNT(*)
    FROM raw_orders WHERE order_delivered_carrier_date < order_approved_at

    UNION ALL SELECT 'TIM-03','BLOCK','Approved before it was purchased',COUNT(*)
    FROM raw_orders WHERE order_approved_at < order_purchase_timestamp

    -- 4. Completeness on the critical path -------------------------------------
    UNION ALL SELECT 'CMP-01','BLOCK','Status=delivered but no delivery timestamp',COUNT(*)
    FROM raw_orders WHERE order_status='delivered' AND order_delivered_customer_date IS NULL

    UNION ALL SELECT 'CMP-02','WARN','Missing payment approval timestamp',COUNT(*)
    FROM raw_orders WHERE order_approved_at IS NULL

    UNION ALL SELECT 'CMP-03','WARN','Missing carrier handover timestamp',COUNT(*)
    FROM raw_orders WHERE order_delivered_carrier_date IS NULL

    UNION ALL SELECT 'CMP-04','WARN','Product rows with no category assigned',COUNT(*)
    FROM raw_products WHERE product_category_name IS NULL

    UNION ALL SELECT 'CMP-05','WARN','Products with zero/NULL weight (breaks freight-per-kg)',COUNT(*)
    FROM raw_products WHERE product_weight_g IS NULL OR product_weight_g = 0

    -- 5. Value sanity ----------------------------------------------------------
    UNION ALL SELECT 'VAL-01','BLOCK','Negative or zero item price',COUNT(*)
    FROM raw_items WHERE price <= 0

    UNION ALL SELECT 'VAL-02','WARN','Zero freight charged on a physical shipment',COUNT(*)
    FROM raw_items WHERE freight_value = 0

    UNION ALL SELECT 'VAL-03','WARN','Review score outside 1-5',COUNT(*)
    FROM raw_reviews WHERE review_score NOT BETWEEN 1 AND 5

    -- 6. Business-rule outliers ------------------------------------------------
    UNION ALL SELECT 'BIZ-01','WARN','Delivery lead time > 100 days (tail outliers)',COUNT(*)
    FROM fct_order WHERE total_lead_days > 100

    UNION ALL SELECT 'BIZ-02','WARN','Promise date earlier than the purchase date',COUNT(*)
    FROM fct_order WHERE promised_days < 0
)
SELECT rule_id, severity, rule_name, failing_rows,
       CASE WHEN failing_rows = 0 THEN 'PASS' ELSE 'FAIL' END AS status
FROM checks
ORDER BY CASE severity WHEN 'BLOCK' THEN 1 ELSE 2 END, failing_rows DESC;

COPY dq_report TO 'outputs/data_quality_report.csv' (HEADER, DELIMITER ',');

SELECT * FROM dq_report;
