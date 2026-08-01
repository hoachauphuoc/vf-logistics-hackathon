-- =====================================================
-- PHASE 4: SAP ERP INTEGRATION
-- =====================================================
-- VF_Logistics_Portal Database Expansion
-- Author: Data Engineering Team
-- Created: 2026-06-22
-- 
-- CRITICAL: This file follows Open-Closed Principle
-- ✅ EXTENDS Phase 1, 2, 3 (no modification to existing objects)
-- ✅ Links to Phase 1 via ShipmentRecord.ContainerNumber (FK)
-- ✅ Manages SAP synchronization queue and status tracking
-- =====================================================

-- =====================================================
-- STEP 1: CREATE PHASE 4 SCHEMA (if not exists)
-- =====================================================
CREATE SCHEMA IF NOT EXISTS VF_LOGISTICS_DB.PHASE4_SCHEMA
COMMENT = 'Phase 4: SAP ERP Integration & Financial Data Sync';

-- =====================================================
-- STEP 2: CREATE SAP_Sync_Queue TABLE
-- =====================================================
-- Queue for managing SAP synchronization operations
-- Links to Phase 1 ShipmentRecord for complete data context
-- =====================================================

CREATE OR REPLACE TABLE VF_LOGISTICS_DB.PHASE4_SCHEMA.SAP_Sync_Queue (
    -- Primary Key
    SyncID VARCHAR(50) PRIMARY KEY,
    
    -- Link to Phase 1 ShipmentRecord (Foreign Key)
    ContainerNumber VARCHAR(50) NOT NULL,
    
    -- Reference to other phases (optional)
    GateID VARCHAR(50),            -- From Phase 2
    WarehouseID VARCHAR(50),       -- From Phase 3
    
    -- SAP Document References
    SAP_MaterialDocument VARCHAR(20),   -- MIGO document number
    SAP_SalesOrder VARCHAR(20),
    SAP_DeliveryNote VARCHAR(20),
    SAP_InvoiceNumber VARCHAR(20),
    SAP_GoodsReceipt VARCHAR(20),
    SAP_ShipmentNumber VARCHAR(20),
    
    -- Sync Status
    SyncStatus VARCHAR(30) DEFAULT 'PENDING', 
    -- Values: PENDING, IN_PROGRESS, SUCCESS, FAILED, RETRY
    
    -- Error Tracking
    ErrorMessage VARCHAR(2000),
    ErrorCode VARCHAR(50),
    ErrorTimestamp TIMESTAMP_NTZ,
    
    -- Retry Logic
    AttemptCount NUMBER(3,0) DEFAULT 0,
    MaxRetryAttempts NUMBER(3,0) DEFAULT 3,
    LastAttempt TIMESTAMP_NTZ,
    NextRetryAt TIMESTAMP_NTZ,
    
    -- SAP API Details
    SAP_RFC_Function VARCHAR(100),      -- e.g., BAPI_GOODSMVT_CREATE
    SAP_OData_Endpoint VARCHAR(500),
    SAP_RequestPayload VARIANT,         -- JSON of request sent to SAP
    SAP_ResponsePayload VARIANT,        -- JSON of response from SAP
    SAP_System VARCHAR(20),             -- PRD, QAS, DEV
    
    -- Financial Data (from SAP response)
    InvoiceAmount NUMBER(15,2),
    Currency VARCHAR(3) DEFAULT 'VND',
    PaymentStatus VARCHAR(20),          -- PENDING, PAID, OVERDUE
    PaymentDueDate DATE,
    PaymentReceivedDate DATE,
    
    -- Zero-Copy SAP BDC Integration
    SAP_BDC_Connected BOOLEAN DEFAULT FALSE,
    SAP_BDC_LastRead TIMESTAMP_NTZ,
    SAP_BDC_Data VARIANT,              -- Historical data from SAP BDC
    
    -- Priority & Scheduling
    SyncPriority NUMBER(3,0) DEFAULT 5, -- 1=highest, 9=lowest
    ScheduledSyncTime TIMESTAMP_NTZ,
    ActualSyncTime TIMESTAMP_NTZ,
    
    -- Business Flags
    IsFullyIntegrated BOOLEAN DEFAULT FALSE,
    RequiresManualIntervention BOOLEAN DEFAULT FALSE,
    ManualInterventionReason VARCHAR(1000),
    
    -- Audit Fields
    CreatedAt TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    UpdatedAt TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    CreatedBy VARCHAR(100),
    UpdatedBy VARCHAR(100),
    
    -- Foreign Key Constraint
    CONSTRAINT FK_SAP_Sync_Queue_ShipmentRecord 
        FOREIGN KEY (ContainerNumber) 
        REFERENCES VF_LOGISTICS_DB.PHASE1_SCHEMA.ShipmentRecord(ContainerNumber)
);

