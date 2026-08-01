# VF_LOGISTICS_PORTAL - CURRENT DATABASE STRUCTURE

## 📊 FULL SYSTEM OVERVIEW

This is the **COMPLETE** database structure for VF_Logistics_Portal, including Phase 1 (existing) and Phase 2-4 (newly created).

---

## 🗄️ DATABASE HIERARCHY

```
VF_LOGISTICS_DB
├── PHASE1_SCHEMA (Existing - DO NOT MODIFY)
│   ├── ShipmentRecord (Table)
│   ├── BillOfLading_Doc (Table)
│   └── ShipmentRecord_BillOfLading_Doc (Association)
│
├── PHASE2_SCHEMA (NEW - Transportation & Gate)
│   ├── Tables (2)
│   │   ├── Gate_Operations
│   │   └── ShipmentRecord_Transportation_Extension
│   ├── Views (3)
│   │   ├── V_Gate_Operations_WithShipment
│   │   ├── V_Active_Trucks_In_Yard
│   │   └── V_Daily_Gate_Statistics
│   └── Stored Procedures (2)
│       ├── SP_Match_GateOperation_To_Shipment
│       └── SP_Record_GateOut
│
├── PHASE3_SCHEMA (NEW - Warehouse & Yard)
│   ├── Tables (2)
│   │   ├── Warehouse_Inventory
│   │   └── Yard_Configuration
│   ├── Views (3)
│   │   ├── V_Warehouse_Inventory_Complete
│   │   ├── V_Warehouse_Capacity
│   │   └── V_Urgent_Containers
│   └── Stored Procedures (3)
│       ├── SP_Optimize_Yard_Placement
│       ├── SP_Assign_Container_To_Slot
│       └── SP_Calculate_Restacking_Needs
│
├── PHASE4_SCHEMA (NEW - SAP Integration)
│   ├── Tables (2)
│   │   ├── SAP_Sync_Queue
│   │   └── SAP_Integration_Log
│   ├── Views (4)
│   │   ├── V_SAP_Sync_Complete
│   │   ├── V_SAP_Sync_Dashboard
│   │   ├── V_Failed_SAP_Syncs
│   │   └── V_End_To_End_Pipeline_Status
│   └── Stored Procedures (3)
│       ├── SP_Enqueue_SAP_Sync
│       ├── SP_Update_SAP_Sync_Status
│       └── SP_Get_Pending_SAP_Syncs
│
└── MENDIX_APP
    └── AGENTS (NEW - Automation Layer)
        ├── Views (1)
        │   └── V_Cleanup_Statistics
        └── Stored Procedures (4) + Task (1)
            ├── sp_LogSAPSync
            ├── sp_CleanupProcessedFiles
            ├── sp_PurgeOldSyncLogs
            ├── sp_ManualCleanup
            └── daily_garbage_collection_task (TASK)
```

---

## 📋 SCHEMA DETAILS

### 🔴 PHASE1_SCHEMA (EXISTING - DO NOT MODIFY)

**Status**: ✅ Already exists, working well  
**Purpose**: Bill of Lading PDF extraction with Cortex AI

#### Tables

**1. ShipmentRecord**
```sql
Primary Key: ContainerNumber VARCHAR(50)
Columns:
  - ContainerNumber VARCHAR(50) [PK]
  - BL_Number VARCHAR(100)
  - Shipper VARCHAR
  - Consignee VARCHAR
  - Vessel VARCHAR(200)
  - ETD DATE (Used by Phase 3 AI optimization)
  - ETA DATE
  - Status VARCHAR(50) -- IMPORTANT: Required for Phase 4 sync
```

**2. BillOfLading_Doc**
```sql
Purpose: Stores PDF file metadata
Columns:
  - ShipmentRecordID (Links to ShipmentRecord)
  - FilePath VARCHAR -- Path in @MY_STAGE
  - ... (other columns)
```

**3. ShipmentRecord_BillOfLading_Doc**
```sql
Purpose: Association table
Type: Many-to-Many relationship
```

**⚠️ CRITICAL NOTES:**
- **CORTEX.EXTRACT_ANSWER** SQL logic = 100% UNTOUCHED
- All Phase 2-4 objects **READ-ONLY** access to Phase 1
- If `Status` column doesn't exist in ShipmentRecord, you MUST add it:
  ```sql
  ALTER TABLE VF_LOGISTICS_DB.PHASE1_SCHEMA.ShipmentRecord 
  ADD COLUMN Status VARCHAR(50) DEFAULT 'Pending';
  ```

