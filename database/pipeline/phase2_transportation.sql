-- =====================================================
-- PHASE 2: TRANSPORTATION & GATE MANAGEMENT
-- =====================================================
-- VF_Logistics_Portal Database Expansion
-- Author: Data Engineering Team
-- Created: 2026-06-22
-- 
-- CRITICAL: This file follows Open-Closed Principle
-- ✅ EXTENDS Phase 1 (no modification to existing objects)
-- ✅ Links to Phase 1 via ShipmentRecord.ContainerNumber (FK)
-- =====================================================

-- =====================================================
-- STEP 1: CREATE PHASE 2 SCHEMA (if not exists)
-- =====================================================
CREATE SCHEMA IF NOT EXISTS VF_LOGISTICS_DB.PHASE2_SCHEMA
COMMENT = 'Phase 2: Land Transportation, Gate-In/Gate-Out Operations';

-- =====================================================
-- STEP 2: CREATE Gate_Operations TABLE
-- =====================================================
-- Tracks all truck gate-in/gate-out events
-- Links to Phase 1 via ContainerNumber (Foreign Key)
-- =====================================================

CREATE OR REPLACE TABLE VF_LOGISTICS_DB.PHASE2_SCHEMA.Gate_Operations (
    -- Primary Key
    GateID VARCHAR(50) PRIMARY KEY,
    
    -- Link to Phase 1 ShipmentRecord (Foreign Key)
    ContainerNumber VARCHAR(50) NOT NULL,
    
    -- Truck & Driver Information
    PlateNumber VARCHAR(20) NOT NULL,
    DriverPhone VARCHAR(20),
    DriverName VARCHAR(200),
    TruckingCompany VARCHAR(300),
    
    -- Gate Transaction Details
    GateNumber VARCHAR(10),           -- e.g., GATE-01, GATE-02
    InTime TIMESTAMP_NTZ,             -- Gate-in timestamp
    OutTime TIMESTAMP_NTZ,            -- Gate-out timestamp
    Status VARCHAR(20) DEFAULT 'IN_YARD', -- IN_YARD, OUT_YARD, IN_TRANSIT
    
    -- Container Details
    ContainerType VARCHAR(20),        -- 20GP, 40HC, 40RF, etc.
    ContainerCondition VARCHAR(20),   -- FULL, EMPTY
    SealNumber VARCHAR(50),
    
    -- Location Assignment (from Phase 3 yard allocation)
    AssignedYardLocation VARCHAR(50), -- Will be populated by Phase 3
    
    -- Anonymous Portal & QR Integration
    QRCodeScanned BOOLEAN DEFAULT FALSE,
    QRScanTimestamp TIMESTAMP_NTZ,
    PortalSessionID VARCHAR(100),
    
    -- Zalo Bot Notification
    ZaloMessageSent BOOLEAN DEFAULT FALSE,
    ZaloMessageID VARCHAR(100),
    ZaloMessageTimestamp TIMESTAMP_NTZ,
    
    -- Duration Calculation
    DurationMinutes NUMBER(10,2) AS (
        DATEDIFF(MINUTE, InTime, COALESCE(OutTime, CURRENT_TIMESTAMP()))
    ),
    
    -- Audit Fields
    CreatedAt TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    UpdatedAt TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    CreatedBy VARCHAR(100),
    UpdatedBy VARCHAR(100),
    
    -- Foreign Key Constraint (links to Phase 1)
    CONSTRAINT FK_Gate_Operations_ShipmentRecord 
        FOREIGN KEY (ContainerNumber) 
        REFERENCES VF_LOGISTICS_DB.PHASE1_SCHEMA.ShipmentRecord(ContainerNumber)
);

-- Create Indexes for Performance
CREATE INDEX IF NOT EXISTS IDX_Gate_Operations_ContainerNumber 
    ON VF_LOGISTICS_DB.PHASE2_SCHEMA.Gate_Operations(ContainerNumber);

CREATE INDEX IF NOT EXISTS IDX_Gate_Operations_InTime 
    ON VF_LOGISTICS_DB.PHASE2_SCHEMA.Gate_Operations(InTime);

CREATE INDEX IF NOT EXISTS IDX_Gate_Operations_Status 
    ON VF_LOGISTICS_DB.PHASE2_SCHEMA.Gate_Operations(Status);