-- Create Indexes for Performance
CREATE INDEX IF NOT EXISTS IDX_SAP_Sync_Queue_ContainerNumber 
    ON VF_LOGISTICS_DB.PHASE4_SCHEMA.SAP_Sync_Queue(ContainerNumber);

CREATE INDEX IF NOT EXISTS IDX_SAP_Sync_Queue_SyncStatus 
    ON VF_LOGISTICS_DB.PHASE4_SCHEMA.SAP_Sync_Queue(SyncStatus);

CREATE INDEX IF NOT EXISTS IDX_SAP_Sync_Queue_NextRetry 
    ON VF_LOGISTICS_DB.PHASE4_SCHEMA.SAP_Sync_Queue(NextRetryAt);

CREATE INDEX IF NOT EXISTS IDX_SAP_Sync_Queue_Priority 
    ON VF_LOGISTICS_DB.PHASE4_SCHEMA.SAP_Sync_Queue(SyncPriority, SyncStatus);

-- =====================================================
-- STEP 3: CREATE SAP_Integration_Log TABLE
-- =====================================================
-- Audit trail for all SAP sync attempts
-- =====================================================

CREATE OR REPLACE TABLE VF_LOGISTICS_DB.PHASE4_SCHEMA.SAP_Integration_Log (
    LogID VARCHAR(50) PRIMARY KEY,
    SyncID VARCHAR(50) NOT NULL,
    ContainerNumber VARCHAR(50) NOT NULL,
    
    -- Sync Attempt Details
    AttemptNumber NUMBER(3,0),
    AttemptTimestamp TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    AttemptStatus VARCHAR(30),         -- SUCCESS, FAILED
    
    -- Request/Response
    RequestPayload VARIANT,
    ResponsePayload VARIANT,
    ResponseTime_MS NUMBER(10,2),      -- API response time
    
    -- Error Details (if failed)
    ErrorMessage VARCHAR(2000),
    ErrorCode VARCHAR(50),
    
    -- SAP System Info
    SAP_System VARCHAR(20),
    SAP_User VARCHAR(100),
    SAP_RFC_Function VARCHAR(100),
    
    CreatedAt TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    
    -- Foreign Key
    CONSTRAINT FK_SAP_Integration_Log_SyncQueue 
        FOREIGN KEY (SyncID) 
        REFERENCES VF_LOGISTICS_DB.PHASE4_SCHEMA.SAP_Sync_Queue(SyncID)
);

-- =====================================================
-- STEP 4: CREATE VIEW - Complete SAP Sync Status
-- =====================================================
-- Combines Phase 1-4 data for end-to-end visibility
-- =====================================================