---

### 🟢 PHASE2_SCHEMA (NEW - Transportation & Gate Management)

**Purpose**: Manages gate-in/gate-out, Zalo Bot, QR code scanning

#### Tables (2)

**1. Gate_Operations**
```sql
CREATE TABLE VF_LOGISTICS_DB.PHASE2_SCHEMA.Gate_Operations (
    -- Primary Key
    GateID VARCHAR(50) PRIMARY KEY,
    
    -- Foreign Key to Phase 1
    ContainerNumber VARCHAR(50) NOT NULL,
    CONSTRAINT FK_Gate_Operations_ShipmentRecord 
        FOREIGN KEY (ContainerNumber) 
        REFERENCES PHASE1_SCHEMA.ShipmentRecord(ContainerNumber),
    
    -- Truck & Driver
    PlateNumber VARCHAR(20) NOT NULL,
    DriverPhone VARCHAR(20),
    DriverName VARCHAR(200),
    TruckingCompany VARCHAR(300),
    
    -- Gate Transaction
    GateNumber VARCHAR(10),
    InTime TIMESTAMP_NTZ,
    OutTime TIMESTAMP_NTZ,
    Status VARCHAR(20) DEFAULT 'IN_YARD',
    
    -- Container Details
    ContainerType VARCHAR(20),
    ContainerCondition VARCHAR(20),
    SealNumber VARCHAR(50),
    
    -- Location (populated by Phase 3)
    AssignedYardLocation VARCHAR(50),
    
    -- Anonymous Portal & QR
    QRCodeScanned BOOLEAN DEFAULT FALSE,
    QRScanTimestamp TIMESTAMP_NTZ,
    PortalSessionID VARCHAR(100),
    
    -- Zalo Bot
    ZaloMessageSent BOOLEAN DEFAULT FALSE,
    ZaloMessageID VARCHAR(100),
    ZaloMessageTimestamp TIMESTAMP_NTZ,
    
    -- Computed Duration
    DurationMinutes NUMBER(10,2) AS (
        DATEDIFF(MINUTE, InTime, COALESCE(OutTime, CURRENT_TIMESTAMP()))
    ),
    
    -- Audit
    CreatedAt TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    UpdatedAt TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);
```

**Indexes:**
- `IDX_Gate_Operations_ContainerNumber`
- `IDX_Gate_Operations_InTime`
- `IDX_Gate_Operations_Status`

**2. ShipmentRecord_Transportation_Extension**
```sql
Purpose: 1-to-1 extension for transportation-specific data
1-to-1 with ShipmentRecord via ContainerNumber FK
Columns:
  - PreferredTruckingCompany
  - TransportationPriority
  - CustomsClearanceRequired
  - DeliveryInstructions
  - TransportationCostVND
```

#### Views (3)

1. **V_Gate_Operations_WithShipment** - JOIN Phase 1 + Phase 2
2. **V_Active_Trucks_In_Yard** - Real-time yard occupancy
3. **V_Daily_Gate_Statistics** - Daily metrics

#### Stored Procedures (2)

1. **SP_Match_GateOperation_To_Shipment(gate_id, container_number, plate_number)**
   - Validates container exists in Phase 1
   - Creates gate operation record

2. **SP_Record_GateOut(gate_id)**
   - Updates OutTime and Status = 'OUT_YARD'

---

### 🔵 PHASE3_SCHEMA (NEW - Warehouse & Yard Management)

**Purpose**: 7 DCs warehouse management, AI yard optimization

#### Tables (2)

