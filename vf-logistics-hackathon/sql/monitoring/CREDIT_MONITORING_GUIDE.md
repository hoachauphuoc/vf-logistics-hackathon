# 💰 Credit Monitoring System - VF Logistics

## 📋 Overview

A real-time credit usage monitoring system has been deployed in the `MENDIX_APP.MONITORING` schema, with views and queries that auto-update from `SNOWFLAKE.ACCOUNT_USAGE`.

---

## 🎯 Quick Start - Key Queries

### 1. ⚡ Real-Time Credit Status (Recommended!)

```sql
-- Quick overview of last 24h, today, and 7 days
SELECT 
    '📊 ' || period as time_period,
    'Credits: ' || total_credits || ' ($' || estimated_cost_usd || ')' as usage
FROM (
    SELECT '24 Hours' as period, 
           ROUND(SUM(credits_used), 4) as total_credits,
           ROUND(SUM(credits_used) * 3.0, 2) as estimated_cost_usd,
           1 as sort_order
    FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_HISTORY
    WHERE start_time >= DATEADD(hour, -24, CURRENT_TIMESTAMP())
    
    UNION ALL
    SELECT 'Today', total_credits, estimated_cost_usd, 2
    FROM MENDIX_APP.MONITORING.V_CREDIT_SUMMARY_TODAY
    
    UNION ALL
    SELECT '7 Days', 
           ROUND(SUM(credits_used), 4),
           ROUND(SUM(credits_used) * 3.0, 2),
           3
    FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_HISTORY
    WHERE start_time >= DATEADD(day, -7, CURRENT_TIMESTAMP())
)
ORDER BY sort_order;
```

### 2. 📊 Today's Credit Breakdown

```sql
SELECT * FROM MENDIX_APP.MONITORING.V_CREDIT_SUMMARY_TODAY;
```

**Output columns:**
- `warehouse_credits` - Credits from warehouses (compute)
- `cloud_services_credits` - Credits from cloud services
- `serverless_credits` - Credits from serverless features
- `ai_ml_credits` - Credits from Cortex AI/ML
- `total_credits` - Total credits for today
- `estimated_cost_usd` - Estimated cost ($3/credit)

### 3. ⏰ Hourly Credit Trend (Last 24h)

```sql
SELECT 
    warehouse_name,
    usage_hour,
    total_credits,
    estimated_cost_usd
FROM MENDIX_APP.MONITORING.V_CREDIT_USAGE_REALTIME
WHERE warehouse_name = 'COMPUTE_WH'
ORDER BY usage_hour DESC
LIMIT 24;
```

### 4. 📈 Daily Cost Summary (Last 30 days)

```sql
SELECT 
    usage_date,
    warehouse_credits,
    cortex_ai_credits,
    total_credits,
    estimated_cost_usd,
    day_over_day_change_pct
FROM MENDIX_APP.MONITORING.V_DAILY_COST_SUMMARY
ORDER BY usage_date DESC
LIMIT 30;
```

### 5. 🔍 Service-Level Breakdown

```sql
SELECT 
    usage_date,
    service_type,
    service_name,
    credits_used,
    estimated_cost_usd
FROM MENDIX_APP.MONITORING.V_CREDIT_BY_SERVICE
WHERE usage_date >= CURRENT_DATE - 7
ORDER BY usage_date DESC, credits_used DESC;
```

---

## 📊 Available Views

### Core Views

| View Name | Description | Lookback Period |
|-----------|-------------|-----------------|
| `V_CREDIT_SUMMARY_TODAY` | Credit summary for today by service type | Today |
| `V_CREDIT_USAGE_REALTIME` | Hourly credit usage by warehouse | Last 24 hours |
| `V_CREDIT_USAGE_HOURLY` | Hourly aggregated usage with hour-of-day | Last 7 days |
| `V_DAILY_COST_SUMMARY` | Daily totals with day-over-day comparison | Last 30 days |
| `V_CREDIT_BY_SERVICE` | Service-level breakdown with cumulative | Last 30 days |

### History Table

| Table Name | Purpose |
|------------|---------|
| `CREDIT_USAGE_HISTORY` | Store snapshots for long-term trend analysis |

---

## 🚨 Alert Queries

### High Usage Alert (Hourly)

```sql
-- Alert if last hour > 5 credits
SELECT 
    'HOURLY ALERT' as alert_type,
    ROUND(SUM(credits_used), 4) as credits_last_hour,
    ROUND(SUM(credits_used) * 3.0, 2) as cost_usd,
    CASE 
        WHEN SUM(credits_used) > 10 THEN '🚨 CRITICAL'
        WHEN SUM(credits_used) > 5 THEN '⚠️ WARNING'
        ELSE '✅ NORMAL'
    END as severity
FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_HISTORY
WHERE start_time >= DATEADD(hour, -1, CURRENT_TIMESTAMP())
HAVING SUM(credits_used) > 5;
```

### Daily Budget Check

```sql
-- Alert if today > $100 (33.3 credits @ $3/credit)
SELECT 
    'DAILY BUDGET' as alert_type,
    total_credits,
    estimated_cost_usd,
    CASE 
        WHEN estimated_cost_usd > 100 THEN '🚨 OVER BUDGET'
        WHEN estimated_cost_usd > 75 THEN '⚠️ APPROACHING LIMIT'
        ELSE '✅ WITHIN BUDGET'
    END as status
FROM MENDIX_APP.MONITORING.V_CREDIT_SUMMARY_TODAY
WHERE estimated_cost_usd > 75;
```

---

## 📈 Visualization Queries (for Dashboards)

### 1. Credit Trend Chart (7 days)