CREATE OR REPLACE VIEW VF_LOGISTICS_DB.PHASE4_SCHEMA.V_SAP_Sync_Complete AS
SELECT 
    -- SAP Sync Info
    sap.SyncID,
    sap.SyncStatus,
    sap.SyncPriority,
    sap.AttemptCount,
    sap.MaxRetryAttempts,
    sap.LastAttempt,
    sap.NextRetryAt,
    sap.ErrorMessage,
    sap.IsFullyIntegrated,
    
    -- SAP Documents
    sap.SAP_MaterialDocument,
    sap.SAP_InvoiceNumber,
    sap.InvoiceAmount,
    sap.Currency,
    sap.PaymentStatus,
    
    -- Phase 1 Shipment Info (READ-ONLY)
    s.ContainerNumber,
    s.BL_Number,
    s.Shipper,
    s.Consignee,
    s.Vessel,
    s.ETD,
    s.ETA,
    
    -- Phase 2 Gate Info (if available)
    g.PlateNumber,
    g.InTime AS GateInTime,
    g.OutTime AS GateOutTime,
    
    -- Phase 3 Warehouse Info (if available)
    w.WarehouseCode,
    w.SlotNumber,
    w.Status AS WarehouseStatus,
    
    -- Business Logic: End-to-End Processing Time
    DATEDIFF(HOUR, g.InTime, sap.ActualSyncTime) AS TotalProcessingHours,
    
    -- Business Logic: Sync Health
    CASE 
        WHEN sap.IsFullyIntegrated = TRUE THEN 'COMPLETED'
        WHEN sap.SyncStatus = 'FAILED' AND sap.AttemptCount >= sap.MaxRetryAttempts THEN 'FAILED_MAX_RETRIES'
        WHEN sap.SyncStatus = 'FAILED' THEN 'RETRY_PENDING'
        WHEN sap.SyncStatus = 'IN_PROGRESS' THEN 'IN_PROGRESS'
        WHEN sap.SyncStatus = 'PENDING' THEN 'WAITING'
        ELSE 'UNKNOWN'
    END AS SyncHealthStatus

FROM VF_LOGISTICS_DB.PHASE4_SCHEMA.SAP_Sync_Queue sap
INNER JOIN VF_LOGISTICS_DB.PHASE1_SCHEMA.ShipmentRecord s 
    ON sap.ContainerNumber = s.ContainerNumber
LEFT JOIN VF_LOGISTICS_DB.PHASE2_SCHEMA.Gate_Operations g 
    ON sap.GateID = g.GateID
LEFT JOIN VF_LOGISTICS_DB.PHASE3_SCHEMA.Warehouse_Inventory w 
    ON sap.WarehouseID = w.WarehouseID;

-- =====================================================
-- STEP 5: CREATE STORED PROCEDURE - Enqueue SAP Sync
-- =====================================================
-- Creates a new SAP sync request in the queue
-- =====================================================

CREATE OR REPLACE PROCEDURE VF_LOGISTICS_DB.PHASE4_SCHEMA.SP_Enqueue_SAP_Sync(
    P_SYNC_ID VARCHAR,
    P_CONTAINER_NUMBER VARCHAR,
    P_GATE_ID VARCHAR,
    P_WAREHOUSE_ID VARCHAR,
    P_SAP_SYSTEM VARCHAR,
    P_PRIORITY NUMBER
)
RETURNS VARCHAR
LANGUAGE SQL
AS
$$
DECLARE
    V_SHIPMENT_EXISTS BOOLEAN;
    V_RESULT_MESSAGE VARCHAR;
BEGIN
    -- Verify container exists in Phase 1
    SELECT COUNT(*) > 0 INTO :V_SHIPMENT_EXISTS
    FROM VF_LOGISTICS_DB.PHASE1_SCHEMA.ShipmentRecord
    WHERE ContainerNumber = :P_CONTAINER_NUMBER;
    
    IF (:V_SHIPMENT_EXISTS = FALSE) THEN
        SET V_RESULT_MESSAGE = 'ERROR: Container ' || :P_CONTAINER_NUMBER || 
                               ' not found in Phase 1';
        RETURN :V_RESULT_MESSAGE;
    END IF;
    
    -- Insert into SAP Sync Queue
    INSERT INTO VF_LOGISTICS_DB.PHASE4_SCHEMA.SAP_Sync_Queue (
        SyncID,
        ContainerNumber,
        GateID,
        WarehouseID,
        SAP_System,
        SyncStatus,
        SyncPriority,
        ScheduledSyncTime,
        CreatedBy
    ) VALUES (
        :P_SYNC_ID,
        :P_CONTAINER_NUMBER,
        :P_GATE_ID,
        :P_WAREHOUSE_ID,
        :P_SAP_SYSTEM,
        'PENDING',
        :P_PRIORITY,
        CURRENT_TIMESTAMP(),
        'SYSTEM_AUTO'
    );
    
    SET V_RESULT_MESSAGE = 'SUCCESS: SAP sync ' || :P_SYNC_ID || 
                           ' enqueued for container ' || :P_CONTAINER_NUMBER;
    RETURN :V_RESULT_MESSAGE;
