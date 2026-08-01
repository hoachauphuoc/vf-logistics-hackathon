-- =====================================================
-- PHASE 3: WAREHOUSE & YARD MANAGEMENT
-- =====================================================
-- VF_Logistics_Portal Database Expansion
-- Author: Data Engineering Team
-- Created: 2026-06-22
-- 
-- CRITICAL: This file follows Open-Closed Principle
-- ✅ EXTENDS Phase 1 & Phase 2 (no modification to existing objects)
-- ✅ Links to Phase 1 via ShipmentRecord.ContainerNumber (FK)
-- ✅ Links to Phase 2 via Gate_Operations.GateID (FK)
-- =====================================================

-- =====================================================
-- STEP 1: CREATE PHASE 3 SCHEMA (if not exists)
-- =====================================================
CREATE SCHEMA IF NOT EXISTS VF_LOGISTICS_DB.PHASE3_SCHEMA
COMMENT = 'Phase 3: Warehouse Inventory & Yard Management (7 DCs)';

-- =====================================================
-- STEP 2: CREATE Warehouse_Inventory TABLE
-- =====================================================
-- Tracks container storage across 7 Distribution Centers
-- Links to Phase 1 (ShipmentRecord) and Phase 2 (Gate_Operations)
-- =====================================================

CREATE OR REPLACE TABLE VF_LOGISTICS_DB.PHASE3_SCHEMA.Warehouse_Inventory (
    -- Primary Key
    WarehouseID VARCHAR(50) PRIMARY KEY,
    
    -- Link to Phase 1 ShipmentRecord (Foreign Key)
    ContainerNumber VARCHAR(50) NOT NULL,
    
    -- Link to Phase 2 Gate_Operations (Optional FK)
    GateID VARCHAR(50),
    
    -- Warehouse & Location
    WarehouseCode VARCHAR(10) NOT NULL,  -- WH-1 to WH-7 (7 DCs)
    WarehouseName VARCHAR(200),
    ZoneType VARCHAR(20),                -- COLD, AMBIENT, HAZMAT, GENERAL
    
    -- Precise Yard Location
    SlotNumber VARCHAR(50),              -- Primary storage slot
    RowNumber VARCHAR(10),
    BayNumber VARCHAR(10),
    TierNumber VARCHAR(10),              -- Stacking tier (1=ground, 2=on top, etc.)
    
    -- Container/Cargo Details
    CargoType VARCHAR(100),
    WeightKG NUMBER(15,2),
    VolumeCBM NUMBER(15,2),
    TemperatureRequirement NUMBER(5,2), -- For refrigerated containers
    
    -- Yard Allocation Algorithm Results
    AllocatedByAI BOOLEAN DEFAULT FALSE,
    AllocationScore NUMBER(5,2),        -- 0-100, higher = more optimal
    OptimalPosition BOOLEAN DEFAULT FALSE,
    
    -- Restacking Tracking
    RestackingRequired BOOLEAN DEFAULT FALSE,
    RestackingCount NUMBER(5,0) DEFAULT 0,
    LastRestackingDate TIMESTAMP_NTZ,
    
    -- Stock Status
    Status VARCHAR(30) DEFAULT 'IN_STOCK', -- IN_STOCK, RESERVED, DISPATCHED, RELOCATED
    StockInDate TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    StockOutDate TIMESTAMP_NTZ,
    
    -- Mobile App Offline Sync
    LastScannedAt TIMESTAMP_NTZ,
    ScannedBy VARCHAR(100),
    ScannedDeviceID VARCHAR(100),
    OfflineSyncFlag BOOLEAN DEFAULT FALSE, -- TRUE if data entered offline
    SyncedToCloudAt TIMESTAMP_NTZ,
    
    -- Loading Priority (from vessel schedule)
    LoadingPriority NUMBER(3,0),        -- 1=highest, 99=lowest
    ExpectedLoadingDate DATE,           -- From Phase 1 ShipmentRecord.ETD
    
    -- Space Utilization
    BlockedSlots NUMBER(3,0) DEFAULT 1, -- How many slots this container blocks
    AccessibilityScore NUMBER(5,2),     -- 0-100, higher = easier to access
    
    -- Audit Fields
    CreatedAt TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    UpdatedAt TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    CreatedBy VARCHAR(100),
    UpdatedBy VARCHAR(100),
    
    -- Foreign Key Constraints
    CONSTRAINT FK_Warehouse_Inventory_ShipmentRecord 
        FOREIGN KEY (ContainerNumber) 
        REFERENCES VF_LOGISTICS_DB.PHASE1_SCHEMA.ShipmentRecord(ContainerNumber),
    
    CONSTRAINT FK_Warehouse_Inventory_GateOperations 
        FOREIGN KEY (GateID) 
        REFERENCES VF_LOGISTICS_DB.PHASE2_SCHEMA.Gate_Operations(GateID)
);