**1. Warehouse_Inventory**
```sql
CREATE TABLE VF_LOGISTICS_DB.PHASE3_SCHEMA.Warehouse_Inventory (
    -- Primary Key
    WarehouseID VARCHAR(50) PRIMARY KEY,
    
    -- Foreign Keys
    ContainerNumber VARCHAR(50) NOT NULL,
    CONSTRAINT FK_Warehouse_Inventory_ShipmentRecord 
        FOREIGN KEY (ContainerNumber) 
        REFERENCES PHASE1_SCHEMA.ShipmentRecord(ContainerNumber),
    
    GateID VARCHAR(50),
    CONSTRAINT FK_Warehouse_Inventory_GateOperations 
        FOREIGN KEY (GateID) 
        REFERENCES PHASE2_SCHEMA.Gate_Operations(GateID),
    
    -- Warehouse Location
    WarehouseCode VARCHAR(10) NOT NULL,  -- WH-1 to WH-7
    WarehouseName VARCHAR(200),
    ZoneType VARCHAR(20),
    SlotNumber VARCHAR(50),
    RowNumber VARCHAR(10),
    BayNumber VARCHAR(10),
    TierNumber VARCHAR(10),
    
    -- Container Details
    CargoType VARCHAR(100),
    WeightKG NUMBER(15,2),
    VolumeCBM NUMBER(15,2),
    TemperatureRequirement NUMBER(5,2),
    
    -- AI Allocation
    AllocatedByAI BOOLEAN DEFAULT FALSE,
    AllocationScore NUMBER(5,2),
    OptimalPosition BOOLEAN DEFAULT FALSE,
    
    -- Restacking
    RestackingRequired BOOLEAN DEFAULT FALSE,
    RestackingCount NUMBER(5,0) DEFAULT 0,
    LastRestackingDate TIMESTAMP_NTZ,
    
    -- Stock Status
    Status VARCHAR(30) DEFAULT 'IN_STOCK',
    StockInDate TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    StockOutDate TIMESTAMP_NTZ,
    
    -- Mobile App Offline Sync
    LastScannedAt TIMESTAMP_NTZ,
    ScannedBy VARCHAR(100),
    ScannedDeviceID VARCHAR(100),
    OfflineSyncFlag BOOLEAN DEFAULT FALSE,
    SyncedToCloudAt TIMESTAMP_NTZ,
    
    -- Loading Priority (from Phase 1 ETD)
    LoadingPriority NUMBER(3,0),
    ExpectedLoadingDate DATE,
    
    -- Audit
    CreatedAt TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    UpdatedAt TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);
```

**Indexes:**
- `IDX_Warehouse_Inventory_ContainerNumber`
- `IDX_Warehouse_Inventory_Status`
- `IDX_Warehouse_Inventory_WarehouseCode`
- `IDX_Warehouse_Inventory_LoadingDate`

**2. Yard_Configuration**
```sql
Purpose: Master data for yard slots (7 DCs)
Columns:
  - SlotID (PK)
  - WarehouseCode
  - SlotNumber
  - MaxTierHeight
  - ZoneType
  - HasPowerSupply (for reefer containers)
  - DistanceToGateMeters
  - IsAvailable
  - CurrentOccupancy
```

#### Views (3)

1. **V_Warehouse_Inventory_Complete** - Phase 1+2+3 joined
2. **V_Warehouse_Capacity** - Real-time 7 DCs capacity
3. **V_Urgent_Containers** - Containers loading within 3 days

#### Stored Procedures (3)

1. **SP_Optimize_Yard_Placement(container_number)**
   - AI recommendation based on Phase 1 ETD
   - Returns optimal SlotNumber with score

2. **SP_Assign_Container_To_Slot(warehouse_id, container_number, gate_id, warehouse_code, slot_number)**
   - Assigns container to slot
   - **Updates Phase 2** `AssignedYardLocation`

3. **SP_Calculate_Restacking_Needs(warehouse_code)**
   - Returns TABLE of containers needing restacking
   - Based on ETD ordering conflicts

---

### 🟡 PHASE4_SCHEMA (NEW - SAP ERP Integration)

**Purpose**: SAP sync queue, retry logic, financial tracking

#### Tables (2)

**1. SAP_Sync_Queue**
```sql
CREATE TABLE VF_LOGISTICS_DB.PHASE4_SCHEMA.SAP_Sync_Queue (
    -- Primary Key
    SyncID VARCHAR(50) PRIMARY KEY,
    
    -- Foreign Key to Phase 1
    ContainerNumber VARCHAR(50) NOT NULL,
    CONSTRAINT FK_SAP_Sync_Queue_ShipmentRecord 
        FOREIGN KEY (ContainerNumber) 
        REFERENCES PHASE1_SCHEMA.ShipmentRecord(ContainerNumber),
    
    -- References to other phases
    GateID VARCHAR(50),
    WarehouseID VARCHAR(50),
    
    -- SAP Documents
    SAP_MaterialDocument VARCHAR(20),
    SAP_SalesOrder VARCHAR(20),
    SAP_DeliveryNote VARCHAR(20),
    SAP_InvoiceNumber VARCHAR(20),
    
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
    SAP_RFC_Function VARCHAR(100),
    SAP_OData_Endpoint VARCHAR(500),
    SAP_RequestPayload VARIANT,
    SAP_ResponsePayload VARIANT,
    SAP_System VARCHAR(20),
    
    -- Financial Data
    InvoiceAmount NUMBER(15,2),
    Currency VARCHAR(3) DEFAULT 'VND',
    PaymentStatus VARCHAR(20),
    PaymentDueDate DATE,
    
    -- Zero-Copy SAP BDC
    SAP_BDC_Connected BOOLEAN DEFAULT FALSE,
    SAP_BDC_LastRead TIMESTAMP_NTZ,
    SAP_BDC_Data VARIANT,
    
    -- Business Flags
    IsFullyIntegrated BOOLEAN DEFAULT FALSE,
    RequiresManualIntervention BOOLEAN DEFAULT FALSE,
    
    -- Audit
    CreatedAt TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    UpdatedAt TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);
```