END;
$$;

-- =====================================================
-- STEP 6: CREATE STORED PROCEDURE - Update SAP Sync Status
-- =====================================================
-- Updates sync status and handles retry logic
-- =====================================================

CREATE OR REPLACE PROCEDURE VF_LOGISTICS_DB.PHASE4_SCHEMA.SP_Update_SAP_Sync_Status(
    P_SYNC_ID VARCHAR,
    P_STATUS VARCHAR,
    P_SAP_DOCUMENT VARCHAR,
    P_ERROR_MESSAGE VARCHAR
)
RETURNS VARCHAR
LANGUAGE SQL
AS
$$
DECLARE
    V_CURRENT_ATTEMPTS NUMBER;
    V_MAX_RETRIES NUMBER;
    V_RESULT_MESSAGE VARCHAR;
BEGIN
    -- Get current attempt count
    SELECT AttemptCount, MaxRetryAttempts 
    INTO :V_CURRENT_ATTEMPTS, :V_MAX_RETRIES
    FROM VF_LOGISTICS_DB.PHASE4_SCHEMA.SAP_Sync_Queue
    WHERE SyncID = :P_SYNC_ID;
    
    IF (:P_STATUS = 'SUCCESS') THEN
        -- Success: Mark as fully integrated
        UPDATE VF_LOGISTICS_DB.PHASE4_SCHEMA.SAP_Sync_Queue
        SET 
            SyncStatus = 'SUCCESS',
            SAP_MaterialDocument = :P_SAP_DOCUMENT,
            IsFullyIntegrated = TRUE,
            ActualSyncTime = CURRENT_TIMESTAMP(),
            UpdatedAt = CURRENT_TIMESTAMP(),
            UpdatedBy = 'SYSTEM_AUTO'
        WHERE SyncID = :P_SYNC_ID;
        
        SET V_RESULT_MESSAGE = 'SUCCESS: Sync completed for ' || :P_SYNC_ID;
        
    ELSIF (:P_STATUS = 'FAILED') THEN
        -- Failed: Increment attempts and schedule retry if within limit
        IF (:V_CURRENT_ATTEMPTS + 1 >= :V_MAX_RETRIES) THEN
            -- Max retries reached
            UPDATE VF_LOGISTICS_DB.PHASE4_SCHEMA.SAP_Sync_Queue
            SET 
                SyncStatus = 'FAILED',
                AttemptCount = AttemptCount + 1,
                LastAttempt = CURRENT_TIMESTAMP(),
                ErrorMessage = :P_ERROR_MESSAGE,
                ErrorTimestamp = CURRENT_TIMESTAMP(),
                RequiresManualIntervention = TRUE,
                ManualInterventionReason = 'Max retry attempts reached',
                UpdatedAt = CURRENT_TIMESTAMP(),
                UpdatedBy = 'SYSTEM_AUTO'
            WHERE SyncID = :P_SYNC_ID;
            
            SET V_RESULT_MESSAGE = 'ERROR: Max retries reached for ' || :P_SYNC_ID;
        ELSE
            -- Schedule retry (exponential backoff: 5, 15, 45 minutes)
            UPDATE VF_LOGISTICS_DB.PHASE4_SCHEMA.SAP_Sync_Queue
            SET 
                SyncStatus = 'RETRY',
                AttemptCount = AttemptCount + 1,
                LastAttempt = CURRENT_TIMESTAMP(),
                NextRetryAt = DATEADD(MINUTE, POWER(3, AttemptCount + 1) * 5, CURRENT_TIMESTAMP()),
                ErrorMessage = :P_ERROR_MESSAGE,
                ErrorTimestamp = CURRENT_TIMESTAMP(),
                UpdatedAt = CURRENT_TIMESTAMP(),
                UpdatedBy = 'SYSTEM_AUTO'
            WHERE SyncID = :P_SYNC_ID;
            
            SET V_RESULT_MESSAGE = 'RETRY: Scheduled retry for ' || :P_SYNC_ID;
        END IF;
    END IF;
    
    RETURN :V_RESULT_MESSAGE;