```sql
SELECT 
    usage_date,
    warehouse_credits,
    cloud_services_credits,
    cortex_ai_credits,
    total_credits
FROM MENDIX_APP.MONITORING.V_DAILY_COST_SUMMARY
WHERE usage_date >= CURRENT_DATE - 7
ORDER BY usage_date;
```

### 2. Hour-of-Day Pattern (for optimization)

```sql
SELECT 
    hour_of_day,
    AVG(total_credits) as avg_credits,
    MAX(total_credits) as peak_credits
FROM MENDIX_APP.MONITORING.V_CREDIT_USAGE_HOURLY
WHERE usage_hour >= DATEADD(day, -7, CURRENT_TIMESTAMP())
GROUP BY hour_of_day
ORDER BY hour_of_day;
```

### 3. Service Type Pie Chart

```sql
SELECT 
    CASE 
        WHEN service_type = 'WAREHOUSE_METERING' THEN 'Compute (Warehouses)'
        WHEN service_type = 'CLOUD_SERVICES' THEN 'Cloud Services'
        WHEN service_type LIKE '%SERVERLESS%' THEN 'Serverless'
        WHEN service_type LIKE '%CORTEX%' THEN 'AI/ML (Cortex)'
        ELSE service_type
    END as category,
    ROUND(SUM(credits_used), 4) as total_credits,
    ROUND(SUM(credits_used) * 100.0 / 
          (SELECT SUM(credits_used) FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_HISTORY 
           WHERE start_time >= DATEADD(day, -7, CURRENT_TIMESTAMP())), 
          2) as percentage
FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_HISTORY
WHERE start_time >= DATEADD(day, -7, CURRENT_TIMESTAMP())
GROUP BY category
ORDER BY total_credits DESC;
```

---

## 🎯 Optimization Tips

### 1. Identify Peak Hours

```sql
SELECT 
    hour_of_day,
    day_of_week,
    AVG(total_credits) as avg_credits,
    COUNT(*) as sample_size
FROM MENDIX_APP.MONITORING.V_CREDIT_USAGE_HOURLY
GROUP BY hour_of_day, day_of_week
ORDER BY avg_credits DESC
LIMIT 10;
```

**Action**: Schedule heavy workloads during off-peak hours

### 2. Find Expensive Warehouses

```sql
SELECT 
    warehouse_name,
    SUM(total_credits) as total_credits_7d,
    ROUND(SUM(total_credits) * 3.0, 2) as cost_usd_7d,
    ROUND(AVG(total_credits), 4) as avg_credits_per_hour
FROM MENDIX_APP.MONITORING.V_CREDIT_USAGE_REALTIME
WHERE usage_hour >= DATEADD(day, -7, CURRENT_TIMESTAMP())
GROUP BY warehouse_name
ORDER BY total_credits_7d DESC;
```

**Action**: Right-size or consolidate warehouses

### 3. Check Auto-Suspend Effectiveness

```sql
-- Coming soon: Query warehouse idle time vs active time
```

---

## 📝 Best Practices

1. **Daily Check**: Run `V_CREDIT_SUMMARY_TODAY` every morning
2. **Weekly Review**: Check `V_DAILY_COST_SUMMARY` to spot trends
3. **Set Alerts**: Create tasks to auto-check thresholds
4. **Budget Planning**: Use historical data to forecast monthly cost
5. **Optimize Gen 2**: Ensure all warehouses use `STANDARD_GEN_2`

---

## 🔄 Automated Monitoring (Optional)

### Create a Monitoring Task

```sql
-- Task to capture hourly snapshots
CREATE OR REPLACE TASK MENDIX_APP.MONITORING.TASK_CAPTURE_CREDIT_SNAPSHOT
    WAREHOUSE = COMPUTE_WH
    SCHEDULE = '60 MINUTE'
AS
INSERT INTO MENDIX_APP.MONITORING.CREDIT_USAGE_HISTORY
SELECT 
    CURRENT_TIMESTAMP(),
    warehouse_name,
    total_credits,
    credits_compute,
    credits_cloud_services,
    0, -- query_count placeholder
    0, -- execution_time placeholder
    0, -- credits_per_query placeholder
    HOUR(CURRENT_TIMESTAMP()),
    DAYNAME(CURRENT_TIMESTAMP())
FROM MENDIX_APP.MONITORING.V_CREDIT_USAGE_REALTIME
WHERE usage_hour >= DATEADD(hour, -1, CURRENT_TIMESTAMP());

-- Resume task
ALTER TASK MENDIX_APP.MONITORING.TASK_CAPTURE_CREDIT_SNAPSHOT RESUME;
```

---

## 💡 Quick Reference

| Scenario | Query |
|----------|-------|
| "How much did I spend today?" | `SELECT * FROM V_CREDIT_SUMMARY_TODAY` |
| "What's my hourly burn rate?" | `SELECT * FROM V_CREDIT_USAGE_REALTIME ORDER BY usage_hour DESC LIMIT 1` |
| "Which warehouse costs the most?" | `SELECT warehouse_name, SUM(total_credits) FROM V_CREDIT_USAGE_REALTIME GROUP BY 1 ORDER BY 2 DESC` |
| "Am I over budget?" | See "Daily Budget Check" in the Alerts section |
| "Show me last 7 days trend" | `SELECT * FROM V_DAILY_COST_SUMMARY WHERE usage_date >= CURRENT_DATE - 7` |

---

## 📞 Support

For questions or issues with credit monitoring:
1. Check the `SNOWFLAKE.ACCOUNT_USAGE` schema documentation
2. Verify the views are created in `MENDIX_APP.MONITORING`
3. Ensure the ACCOUNTADMIN role has access to ACCOUNT_USAGE

**Note**: `ACCOUNT_USAGE` views have latency (up to 3 hours), so very recent usage may not appear immediately.

---

Generated by Cortex Code for the VF Logistics Project
Last Updated: 2026-07-23