-- =====================================================
-- STEP 3: CREATE EXTENSION TABLE (Optional)
-- =====================================================
-- If Phase 2 needs additional shipment-level data 
-- without modifying Phase 1's ShipmentRecord
-- =====================================================

CREATE OR REPLACE TABLE VF_LOGISTICS_DB.PHASE2_SCHEMA.ShipmentRecord_Transportation_Extension (
    -- 1-to-1 relationship with ShipmentRecord
    ContainerNumber VARCHAR(50) PRIMARY KEY,
    
    -- Transportation-specific attributes
    PreferredTruckingCompany VARCHAR(300),
    TransportationPriority VARCHAR(20), -- HIGH, MEDIUM, LOW
    CustomsClearanceRequired BOOLEAN DEFAULT FALSE,
    CustomsClearanceStatus VARCHAR(30),
    CustomsClearanceDate DATE,
    
    -- Delivery Instructions
    DeliveryInstructions VARCHAR(2000),
    SpecialHandlingRequired BOOLEAN DEFAULT FALSE,
    SpecialHandlingNotes VARCHAR(1000),
    
    -- Cost Tracking
    TransportationCostVND NUMBER(15,2),
    GateFeeVND NUMBER(15,2),
    
    -- Audit
    CreatedAt TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    UpdatedAt TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    
    -- Foreign Key to Phase 1
    CONSTRAINT FK_ShipmentExt_Phase2_ShipmentRecord 
        FOREIGN KEY (ContainerNumber) 
        REFERENCES VF_LOGISTICS_DB.PHASE1_SCHEMA.ShipmentRecord(ContainerNumber)
);

-- =====================================================
-- STEP 4: CREATE VIEW - Gate Operations with Shipment Info
-- =====================================================
-- Joins Phase 2 Gate_Operations with Phase 1 ShipmentRecord
-- Provides complete visibility of gate transactions
-- =====================================================

CREATE OR REPLACE VIEW VF_LOGISTICS_DB.PHASE2_SCHEMA.V_Gate_Operations_WithShipment AS
SELECT 
    -- Gate Operation Info
    g.GateID,
    g.PlateNumber,
    g.DriverPhone,
    g.DriverName,
    g.GateNumber,
    g.InTime,
    g.OutTime,
    g.Status AS GateStatus,
    g.DurationMinutes,
    g.ContainerType,
    g.ContainerCondition,
    g.AssignedYardLocation,
    
    -- Phase 1 Shipment Info (READ-ONLY, no modification)
    s.ContainerNumber,
    s.BL_Number,
    s.Shipper,
    s.Consignee,
    s.Vessel,
    s.ETD AS ExpectedDeparture,
    s.ETA AS ExpectedArrival,
    
    -- Transportation Extension (if exists)
    e.TransportationPriority,
    e.CustomsClearanceRequired,
    e.CustomsClearanceStatus,
    e.DeliveryInstructions,
    
    -- Business Logic: Calculate Urgency
    CASE 
        WHEN s.ETD <= DATEADD(DAY, 2, CURRENT_DATE()) THEN 'URGENT'
        WHEN s.ETD <= DATEADD(DAY, 5, CURRENT_DATE()) THEN 'NORMAL'
        ELSE 'LOW_PRIORITY'
    END AS UrgencyLevel,
    
    -- Business Logic: Detect Delays
    CASE 
        WHEN g.Status = 'IN_YARD' AND g.DurationMinutes > 180 THEN TRUE
        ELSE FALSE
    END AS IsDelayed

FROM VF_LOGISTICS_DB.PHASE2_SCHEMA.Gate_Operations g
INNER JOIN VF_LOGISTICS_DB.PHASE1_SCHEMA.ShipmentRecord s 
    ON g.ContainerNumber = s.ContainerNumber
LEFT JOIN VF_LOGISTICS_DB.PHASE2_SCHEMA.ShipmentRecord_Transportation_Extension e 
    ON g.ContainerNumber = e.ContainerNumber;

-- =====================================================
-- STEP 5: CREATE STORED PROCEDURE - Match Gate Operations
-- =====================================================
-- Automatically matches incoming gate-in events with 
-- existing ShipmentRecords from Phase 1
-- =====================================================