END;
$$;

-- =====================================================
-- STEP 7: CREATE STORED PROCEDURE - Get Pending Syncs
-- =====================================================
-- Returns all sync requests ready for processing
-- =====================================================

CREATE OR REPLACE PROCEDURE VF_LOGISTICS_DB.PHASE4_SCHEMA.SP_Get_Pending_SAP_Syncs()
RETURNS TABLE (
    SyncID VARCHAR,
    ContainerNumber VARCHAR,
    SyncPriority NUMBER,
    AttemptCount NUMBER,
    ScheduledSyncTime TIMESTAMP_NTZ
)
LANGUAGE SQL
AS
$$
    SELECT 
        SyncID,
        ContainerNumber,
        SyncPriority,
        AttemptCount,
        ScheduledSyncTime
    FROM VF_LOGISTICS_DB.PHASE4_SCHEMA.SAP_Sync_Queue
    WHERE SyncStatus IN ('PENDING', 'RETRY')
      AND (NextRetryAt IS NULL OR NextRetryAt <= CURRENT_TIMESTAMP())
      AND RequiresManualIntervention = FALSE
    ORDER BY SyncPriority ASC, ScheduledSyncTime ASC
    LIMIT 100;
$$;

-- =====================================================
-- STEP 8: CREATE MONITORING VIEW - SAP Sync Dashboard
-- =====================================================
-- Real-time SAP integration health metrics
-- =====================================================

CREATE OR REPLACE VIEW VF_LOGISTICS_DB.PHASE4_SCHEMA.V_SAP_Sync_Dashboard AS
SELECT 
    CURRENT_DATE() AS ReportDate,
    
    -- Overall Status Counts
    COUNT(DISTINCT SyncID) AS TotalSyncRequests,
    COUNT(DISTINCT CASE WHEN SyncStatus = 'PENDING' THEN SyncID END) AS PendingCount,
    COUNT(DISTINCT CASE WHEN SyncStatus = 'IN_PROGRESS' THEN SyncID END) AS InProgressCount,
    COUNT(DISTINCT CASE WHEN SyncStatus = 'SUCCESS' THEN SyncID END) AS SuccessCount,
    COUNT(DISTINCT CASE WHEN SyncStatus = 'FAILED' THEN SyncID END) AS FailedCount,
    COUNT(DISTINCT CASE WHEN SyncStatus = 'RETRY' THEN SyncID END) AS RetryCount,
    
    -- Success Rate
    ROUND(
        COUNT(DISTINCT CASE WHEN SyncStatus = 'SUCCESS' THEN SyncID END) * 100.0 /
        NULLIF(COUNT(DISTINCT SyncID), 0),
    2) AS SuccessRatePercent,
    
    -- Integration Completeness
    COUNT(DISTINCT CASE WHEN IsFullyIntegrated = TRUE THEN SyncID END) AS FullyIntegratedCount,
    COUNT(DISTINCT CASE WHEN RequiresManualIntervention = TRUE THEN SyncID END) AS ManualInterventionCount,
    
    -- Financial Metrics
    ROUND(SUM(InvoiceAmount), 2) AS TotalInvoiceAmount_VND,
    COUNT(DISTINCT CASE WHEN PaymentStatus = 'PAID' THEN SyncID END) AS PaidInvoices,
    COUNT(DISTINCT CASE WHEN PaymentStatus = 'PENDING' THEN SyncID END) AS PendingPayments,
    COUNT(DISTINCT CASE WHEN PaymentStatus = 'OVERDUE' THEN SyncID END) AS OverduePayments,
    
    -- Performance Metrics
    ROUND(AVG(CASE WHEN SyncStatus = 'SUCCESS' THEN AttemptCount END), 2) AS AvgAttemptsToSuccess,
    MAX(AttemptCount) AS MaxAttempts