**Indexes:**
- `IDX_SAP_Sync_Queue_ContainerNumber`
- `IDX_SAP_Sync_Queue_SyncStatus`
- `IDX_SAP_Sync_Queue_NextRetry`
- `IDX_SAP_Sync_Queue_Priority`

**2. SAP_Integration_Log**
```sql
Purpose: Audit trail for all SAP sync attempts
Columns:
  - LogID (PK)
  - SyncID (FK to SAP_Sync_Queue)
  - AttemptNumber
  - RequestPayload (VARIANT)
  - ResponsePayload (VARIANT)
  - ResponseTime_MS
  - ErrorMessage
```

#### Views (4)

1. **V_SAP_Sync_Complete** - Phase 1+2+3+4 joined
2. **V_SAP_Sync_Dashboard** - KPIs, success rate, payment status
3. **V_Failed_SAP_Syncs** - Alerts for failed syncs
4. **V_End_To_End_Pipeline_Status** - **Complete journey Phase 1→4**

#### Stored Procedures (3)

1. **SP_Enqueue_SAP_Sync(sync_id, container_number, gate_id, warehouse_id, sap_system, priority)**
   - Validates container in Phase 1
   - Creates sync request

2. **SP_Update_SAP_Sync_Status(sync_id, status, sap_document, error_message)**
   - Updates sync status
   - Handles retry logic (exponential backoff)

3. **SP_Get_Pending_SAP_Syncs()**
   - Returns TABLE of ready-to-process syncs
   - Priority ordered

---

### 🟣 MENDIX_APP.AGENTS (NEW - Automation Layer)

**Purpose**: Mendix integration, automated cleanup

#### Stored Procedures (4)

**1. sp_LogSAPSync(record_id, sync_status, error_message)**
```sql
Purpose: Called by Mendix after every SAP sync
Flow:
  1. Validate container in Phase 1
  2. Insert log into Phase 4 SAP_Sync_Queue
  3. IF SUCCESS → Update ShipmentRecord.Status = 'Synced_To_SAP'
  4. Return success/error message
```

**2. sp_CleanupProcessedFiles()**
```sql
Purpose: Remove PDF files from @MY_STAGE
Flow:
  1. Find files WHERE Status = 'Synced_To_SAP'
  2. REMOVE @MY_STAGE/filename.pdf
  3. Skip if file not found (error handling)
  4. Return count of deleted files
```

**3. sp_PurgeOldSyncLogs(retention_days)**
```sql
Purpose: Delete old SUCCESS logs
Flow:
  1. Calculate cutoff_date = CURRENT_DATE - retention_days
  2. DELETE WHERE SyncStatus = 'SUCCESS' AND CreatedAt < cutoff_date
  3. Keep FAILED logs for debugging
  4. Return count of purged logs
```

**4. sp_ManualCleanup(retention_days)**
```sql
Purpose: Manual trigger for both cleanups
Calls: sp_CleanupProcessedFiles() + sp_PurgeOldSyncLogs()
```

#### Task (1)

**daily_garbage_collection_task**
```sql
Schedule: CRON 0 1 * * * UTC (Daily 01:00 AM)
Warehouse: COMPUTE_WH
State: RESUMED (active)
Actions:
  CALL sp_CleanupProcessedFiles();
  CALL sp_PurgeOldSyncLogs(30);
```

#### View (1)

**V_Cleanup_Statistics**
```sql
Returns:
  - Files Ready for Cleanup (count)
  - Old Sync Logs >30 days (count + oldest date)
  - Total Synced Records (count)
```

---

## 📊 SUMMARY STATISTICS

### Objects Count