CREATE OR REPLACE PROCEDURE VF_LOGISTICS_DB.PHASE2_SCHEMA.SP_Match_GateOperation_To_Shipment(
    P_GATE_ID VARCHAR,
    P_CONTAINER_NUMBER VARCHAR,
    P_PLATE_NUMBER VARCHAR
)
RETURNS VARCHAR
LANGUAGE SQL
AS
$$
DECLARE
    V_SHIPMENT_EXISTS BOOLEAN;
    V_RESULT_MESSAGE VARCHAR;
BEGIN
    -- Step 1: Check if ShipmentRecord exists in Phase 1
    SELECT COUNT(*) > 0 INTO :V_SHIPMENT_EXISTS
    FROM VF_LOGISTICS_DB.PHASE1_SCHEMA.ShipmentRecord
    WHERE ContainerNumber = :P_CONTAINER_NUMBER;
    
    IF (:V_SHIPMENT_EXISTS = FALSE) THEN
        -- Container not found in Phase 1
        SET V_RESULT_MESSAGE = 'ERROR: Container ' || :P_CONTAINER_NUMBER || 
                               ' not found in Phase 1 ShipmentRecord';
        RETURN :V_RESULT_MESSAGE;
    END IF;
    
    -- Step 2: Check if Gate_Operation already exists
    IF (SELECT COUNT(*) FROM VF_LOGISTICS_DB.PHASE2_SCHEMA.Gate_Operations 
        WHERE GateID = :P_GATE_ID) > 0 THEN
        SET V_RESULT_MESSAGE = 'ERROR: GateID ' || :P_GATE_ID || ' already exists';
        RETURN :V_RESULT_MESSAGE;
    END IF;
    
    -- Step 3: Insert Gate Operation (linked to Phase 1)
    INSERT INTO VF_LOGISTICS_DB.PHASE2_SCHEMA.Gate_Operations (
        GateID,
        ContainerNumber,
        PlateNumber,
        InTime,
        Status,
        CreatedBy
    ) VALUES (
        :P_GATE_ID,
        :P_CONTAINER_NUMBER,
        :P_PLATE_NUMBER,
        CURRENT_TIMESTAMP(),
        'IN_YARD',
        'SYSTEM_AUTO'
    );
    
    SET V_RESULT_MESSAGE = 'SUCCESS: Gate operation ' || :P_GATE_ID || 
                           ' matched to container ' || :P_CONTAINER_NUMBER;
    RETURN :V_RESULT_MESSAGE;
END;
$$;

-- =====================================================
-- STEP 6: CREATE STORED PROCEDURE - Record Gate-Out
-- =====================================================
-- Updates gate-out time when truck leaves the yard
-- =====================================================

CREATE OR REPLACE PROCEDURE VF_LOGISTICS_DB.PHASE2_SCHEMA.SP_Record_GateOut(
    P_GATE_ID VARCHAR
)
RETURNS VARCHAR
LANGUAGE SQL
AS
$$
DECLARE
    V_RECORD_EXISTS BOOLEAN;
    V_RESULT_MESSAGE VARCHAR;
BEGIN
    -- Check if gate operation exists
    SELECT COUNT(*) > 0 INTO :V_RECORD_EXISTS
    FROM VF_LOGISTICS_DB.PHASE2_SCHEMA.Gate_Operations
    WHERE GateID = :P_GATE_ID;
    
    IF (:V_RECORD_EXISTS = FALSE) THEN
        SET V_RESULT_MESSAGE = 'ERROR: GateID ' || :P_GATE_ID || ' not found';
        RETURN :V_RESULT_MESSAGE;
    END IF;
    
    -- Update OutTime and Status
    UPDATE VF_LOGISTICS_DB.PHASE2_SCHEMA.Gate_Operations
    SET 
        OutTime = CURRENT_TIMESTAMP(),
        Status = 'OUT_YARD',
        UpdatedAt = CURRENT_TIMESTAMP(),
        UpdatedBy = 'SYSTEM_AUTO'
    WHERE GateID = :P_GATE_ID;
    
    SET V_RESULT_MESSAGE = 'SUCCESS: Gate-out recorded for ' || :P_GATE_ID;
    RETURN :V_RESULT_MESSAGE;
END;
$$;

-- =====================================================
-- STEP 7: CREATE MONITORING VIEW - Active Yard Trucks
-- =====================================================
-- Shows all trucks currently in the yard
-- =====================================================