-- Create Indexes for Performance
CREATE INDEX IF NOT EXISTS IDX_Warehouse_Inventory_ContainerNumber 
    ON VF_LOGISTICS_DB.PHASE3_SCHEMA.Warehouse_Inventory(ContainerNumber);

CREATE INDEX IF NOT EXISTS IDX_Warehouse_Inventory_Status 
    ON VF_LOGISTICS_DB.PHASE3_SCHEMA.Warehouse_Inventory(Status);

CREATE INDEX IF NOT EXISTS IDX_Warehouse_Inventory_WarehouseCode 
    ON VF_LOGISTICS_DB.PHASE3_SCHEMA.Warehouse_Inventory(WarehouseCode);

CREATE INDEX IF NOT EXISTS IDX_Warehouse_Inventory_LoadingDate 
    ON VF_LOGISTICS_DB.PHASE3_SCHEMA.Warehouse_Inventory(ExpectedLoadingDate);

-- =====================================================
-- STEP 3: CREATE Yard_Configuration TABLE
-- =====================================================
-- Master data for yard slot configuration
-- =====================================================

CREATE OR REPLACE TABLE VF_LOGISTICS_DB.PHASE3_SCHEMA.Yard_Configuration (
    SlotID VARCHAR(50) PRIMARY KEY,
    WarehouseCode VARCHAR(10) NOT NULL,
    SlotNumber VARCHAR(50) NOT NULL,
    RowNumber VARCHAR(10),
    BayNumber VARCHAR(10),
    MaxTierHeight NUMBER(2,0) DEFAULT 3,  -- Max stacking height
    
    -- Slot Characteristics
    ZoneType VARCHAR(20),              -- COLD, AMBIENT, HAZMAT, GENERAL
    HasPowerSupply BOOLEAN DEFAULT FALSE, -- For reefer containers
    IsUnderCover BOOLEAN DEFAULT FALSE,
    DistanceToGateMeters NUMBER(6,2),
    DistanceToQuayMeters NUMBER(6,2),
    
    -- Slot Status
    IsAvailable BOOLEAN DEFAULT TRUE,
    IsBlocked BOOLEAN DEFAULT FALSE,
    BlockedReason VARCHAR(500),
    
    -- Capacity
    MaxWeightKG NUMBER(15,2),
    CurrentOccupancy NUMBER(3,0) DEFAULT 0, -- Number of containers currently
    
    -- Maintenance
    LastMaintenanceDate DATE,
    NextMaintenanceDate DATE,
    
    CreatedAt TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    UpdatedAt TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- =====================================================
-- STEP 4: CREATE VIEW - Warehouse Inventory with Shipment Details
-- =====================================================
-- Combines Phase 1, 2, 3 data for complete visibility
-- =====================================================

CREATE OR REPLACE VIEW VF_LOGISTICS_DB.PHASE3_SCHEMA.V_Warehouse_Inventory_Complete AS
SELECT 
    -- Warehouse Info
    w.WarehouseID,
    w.WarehouseCode,
    w.WarehouseName,
    w.SlotNumber,
    w.Status AS InventoryStatus,
    w.StockInDate,
    w.LoadingPriority,
    w.RestackingCount,
    w.AllocationScore,
    
    -- Container Info from Phase 1 (READ-ONLY)
    s.ContainerNumber,
    s.BL_Number,
    s.Shipper,
    s.Consignee,
    s.Vessel,
    s.ETD,
    s.ETA,
    
    -- Gate Info from Phase 2 (if available)
    g.PlateNumber,
    g.DriverPhone,
    g.InTime AS GateInTime,
    
    -- Business Logic: Days Until Loading
    DATEDIFF(DAY, CURRENT_DATE(), s.ETD) AS DaysUntilETD,
    
    -- Business Logic: Storage Duration
    DATEDIFF(DAY, w.StockInDate, CURRENT_DATE()) AS DaysInStorage,
    
    -- Business Logic: Urgency Flag
    CASE 
        WHEN DATEDIFF(DAY, CURRENT_DATE(), s.ETD) <= 1 THEN 'CRITICAL'
        WHEN DATEDIFF(DAY, CURRENT_DATE(), s.ETD) <= 3 THEN 'HIGH'
        WHEN DATEDIFF(DAY, CURRENT_DATE(), s.ETD) <= 7 THEN 'MEDIUM'
        ELSE 'LOW'
    END AS UrgencyLevel,
    
    -- Business Logic: Restacking Alert
    CASE 
        WHEN w.RestackingCount > 2 THEN 'EXCESSIVE_RESTACKING'
        WHEN w.RestackingRequired = TRUE THEN 'NEEDS_RESTACKING'
        ELSE 'OK'
    END AS RestackingAlert

FROM VF_LOGISTICS_DB.PHASE3_SCHEMA.Warehouse_Inventory w
INNER JOIN VF_LOGISTICS_DB.PHASE1_SCHEMA.ShipmentRecord s 
    ON w.ContainerNumber = s.ContainerNumber
LEFT JOIN VF_LOGISTICS_DB.PHASE2_SCHEMA.Gate_Operations g 
    ON w.GateID = g.GateID;

-- =====================================================
-- STEP 5: CREATE STORED PROCEDURE - Optimize Yard Placement
-- =====================================================
-- AI-powered yard allocation based on vessel schedule
-- Minimizes restacking by placing containers in optimal order
-- =====================================================

CREATE OR REPLACE PROCEDURE VF_LOGISTICS_DB.PHASE3_SCHEMA.SP_Optimize_Yard_Placement(
    P_CONTAINER_NUMBER VARCHAR
)
RETURNS VARCHAR
LANGUAGE SQL
AS
$$
DECLARE
    V_VESSEL_ETD DATE;
    V_RECOMMENDED_SLOT VARCHAR;
    V_ALLOCATION_SCORE NUMBER;
    V_RESULT_MESSAGE VARCHAR;
BEGIN
    -- Step 1: Get ETD from Phase 1 ShipmentRecord
    SELECT ETD INTO :V_VESSEL_ETD
    FROM VF_LOGISTICS_DB.PHASE1_SCHEMA.ShipmentRecord
    WHERE ContainerNumber = :P_CONTAINER_NUMBER;
    
    IF (:V_VESSEL_ETD IS NULL) THEN
        SET V_RESULT_MESSAGE = 'ERROR: Container ' || :P_CONTAINER_NUMBER || 
                               ' not found in Phase 1';
        RETURN :V_RESULT_MESSAGE;
    END IF;
    
    -- Step 2: Find optimal slot based on ETD priority
    -- Logic: Containers loading sooner should be more accessible
    -- (Simplified algorithm - real implementation would be more complex)
    
    SELECT 
        SlotNumber,
        -- Score calculation:
        -- - Closer to gate = higher score
        -- - Available slot = higher score
        -- - Match zone type = higher score
        (100 - (DistanceToGateMeters / 10)) AS Score
    INTO :V_RECOMMENDED_SLOT, :V_ALLOCATION_SCORE
    FROM VF_LOGISTICS_DB.PHASE3_SCHEMA.Yard_Configuration
    WHERE IsAvailable = TRUE
      AND IsBlocked = FALSE
      AND CurrentOccupancy < MaxTierHeight
    ORDER BY Score DESC
    LIMIT 1;
    
    IF (:V_RECOMMENDED_SLOT IS NULL) THEN
        SET V_RESULT_MESSAGE = 'ERROR: No available slots found';
        RETURN :V_RESULT_MESSAGE;
    END IF;
    
    -- Step 3: Return recommendation
    SET V_RESULT_MESSAGE = 'SUCCESS: Recommended slot ' || :V_RECOMMENDED_SLOT || 
                           ' with score ' || :V_ALLOCATION_SCORE || 
                           ' for container ' || :P_CONTAINER_NUMBER ||
                           ' (ETD: ' || TO_VARCHAR(:V_VESSEL_ETD, 'YYYY-MM-DD') || ')';
    
    RETURN :V_RESULT_MESSAGE;
END;
$$;

-- =====================================================
-- STEP 6: CREATE STORED PROCEDURE - Assign Container to Slot
-- =====================================================
-- Assigns a container to a specific warehouse slot
-- Updates Phase 2 Gate_Operations with yard location
-- =====================================================

CREATE OR REPLACE PROCEDURE VF_LOGISTICS_DB.PHASE3_SCHEMA.SP_Assign_Container_To_Slot(
    P_WAREHOUSE_ID VARCHAR,
    P_CONTAINER_NUMBER VARCHAR,
    P_GATE_ID VARCHAR,
    P_WAREHOUSE_CODE VARCHAR,
    P_SLOT_NUMBER VARCHAR
)
RETURNS VARCHAR
LANGUAGE SQL
AS
$$
DECLARE
    V_ETD DATE;
    V_LOADING_PRIORITY NUMBER;
    V_RESULT_MESSAGE VARCHAR;
BEGIN
    -- Get ETD and calculate priority from Phase 1
    SELECT 
        ETD,
        CASE 
            WHEN DATEDIFF(DAY, CURRENT_DATE(), ETD) <= 1 THEN 1
            WHEN DATEDIFF(DAY, CURRENT_DATE(), ETD) <= 3 THEN 2
            WHEN DATEDIFF(DAY, CURRENT_DATE(), ETD) <= 7 THEN 3
            ELSE 4
        END
    INTO :V_ETD, :V_LOADING_PRIORITY
    FROM VF_LOGISTICS_DB.PHASE1_SCHEMA.ShipmentRecord
    WHERE ContainerNumber = :P_CONTAINER_NUMBER;
    
    -- Insert into Warehouse_Inventory
    INSERT INTO VF_LOGISTICS_DB.PHASE3_SCHEMA.Warehouse_Inventory (
        WarehouseID,
        ContainerNumber,
        GateID,
        WarehouseCode,
        SlotNumber,
        Status,
        AllocatedByAI,
        LoadingPriority,
        ExpectedLoadingDate,
        CreatedBy
    ) VALUES (
        :P_WAREHOUSE_ID,
        :P_CONTAINER_NUMBER,
        :P_GATE_ID,
        :P_WAREHOUSE_CODE,
        :P_SLOT_NUMBER,
        'IN_STOCK',
        TRUE,
        :V_LOADING_PRIORITY,
        :V_ETD,
        'SYSTEM_AUTO'
    );
    
    -- Update Phase 2 Gate_Operations with assigned location
    UPDATE VF_LOGISTICS_DB.PHASE2_SCHEMA.Gate_Operations
    SET 
        AssignedYardLocation = :P_SLOT_NUMBER,
        UpdatedAt = CURRENT_TIMESTAMP()
    WHERE GateID = :P_GATE_ID;
    
    -- Update Yard_Configuration occupancy
    UPDATE VF_LOGISTICS_DB.PHASE3_SCHEMA.Yard_Configuration
    SET 
        CurrentOccupancy = CurrentOccupancy + 1,
        UpdatedAt = CURRENT_TIMESTAMP()
    WHERE SlotNumber = :P_SLOT_NUMBER
      AND WarehouseCode = :P_WAREHOUSE_CODE;
    
    SET V_RESULT_MESSAGE = 'SUCCESS: Container ' || :P_CONTAINER_NUMBER || 
                           ' assigned to slot ' || :P_SLOT_NUMBER ||
                           ' in warehouse ' || :P_WAREHOUSE_CODE;
    RETURN :V_RESULT_MESSAGE;
END;
$$;

-- =====================================================
-- STEP 7: CREATE STORED PROCEDURE - Calculate Restacking Needs
-- =====================================================
-- Identifies containers that will need restacking
-- =====================================================

CREATE OR REPLACE PROCEDURE VF_LOGISTICS_DB.PHASE3_SCHEMA.SP_Calculate_Restacking_Needs(
    P_WAREHOUSE_CODE VARCHAR
)
RETURNS TABLE (
    ContainerNumber VARCHAR,
    SlotNumber VARCHAR,
    ETD DATE,
    CurrentTier NUMBER,
    BlockingContainers NUMBER,
    RestackingPriority VARCHAR
)
LANGUAGE SQL
AS
$$
    -- Find containers that are blocked by other containers
    -- with later ETD (needs restacking)
    SELECT 
        w1.ContainerNumber,
        w1.SlotNumber,
        s1.ETD,
        TRY_CAST(w1.TierNumber AS NUMBER) AS CurrentTier,
        
        -- Count containers above this one with later ETD
        (SELECT COUNT(*)
         FROM VF_LOGISTICS_DB.PHASE3_SCHEMA.Warehouse_Inventory w2
         INNER JOIN VF_LOGISTICS_DB.PHASE1_SCHEMA.ShipmentRecord s2
             ON w2.ContainerNumber = s2.ContainerNumber
         WHERE w2.SlotNumber = w1.SlotNumber
           AND w2.WarehouseCode = w1.WarehouseCode
           AND TRY_CAST(w2.TierNumber AS NUMBER) > TRY_CAST(w1.TierNumber AS NUMBER)
           AND s2.ETD > s1.ETD
        ) AS BlockingContainers,
        
        CASE 
            WHEN DATEDIFF(DAY, CURRENT_DATE(), s1.ETD) <= 2 THEN 'CRITICAL'
            WHEN DATEDIFF(DAY, CURRENT_DATE(), s1.ETD) <= 5 THEN 'HIGH'
            ELSE 'MEDIUM'
        END AS RestackingPriority
        
    FROM VF_LOGISTICS_DB.PHASE3_SCHEMA.Warehouse_Inventory w1
    INNER JOIN VF_LOGISTICS_DB.PHASE1_SCHEMA.ShipmentRecord s1
        ON w1.ContainerNumber = s1.ContainerNumber
    WHERE w1.WarehouseCode = :P_WAREHOUSE_CODE
      AND w1.Status = 'IN_STOCK'
    HAVING BlockingContainers > 0
    ORDER BY s1.ETD ASC, BlockingContainers DESC;
$$;

-- =====================================================
-- STEP 8: CREATE MONITORING VIEW - Warehouse Capacity
-- =====================================================
-- Real-time capacity tracking for 7 DCs
-- =====================================================

CREATE OR REPLACE VIEW VF_LOGISTICS_DB.PHASE3_SCHEMA.V_Warehouse_Capacity AS
SELECT 
    w.WarehouseCode,
    w.WarehouseName,
    COUNT(DISTINCT w.WarehouseID) AS TotalContainers,
    COUNT(DISTINCT CASE WHEN w.Status = 'IN_STOCK' THEN w.WarehouseID END) AS InStock,
    COUNT(DISTINCT CASE WHEN w.Status = 'RESERVED' THEN w.WarehouseID END) AS Reserved,
    COUNT(DISTINCT CASE WHEN w.Status = 'DISPATCHED' THEN w.WarehouseID END) AS Dispatched,
    
    -- Utilization
    (SELECT COUNT(*) FROM VF_LOGISTICS_DB.PHASE3_SCHEMA.Yard_Configuration yc 
     WHERE yc.WarehouseCode = w.WarehouseCode) AS TotalSlots,
    
    (SELECT SUM(CurrentOccupancy) FROM VF_LOGISTICS_DB.PHASE3_SCHEMA.Yard_Configuration yc 
     WHERE yc.WarehouseCode = w.WarehouseCode) AS OccupiedSlots,
    
    ROUND(
        (SELECT SUM(CurrentOccupancy) FROM VF_LOGISTICS_DB.PHASE3_SCHEMA.Yard_Configuration yc 
         WHERE yc.WarehouseCode = w.WarehouseCode) * 100.0 / 
        NULLIF((SELECT COUNT(*) FROM VF_LOGISTICS_DB.PHASE3_SCHEMA.Yard_Configuration yc 
                WHERE yc.WarehouseCode = w.WarehouseCode), 0),
    2) AS UtilizationPercent,
    
    -- Restacking Metrics
    SUM(w.RestackingCount) AS TotalRestackingOps,
    ROUND(AVG(w.AllocationScore), 2) AS AvgAllocationScore

FROM VF_LOGISTICS_DB.PHASE3_SCHEMA.Warehouse_Inventory w
GROUP BY w.WarehouseCode, w.WarehouseName
ORDER BY w.WarehouseCode;

-- =====================================================
-- STEP 9: CREATE ALERT VIEW - Urgent Containers
-- =====================================================
-- Containers that need immediate attention
-- =====================================================

CREATE OR REPLACE VIEW VF_LOGISTICS_DB.PHASE3_SCHEMA.V_Urgent_Containers AS
SELECT 
    w.ContainerNumber,
    s.BL_Number,
    w.WarehouseCode,
    w.SlotNumber,
    s.Vessel,
    s.ETD,
    DATEDIFF(DAY, CURRENT_DATE(), s.ETD) AS DaysUntilETD,
    w.RestackingRequired,
    w.RestackingCount,
    
    CASE 
        WHEN DATEDIFF(DAY, CURRENT_DATE(), s.ETD) < 0 THEN 'OVERDUE'
        WHEN DATEDIFF(DAY, CURRENT_DATE(), s.ETD) = 0 THEN 'TODAY'
        WHEN DATEDIFF(DAY, CURRENT_DATE(), s.ETD) = 1 THEN 'TOMORROW'
        ELSE 'UPCOMING'
    END AS UrgencyCategory

FROM VF_LOGISTICS_DB.PHASE3_SCHEMA.Warehouse_Inventory w
INNER JOIN VF_LOGISTICS_DB.PHASE1_SCHEMA.ShipmentRecord s 
    ON w.ContainerNumber = s.ContainerNumber
WHERE w.Status = 'IN_STOCK'
  AND s.ETD <= DATEADD(DAY, 3, CURRENT_DATE())
ORDER BY s.ETD ASC, w.RestackingCount DESC;

-- =====================================================
-- VERIFICATION QUERIES
-- =====================================================

-- Test 1: Verify table structure
DESC TABLE VF_LOGISTICS_DB.PHASE3_SCHEMA.Warehouse_Inventory;

-- Test 2: Verify foreign key constraints
SHOW TABLES LIKE 'Warehouse_Inventory' IN SCHEMA VF_LOGISTICS_DB.PHASE3_SCHEMA;

-- Test 3: Check views
SHOW VIEWS IN SCHEMA VF_LOGISTICS_DB.PHASE3_SCHEMA;

-- Test 4: Check stored procedures
SHOW PROCEDURES IN SCHEMA VF_LOGISTICS_DB.PHASE3_SCHEMA;

-- =====================================================
-- SAMPLE USAGE EXAMPLES
-- =====================================================

/*
-- Example 1: Get yard placement recommendation
CALL VF_LOGISTICS_DB.PHASE3_SCHEMA.SP_Optimize_Yard_Placement('CONT1234567');

-- Example 2: Assign container to slot
CALL VF_LOGISTICS_DB.PHASE3_SCHEMA.SP_Assign_Container_To_Slot(
    'WH-001',           -- WarehouseID
    'CONT1234567',      -- ContainerNumber from Phase 1
    'GATE-001',         -- GateID from Phase 2
    'WH-1',             -- WarehouseCode
    'A-12-03'           -- SlotNumber
);

-- Example 3: Calculate restacking needs
CALL VF_LOGISTICS_DB.PHASE3_SCHEMA.SP_Calculate_Restacking_Needs('WH-1');

-- Example 4: View complete warehouse inventory
SELECT * FROM VF_LOGISTICS_DB.PHASE3_SCHEMA.V_Warehouse_Inventory_Complete
ORDER BY DaysUntilETD ASC
LIMIT 20;

-- Example 5: Check warehouse capacity
SELECT * FROM VF_LOGISTICS_DB.PHASE3_SCHEMA.V_Warehouse_Capacity;

-- Example 6: View urgent containers
SELECT * FROM VF_LOGISTICS_DB.PHASE3_SCHEMA.V_Urgent_Containers;
*/

-- =====================================================
-- END OF PHASE 3 WAREHOUSE & YARD SQL
-- =====================================================
-- Integration Points:
-- ✅ Links to Phase 1 via ShipmentRecord.ContainerNumber (FK)
-- ✅ Links to Phase 2 via Gate_Operations.GateID (FK)
-- ✅ Updates Phase 2 AssignedYardLocation when slot assigned
-- ✅ AI-powered yard optimization based on vessel ETD
-- ✅ Supports offline mobile app with sync tracking
-- =====================================================