| Schema | Tables | Views | Stored Procedures | Tasks | Total |
|--------|--------|-------|-------------------|-------|-------|
| **PHASE1_SCHEMA** | 3 | 0 | 0 | 0 | **3** |
| **PHASE2_SCHEMA** | 2 | 3 | 2 | 0 | **7** |
| **PHASE3_SCHEMA** | 2 | 3 | 3 | 0 | **8** |
| **PHASE4_SCHEMA** | 2 | 4 | 3 | 0 | **9** |
| **MENDIX_APP.AGENTS** | 0 | 1 | 4 | 1 | **6** |
| **TOTAL** | **9** | **11** | **12** | **1** | **33** |

### Foreign Key Relationships

```
ShipmentRecord.ContainerNumber [PK]
    ↑ Referenced by:
    ├── Gate_Operations.ContainerNumber (Phase 2)
    ├── Warehouse_Inventory.ContainerNumber (Phase 3)
    └── SAP_Sync_Queue.ContainerNumber (Phase 4)

Gate_Operations.GateID [PK]
    ↑ Referenced by:
    └── Warehouse_Inventory.GateID (Phase 3)

SAP_Sync_Queue.SyncID [PK]
    ↑ Referenced by:
    └── SAP_Integration_Log.SyncID (Phase 4)
```

### Indexes Summary

- **Phase 2**: 3 indexes
- **Phase 3**: 4 indexes
- **Phase 4**: 4 indexes
- **Total**: **11 performance indexes**

---

## 🔗 DATA FLOW

```
┌─────────────────────────────────────────────────────────┐
│ Phase 1: ShipmentRecord (Existing)                      │
│ • PDF → Cortex AI → Structured data                     │
│ • ContainerNumber, BL_Number, Vessel, ETD, ETA          │
└──────────────────┬──────────────────────────────────────┘
                   │ FK: ContainerNumber
                   ▼
┌─────────────────────────────────────────────────────────┐
│ Phase 2: Gate_Operations (NEW)                          │
│ • QR scan → Gate-in                                     │
│ • Zalo Bot notification                                 │
│ • AssignedYardLocation ← Updated by Phase 3             │
└──────────────────┬──────────────────────────────────────┘
                   │ FK: ContainerNumber + GateID
                   ▼
┌─────────────────────────────────────────────────────────┐
│ Phase 3: Warehouse_Inventory (NEW)                      │
│ • AI reads Phase 1 ETD → Optimize placement             │
│ • Assign to slot → Update Phase 2 location             │
│ • Minimize restacking                                   │
└──────────────────┬──────────────────────────────────────┘
                   │ FK: ContainerNumber + WarehouseID
                   ▼
┌─────────────────────────────────────────────────────────┐
│ Phase 4: SAP_Sync_Queue (NEW)                           │
│ • Enqueue sync request                                  │
│ • Retry logic (max 3 attempts)                          │
│ • Financial tracking                                    │
└──────────────────┬──────────────────────────────────────┘
                   │ Mendix calls sp_LogSAPSync
                   ▼
┌─────────────────────────────────────────────────────────┐
│ MENDIX_APP.AGENTS (NEW)                                 │
│ • sp_LogSAPSync → Update Phase 1 Status                │
│ • Daily cleanup → Remove PDF files                      │
│ • Daily purge → Delete old logs                         │
└─────────────────────────────────────────────────────────┘
```

---

## 🚀 DEPLOYMENT CHECKLIST

### Prerequisites
- [ ] Snowflake account with ACCOUNTADMIN role
- [ ] Warehouse: COMPUTE_WH (or create a new one)
- [ ] Stage: @MY_STAGE for PDF files
- [ ] Mendix JDBC connector configured

### Step-by-Step Deployment

**1. Deploy Phase 1 (If not exists)**
```sql
-- This is your existing Phase 1
-- Ensure ShipmentRecord, BillOfLading_Doc exist
-- Add Status column if missing:
ALTER TABLE VF_LOGISTICS_DB.PHASE1_SCHEMA.ShipmentRecord 
ADD COLUMN Status VARCHAR(50) DEFAULT 'Pending';
```

**2. Deploy Phase 2-4**
```sql
-- Run in order:
-- 1. phase2_transportation.sql (391 lines)
-- 2. phase3_warehouse_yard.sql (540 lines)
-- 3. phase4_sap_integration.sql (596 lines)
```

**3. Deploy Automation Layer**
```sql
-- 4. data_sync_and_cleanup.sql (479 lines)
```