CREATE OR REPLACE VIEW VF_LOGISTICS_DB.PHASE2_SCHEMA.V_Active_Trucks_In_Yard AS
SELECT 
    g.GateID,
    g.ContainerNumber,
    g.PlateNumber,
    g.DriverPhone,
    g.InTime,
    g.DurationMinutes,
    g.AssignedYardLocation,
    s.Vessel,
    s.ETD,
    
    -- Alert if truck is in yard too long
    CASE 
        WHEN g.DurationMinutes > 240 THEN 'CRITICAL_DELAY'
        WHEN g.DurationMinutes > 180 THEN 'WARNING'
        ELSE 'NORMAL'
    END AS AlertLevel
    
FROM VF_LOGISTICS_DB.PHASE2_SCHEMA.Gate_Operations g
INNER JOIN VF_LOGISTICS_DB.PHASE1_SCHEMA.ShipmentRecord s 
    ON g.ContainerNumber = s.ContainerNumber
WHERE g.Status = 'IN_YARD'
  AND g.OutTime IS NULL
ORDER BY g.DurationMinutes DESC;

-- =====================================================
-- STEP 8: CREATE REPORTING VIEW - Daily Gate Statistics
-- =====================================================
-- Summary of daily gate operations
-- =====================================================

CREATE OR REPLACE VIEW VF_LOGISTICS_DB.PHASE2_SCHEMA.V_Daily_Gate_Statistics AS
SELECT 
    DATE(InTime) AS OperationDate,
    COUNT(DISTINCT GateID) AS TotalGateTransactions,
    COUNT(DISTINCT CASE WHEN Status = 'IN_YARD' THEN GateID END) AS CurrentlyInYard,
    COUNT(DISTINCT CASE WHEN Status = 'OUT_YARD' THEN GateID END) AS CompletedToday,
    COUNT(DISTINCT PlateNumber) AS UniqueTrucks,
    ROUND(AVG(DurationMinutes), 2) AS AvgDurationMinutes,
    MAX(DurationMinutes) AS MaxDurationMinutes
FROM VF_LOGISTICS_DB.PHASE2_SCHEMA.Gate_Operations
WHERE InTime >= DATEADD(DAY, -30, CURRENT_DATE())
GROUP BY DATE(InTime)
ORDER BY OperationDate DESC;

-- =====================================================
-- VERIFICATION QUERIES
-- =====================================================

-- Test 1: Verify table structure
DESC TABLE VF_LOGISTICS_DB.PHASE2_SCHEMA.Gate_Operations;

-- Test 2: Verify foreign key constraint
SHOW TABLES LIKE 'Gate_Operations' IN SCHEMA VF_LOGISTICS_DB.PHASE2_SCHEMA;

-- Test 3: Check views
SHOW VIEWS IN SCHEMA VF_LOGISTICS_DB.PHASE2_SCHEMA;

-- Test 4: Check stored procedures
SHOW PROCEDURES IN SCHEMA VF_LOGISTICS_DB.PHASE2_SCHEMA;

-- =====================================================
-- SAMPLE USAGE EXAMPLES
-- =====================================================

/*
-- Example 1: Record a new gate-in
CALL VF_LOGISTICS_DB.PHASE2_SCHEMA.SP_Match_GateOperation_To_Shipment(
    'GATE-001',
    'CONT1234567',  -- Must exist in Phase 1 ShipmentRecord
    '51A-12345'
);

-- Example 2: Record gate-out
CALL VF_LOGISTICS_DB.PHASE2_SCHEMA.SP_Record_GateOut('GATE-001');

-- Example 3: View all gate operations with shipment info
SELECT * FROM VF_LOGISTICS_DB.PHASE2_SCHEMA.V_Gate_Operations_WithShipment
ORDER BY InTime DESC
LIMIT 10;

-- Example 4: Monitor trucks in yard
SELECT * FROM VF_LOGISTICS_DB.PHASE2_SCHEMA.V_Active_Trucks_In_Yard;

-- Example 5: Daily statistics
SELECT * FROM VF_LOGISTICS_DB.PHASE2_SCHEMA.V_Daily_Gate_Statistics
LIMIT 7;
*/

-- =====================================================
-- END OF PHASE 2 TRANSPORTATION SQL
-- =====================================================
-- Integration Points:
-- ✅ Links to Phase 1 via ShipmentRecord.ContainerNumber (FK)
-- ✅ Provides AssignedYardLocation column for Phase 3 integration
-- ✅ Ready for Zalo Bot & Anonymous Portal integration
-- =====================================================