FROM VF_LOGISTICS_DB.PHASE4_SCHEMA.SAP_Sync_Queue
WHERE CreatedAt >= DATEADD(DAY, -30, CURRENT_DATE());

-- =====================================================
-- STEP 9: CREATE ALERT VIEW - Failed SAP Syncs
-- =====================================================
-- Syncs requiring immediate attention
-- =====================================================

CREATE OR REPLACE VIEW VF_LOGISTICS_DB.PHASE4_SCHEMA.V_Failed_SAP_Syncs AS
SELECT 
    sap.SyncID,
    sap.ContainerNumber,
    s.BL_Number,
    sap.SyncStatus,
    sap.AttemptCount,
    sap.MaxRetryAttempts,
    sap.LastAttempt,
    sap.ErrorMessage,
    sap.ErrorCode,
    sap.RequiresManualIntervention,
    sap.ManualInterventionReason,
    
    -- Business Context
    s.Shipper,
    s.Consignee,
    s.Vessel,
    
    -- Time Since Last Failure
    DATEDIFF(HOUR, sap.LastAttempt, CURRENT_TIMESTAMP()) AS HoursSinceLastAttempt,
    
    -- Alert Level
    CASE 
        WHEN sap.RequiresManualIntervention = TRUE THEN 'CRITICAL'
        WHEN sap.AttemptCount >= sap.MaxRetryAttempts THEN 'HIGH'
        WHEN sap.SyncStatus = 'RETRY' THEN 'MEDIUM'
        ELSE 'LOW'
    END AS AlertLevel

FROM VF_LOGISTICS_DB.PHASE4_SCHEMA.SAP_Sync_Queue sap
INNER JOIN VF_LOGISTICS_DB.PHASE1_SCHEMA.ShipmentRecord s 
    ON sap.ContainerNumber = s.ContainerNumber
WHERE sap.SyncStatus IN ('FAILED', 'RETRY')
   OR sap.RequiresManualIntervention = TRUE
ORDER BY AlertLevel, sap.LastAttempt DESC;

-- =====================================================
-- STEP 10: CREATE REPORTING VIEW - End-to-End Pipeline Status
-- =====================================================
-- Complete journey from Phase 1 to Phase 4
-- =====================================================

CREATE OR REPLACE VIEW VF_LOGISTICS_DB.PHASE4_SCHEMA.V_End_To_End_Pipeline_Status AS
SELECT 
    -- Phase 1: Shipment
    s.ContainerNumber,
    s.BL_Number,
    s.Vessel,
    s.ETD,
    
    -- Phase 2: Gate (if exists)
    g.GateID,
    g.InTime AS Phase2_GateInTime,
    g.Status AS Phase2_GateStatus,
    
    -- Phase 3: Warehouse (if exists)
    w.WarehouseID,
    w.WarehouseCode AS Phase3_WarehouseCode,
    w.Status AS Phase3_WarehouseStatus,
    
    -- Phase 4: SAP (if exists)
    sap.SyncID AS Phase4_SyncID,
    sap.SyncStatus AS Phase4_SAPStatus,
    sap.IsFullyIntegrated AS Phase4_FullyIntegrated,
    sap.SAP_InvoiceNumber,
    
    -- Pipeline Stage Detection
    CASE 
        WHEN sap.IsFullyIntegrated = TRUE THEN 'COMPLETED_ALL_PHASES'
        WHEN sap.SyncID IS NOT NULL THEN 'IN_PHASE4_SAP'
        WHEN w.WarehouseID IS NOT NULL THEN 'IN_PHASE3_WAREHOUSE'
        WHEN g.GateID IS NOT NULL THEN 'IN_PHASE2_GATE'
        ELSE 'PHASE1_ONLY'
    END AS CurrentPipelineStage,
    
    -- Total Processing Time
    DATEDIFF(HOUR, g.InTime, sap.ActualSyncTime) AS TotalHoursInPipeline