**4. Grant Privileges**
```sql
-- Stage privileges
GRANT WRITE ON STAGE MY_STAGE TO ROLE MENDIX_APP_ROLE;

-- Warehouse privileges
GRANT USAGE ON WAREHOUSE COMPUTE_WH TO ROLE MENDIX_APP_ROLE;

-- Schema privileges
GRANT USAGE ON SCHEMA VF_LOGISTICS_DB.MENDIX_APP.AGENTS TO ROLE MENDIX_APP_ROLE;
```

**5. Verify Deployment**
```sql
-- Check all schemas
SHOW SCHEMAS IN DATABASE VF_LOGISTICS_DB;

-- Check all objects
SELECT 
    TABLE_SCHEMA,
    TABLE_TYPE,
    COUNT(*) AS COUNT
FROM VF_LOGISTICS_DB.INFORMATION_SCHEMA.TABLES
GROUP BY TABLE_SCHEMA, TABLE_TYPE
ORDER BY TABLE_SCHEMA, TABLE_TYPE;

-- Check task is running
SHOW TASKS IN SCHEMA VF_LOGISTICS_DB.MENDIX_APP.AGENTS;
```

---

## 📁 SQL FILES REFERENCE

| File | Lines | Purpose |
|------|-------|---------|
| **phase2_transportation.sql** | 391 | Phase 2 objects |
| **phase3_warehouse_yard.sql** | 540 | Phase 3 objects |
| **phase4_sap_integration.sql** | 596 | Phase 4 objects |
| **data_sync_and_cleanup.sql** | 479 | Mendix automation |
| **Total** | **2,006** | Complete system |

---

## ⚠️ IMPORTANT CONSTRAINTS

### 1. Phase 1 NON-REGRESSION
- ❌ **DO NOT** modify ShipmentRecord table structure (except Status column)
- ❌ **DO NOT** modify BillOfLading_Doc
- ❌ **DO NOT** touch CORTEX.EXTRACT_ANSWER logic
- ✅ **ONLY** read Phase 1 data via JOINs in views

### 2. Foreign Key Dependencies
- All Phase 2-4 tables depend on `ShipmentRecord.ContainerNumber`
- Cannot delete ShipmentRecord if referenced by Phase 2-4
- Cascade delete not enabled (explicit cleanup required)

### 3. Cross-Phase Updates
- Only Phase 3 writes to Phase 2 (`AssignedYardLocation`)
- Only MENDIX_APP writes to Phase 1 (`Status` column)
- All other relationships are read-only

---

## 🎯 USAGE PATTERNS

### Mendix Integration Points

**1. After PDF Extraction (Phase 1)**
```java
// No changes needed - existing Cortex AI logic works
```

**2. After SAP Sync (Phase 4 → Mendix)**
```java
// Call from Mendix
CALL VF_LOGISTICS_DB.MENDIX_APP.AGENTS.sp_LogSAPSync(
    containerNumber, 'SUCCESS', null
);
```

**3. Gate-In Event (Phase 2)**
```java
CALL VF_LOGISTICS_DB.PHASE2_SCHEMA.SP_Match_GateOperation_To_Shipment(
    gateId, containerNumber, plateNumber
);
```

**4. Warehouse Assignment (Phase 3)**
```java
// Get recommendation
CALL VF_LOGISTICS_DB.PHASE3_SCHEMA.SP_Optimize_Yard_Placement(
    containerNumber
);

// Assign to slot
CALL VF_LOGISTICS_DB.PHASE3_SCHEMA.SP_Assign_Container_To_Slot(
    warehouseId, containerNumber, gateId, warehouseCode, slotNumber
);
```

---

## 📞 SUPPORT

**Documentation Files:**
- `VF_LOGISTICS_EXPANSION_SUMMARY.md` - Phase 2-4 overview
- `DATA_SYNC_CLEANUP_GUIDE.md` - Automation guide
- `ARCHITECTURE_DIAGRAM.txt` - Visual architecture
- `SYNC_CLEANUP_FLOW_DIAGRAM.txt` - Flow diagrams

**Quick Links:**
- Phase 2: Transportation & Gate → `phase2_transportation.sql`
- Phase 3: Warehouse & Yard → `phase3_warehouse_yard.sql`
- Phase 4: SAP Integration → `phase4_sap_integration.sql`
- Automation Layer → `data_sync_and_cleanup.sql`

---

**Created**: 2026-06-22  
**Version**: 1.0  
**Status**: ✅ Production Ready  
**Total Objects**: 33 (9 tables, 11 views, 12 procedures, 1 task)