FROM VF_LOGISTICS_DB.PHASE1_SCHEMA.ShipmentRecord s
LEFT JOIN VF_LOGISTICS_DB.PHASE2_SCHEMA.Gate_Operations g 
    ON s.ContainerNumber = g.ContainerNumber
LEFT JOIN VF_LOGISTICS_DB.PHASE3_SCHEMA.Warehouse_Inventory w 
    ON s.ContainerNumber = w.ContainerNumber
LEFT JOIN VF_LOGISTICS_DB.PHASE4_SCHEMA.SAP_Sync_Queue sap 
    ON s.ContainerNumber = sap.ContainerNumber;

-- =====================================================
-- VERIFICATION QUERIES
-- =====================================================

-- Test 1: Verify table structure
DESC TABLE VF_LOGISTICS_DB.PHASE4_SCHEMA.SAP_Sync_Queue;

-- Test 2: Verify foreign key constraints
SHOW TABLES IN SCHEMA VF_LOGISTICS_DB.PHASE4_SCHEMA;

-- Test 3: Check views
SHOW VIEWS IN SCHEMA VF_LOGISTICS_DB.PHASE4_SCHEMA;

-- Test 4: Check stored procedures
SHOW PROCEDURES IN SCHEMA VF_LOGISTICS_DB.PHASE4_SCHEMA;

-- =====================================================
-- SAMPLE USAGE EXAMPLES
-- =====================================================

/*
-- Example 1: Enqueue a new SAP sync request
CALL VF_LOGISTICS_DB.PHASE4_SCHEMA.SP_Enqueue_SAP_Sync(
    'SAP-SYNC-001',      -- SyncID
    'CONT1234567',       -- ContainerNumber from Phase 1
    'GATE-001',          -- GateID from Phase 2
    'WH-001',            -- WarehouseID from Phase 3
    'PRD',               -- SAP System
    1                    -- Priority (1=highest)
);

-- Example 2: Get pending syncs
CALL VF_LOGISTICS_DB.PHASE4_SCHEMA.SP_Get_Pending_SAP_Syncs();

-- Example 3: Update sync status after SAP API call
CALL VF_LOGISTICS_DB.PHASE4_SCHEMA.SP_Update_SAP_Sync_Status(
    'SAP-SYNC-001',      -- SyncID
    'SUCCESS',           -- Status
    'MIGO-2026-001',     -- SAP Document Number
    NULL                 -- Error Message (null for success)
);

-- Example 4: View complete SAP sync status
SELECT * FROM VF_LOGISTICS_DB.PHASE4_SCHEMA.V_SAP_Sync_Complete
ORDER BY SyncPriority ASC, LastAttempt DESC
LIMIT 20;

-- Example 5: View SAP dashboard metrics
SELECT * FROM VF_LOGISTICS_DB.PHASE4_SCHEMA.V_SAP_Sync_Dashboard;

-- Example 6: View failed syncs requiring attention
SELECT * FROM VF_LOGISTICS_DB.PHASE4_SCHEMA.V_Failed_SAP_Syncs;

-- Example 7: View end-to-end pipeline status
SELECT * FROM VF_LOGISTICS_DB.PHASE4_SCHEMA.V_End_To_End_Pipeline_Status
WHERE CurrentPipelineStage = 'COMPLETED_ALL_PHASES'
LIMIT 10;
*/

-- =====================================================
-- END OF PHASE 4 SAP INTEGRATION SQL
-- =====================================================
-- Integration Points:
-- ✅ Links to Phase 1 via ShipmentRecord.ContainerNumber (FK)
-- ✅ Tracks SAP sync queue with retry logic
-- ✅ Monitors end-to-end pipeline from Phase 1 to Phase 4
-- ✅ Supports Zero-Copy SAP BDC integration
-- ✅ Provides financial tracking and payment status
-- =====================================================
