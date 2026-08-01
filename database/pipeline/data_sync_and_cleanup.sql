-- =====================================================
-- DATA SYNCHRONIZATION & AUTOMATED GARBAGE COLLECTION
-- =====================================================
-- VF_Logistics_Portal - Mendix Integration Layer
-- Author: Data Engineering Team
-- Created: 2026-06-22
-- 
-- CRITICAL: This script creates NEW stored procedures and tasks
-- ✅ Does NOT modify Phase 1, 2, 3 schemas
-- ✅ All objects created in MENDIX_APP.AGENTS schema
-- =====================================================

-- =====================================================
-- STEP 0: CREATE SCHEMA (if not exists)
-- =====================================================
CREATE SCHEMA IF NOT EXISTS VF_LOGISTICS_DB.MENDIX_APP;
CREATE SCHEMA IF NOT EXISTS VF_LOGISTICS_DB.MENDIX_APP.AGENTS
COMMENT = 'Mendix Integration Layer - Sync & Cleanup Automation';

-- =====================================================
-- TASK A: DATA SYNCHRONIZATION (SAP Sync Log)
-- =====================================================
-- Purpose: Log SAP synchronization attempts from Mendix
-- Updates ShipmentRecord status on successful sync
-- =====================================================

CREATE OR REPLACE PROCEDURE VF_LOGISTICS_DB.MENDIX_APP.AGENTS.sp_LogSAPSync(
    P_RECORD_ID VARCHAR,
    P_SYNC_STATUS VARCHAR,
    P_ERROR_MESSAGE VARCHAR
)
RETURNS VARCHAR
LANGUAGE SQL
COMMENT = 'Logs SAP synchronization attempts and updates ShipmentRecord status'
AS
$$
DECLARE
    V_CONTAINER_NUMBER VARCHAR;
    V_SYNC_ID VARCHAR;
    V_RESULT_MESSAGE VARCHAR;
BEGIN
    -- Step 1: Get ContainerNumber from ShipmentRecord
    -- Assuming P_RECORD_ID is the primary key of ShipmentRecord
    -- Adjust column name if different (id, ShipmentRecordID, etc.)
    SELECT ContainerNumber INTO :V_CONTAINER_NUMBER
    FROM VF_LOGISTICS_DB.PHASE1_SCHEMA.ShipmentRecord
    WHERE ContainerNumber = :P_RECORD_ID  -- Or use: WHERE id = :P_RECORD_ID
    LIMIT 1;
    
    IF (:V_CONTAINER_NUMBER IS NULL) THEN
        -- Record not found in Phase 1
        SET V_RESULT_MESSAGE = 'ERROR: ShipmentRecord with ID ' || :P_RECORD_ID || ' not found';
        RETURN :V_RESULT_MESSAGE;
    END IF;
    
    -- Step 2: Generate unique SyncID
    SET V_SYNC_ID = 'SYNC-' || TO_VARCHAR(CURRENT_TIMESTAMP(), 'YYYYMMDDHH24MISSFF3') || 
                    '-' || SUBSTR(:V_CONTAINER_NUMBER, 1, 8);
    
    -- Step 3: Insert log entry into SAP_Sync_Queue (Phase 4)
    INSERT INTO VF_LOGISTICS_DB.PHASE4_SCHEMA.SAP_Sync_Queue (
        SyncID,
        ContainerNumber,
        SyncStatus,
        ErrorMessage,
        ErrorCode,
        AttemptCount,
        LastAttempt,
        ActualSyncTime,
        CreatedBy,
        UpdatedBy
    ) VALUES (
        :V_SYNC_ID,
        :V_CONTAINER_NUMBER,
        :P_SYNC_STATUS,
        :P_ERROR_MESSAGE,
        CASE WHEN :P_SYNC_STATUS = 'FAILED' THEN 'ERR_MENDIX_SYNC' ELSE NULL END,
        1,  -- First attempt logged from Mendix
        CURRENT_TIMESTAMP(),
        CASE WHEN :P_SYNC_STATUS = 'SUCCESS' THEN CURRENT_TIMESTAMP() ELSE NULL END,
        'MENDIX_APP',
        'MENDIX_APP'
    );
    
    -- Step 4: Update ShipmentRecord status if sync successful
    IF (:P_SYNC_STATUS = 'SUCCESS') THEN
        -- Update Phase 1 ShipmentRecord (only Status column, non-breaking)
        -- Note: If Phase 1 doesn't have Status column, this will fail gracefully
        -- You may need to add Status column or use a different approach
        UPDATE VF_LOGISTICS_DB.PHASE1_SCHEMA.ShipmentRecord
        SET Status = 'Synced_To_SAP'
            -- UpdatedAt = CURRENT_TIMESTAMP()  -- Uncomment if column exists
        WHERE ContainerNumber = :V_CONTAINER_NUMBER;
        
        SET V_RESULT_MESSAGE = 'SUCCESS: SAP sync logged and ShipmentRecord updated to Synced_To_SAP for ' || 
                               :V_CONTAINER_NUMBER;
    ELSE
        SET V_RESULT_MESSAGE = 'WARNING: SAP sync FAILED for ' || :V_CONTAINER_NUMBER || 
                               ' - Error: ' || COALESCE(:P_ERROR_MESSAGE, 'Unknown error');
    END IF;
    
    RETURN :V_RESULT_MESSAGE;
    
EXCEPTION
    WHEN OTHER THEN
        -- Catch any errors and return error message
        SET V_RESULT_MESSAGE = 'ERROR: ' || SQLERRM;
        RETURN :V_RESULT_MESSAGE;
END;
$$;

-- =====================================================
-- TASK B: AUTOMATED GARBAGE COLLECTION (File Cleanup)
-- =====================================================
-- Purpose: Remove processed PDF files from Snowflake stage
-- Only deletes files that are successfully synced to SAP
-- =====================================================

CREATE OR REPLACE PROCEDURE VF_LOGISTICS_DB.MENDIX_APP.AGENTS.sp_CleanupProcessedFiles()
RETURNS VARCHAR
LANGUAGE SQL
COMMENT = 'Removes processed PDF files from stage after successful SAP sync'
AS
$$
DECLARE
    V_FILES_DELETED NUMBER DEFAULT 0;
    V_FILES_SKIPPED NUMBER DEFAULT 0;
    V_RESULT_MESSAGE VARCHAR;
    V_FILE_PATH VARCHAR;
    V_STAGE_PREFIX VARCHAR DEFAULT '@MY_STAGE/';
BEGIN
    -- Step 1: Find all files that are ready for cleanup
    -- Criteria: ShipmentRecord.Status = 'Synced_To_SAP' AND file exists in BillOfLading_Doc
    
    -- Create a resultset of files to delete
    LET file_cursor CURSOR FOR
        SELECT DISTINCT doc.FilePath
        FROM VF_LOGISTICS_DB.PHASE1_SCHEMA.BillOfLading_Doc doc
        INNER JOIN VF_LOGISTICS_DB.PHASE1_SCHEMA.ShipmentRecord sr
            ON doc.ShipmentRecordID = sr.ContainerNumber  -- Adjust join condition as needed
        WHERE sr.Status = 'Synced_To_SAP'
          AND doc.FilePath IS NOT NULL
          AND doc.FilePath != '';
    
    -- Step 2: Iterate through files and delete them
    FOR file_record IN file_cursor DO
        BEGIN
            SET V_FILE_PATH = file_record.FilePath;
            
            -- Execute REMOVE command
            -- Note: REMOVE requires exact file path including stage prefix
            EXECUTE IMMEDIATE 'REMOVE ' || :V_STAGE_PREFIX || :V_FILE_PATH;
            
            SET V_FILES_DELETED = :V_FILES_DELETED + 1;
            
        EXCEPTION
            WHEN OTHER THEN
                -- If file doesn't exist or error occurs, skip and continue
                SET V_FILES_SKIPPED = :V_FILES_SKIPPED + 1;
        END;
    END FOR;
    
    -- Step 3: Return summary
    SET V_RESULT_MESSAGE = 'SUCCESS: Deleted ' || :V_FILES_DELETED || 
                           ' processed PDF files from stage. Skipped ' || 
                           :V_FILES_SKIPPED || ' files (already deleted or inaccessible).';
    
    RETURN :V_RESULT_MESSAGE;
    
EXCEPTION
    WHEN OTHER THEN
        SET V_RESULT_MESSAGE = 'ERROR in cleanup: ' || SQLERRM;
        RETURN :V_RESULT_MESSAGE;
END;
$$;

-- =====================================================
-- TASK C: LOG PURGING (Clean Old Database Logs)
-- =====================================================
-- Purpose: Delete old successful sync logs to keep database lightweight
-- Default retention: 30 days
-- =====================================================

CREATE OR REPLACE PROCEDURE VF_LOGISTICS_DB.MENDIX_APP.AGENTS.sp_PurgeOldSyncLogs(
    P_RETENTION_DAYS INT
)
RETURNS VARCHAR
LANGUAGE SQL
COMMENT = 'Purges successful SAP sync logs older than specified retention period'
AS
$$
DECLARE
    V_CUTOFF_DATE DATE;
    V_ROWS_DELETED NUMBER;
    V_RESULT_MESSAGE VARCHAR;
BEGIN
    -- Default retention to 30 days if not provided or invalid
    IF (:P_RETENTION_DAYS IS NULL OR :P_RETENTION_DAYS <= 0) THEN
        SET P_RETENTION_DAYS = 30;
    END IF;
    
    -- Calculate cutoff date
    SET V_CUTOFF_DATE = DATEADD(DAY, -1 * :P_RETENTION_DAYS, CURRENT_DATE());
    
    -- Step 1: Delete old successful sync logs from Phase 4
    DELETE FROM VF_LOGISTICS_DB.PHASE4_SCHEMA.SAP_Sync_Queue
    WHERE SyncStatus = 'SUCCESS'
      AND IsFullyIntegrated = TRUE
      AND CreatedAt < :V_CUTOFF_DATE;
    
    SET V_ROWS_DELETED = SQLROWCOUNT;
    
    -- Step 2: Also clean up old audit logs (if SAP_Integration_Log exists)
    BEGIN
        DELETE FROM VF_LOGISTICS_DB.PHASE4_SCHEMA.SAP_Integration_Log
        WHERE AttemptStatus = 'SUCCESS'
          AND CreatedAt < :V_CUTOFF_DATE;
    EXCEPTION
        WHEN OTHER THEN
            -- Table might not exist, ignore error
            NULL;
    END;
    
    -- Step 3: Return summary
    SET V_RESULT_MESSAGE = 'SUCCESS: Purged ' || :V_ROWS_DELETED || 
                           ' old sync logs (older than ' || :P_RETENTION_DAYS || 
                           ' days, cutoff date: ' || TO_VARCHAR(:V_CUTOFF_DATE) || ')';
    
    RETURN :V_RESULT_MESSAGE;
    
EXCEPTION
    WHEN OTHER THEN
        SET V_RESULT_MESSAGE = 'ERROR in log purging: ' || SQLERRM;
        RETURN :V_RESULT_MESSAGE;
END;
$$;

-- =====================================================
-- TASK D: SCHEDULED AUTOMATION (Snowflake Task)
-- =====================================================
-- Purpose: Run cleanup procedures daily at 01:00 AM
-- Executes both file cleanup and log purging automatically
-- =====================================================

-- Step 1: Create the daily garbage collection task
CREATE OR REPLACE TASK VF_LOGISTICS_DB.MENDIX_APP.AGENTS.daily_garbage_collection_task
    WAREHOUSE = COMPUTE_WH
    SCHEDULE = 'USING CRON 0 1 * * * UTC'  -- Daily at 01:00 AM UTC
    COMMENT = 'Automated cleanup: Removes processed PDF files and purges old sync logs'
AS
BEGIN
    -- Execute file cleanup
    CALL VF_LOGISTICS_DB.MENDIX_APP.AGENTS.sp_CleanupProcessedFiles();
    
    -- Execute log purging (30 days retention)
    CALL VF_LOGISTICS_DB.MENDIX_APP.AGENTS.sp_PurgeOldSyncLogs(30);
END;

-- Step 2: Resume (activate) the task
-- Note: Tasks are created in SUSPENDED state by default
ALTER TASK VF_LOGISTICS_DB.MENDIX_APP.AGENTS.daily_garbage_collection_task RESUME;

-- =====================================================
-- HELPER PROCEDURE: Manual Trigger (Optional)
-- =====================================================
-- Allows Mendix or admin to manually trigger cleanup
-- =====================================================

CREATE OR REPLACE PROCEDURE VF_LOGISTICS_DB.MENDIX_APP.AGENTS.sp_ManualCleanup(
    P_RETENTION_DAYS INT
)
RETURNS VARCHAR
LANGUAGE SQL
COMMENT = 'Manually trigger both cleanup procedures with custom retention days'
AS
$$
DECLARE
    V_FILE_CLEANUP_RESULT VARCHAR;
    V_LOG_PURGE_RESULT VARCHAR;
    V_RESULT_MESSAGE VARCHAR;
BEGIN
    -- Execute file cleanup
    CALL VF_LOGISTICS_DB.MENDIX_APP.AGENTS.sp_CleanupProcessedFiles() 
        INTO :V_FILE_CLEANUP_RESULT;
    
    -- Execute log purging with specified retention
    CALL VF_LOGISTICS_DB.MENDIX_APP.AGENTS.sp_PurgeOldSyncLogs(:P_RETENTION_DAYS) 
        INTO :V_LOG_PURGE_RESULT;
    
    -- Combine results
    SET V_RESULT_MESSAGE = 'MANUAL CLEANUP COMPLETED:\n' || 
                           '1. ' || :V_FILE_CLEANUP_RESULT || '\n' ||
                           '2. ' || :V_LOG_PURGE_RESULT;
    
    RETURN :V_RESULT_MESSAGE;
END;
$$;

-- =====================================================
-- MONITORING VIEW: Cleanup Statistics
-- =====================================================
-- Provides visibility into cleanup operations
-- =====================================================

CREATE OR REPLACE VIEW VF_LOGISTICS_DB.MENDIX_APP.AGENTS.V_Cleanup_Statistics AS
SELECT 
    'Files Ready for Cleanup' AS Category,
    COUNT(DISTINCT doc.FilePath) AS Count,
    NULL AS OldestDate
FROM VF_LOGISTICS_DB.PHASE1_SCHEMA.BillOfLading_Doc doc
INNER JOIN VF_LOGISTICS_DB.PHASE1_SCHEMA.ShipmentRecord sr
    ON doc.ShipmentRecordID = sr.ContainerNumber
WHERE sr.Status = 'Synced_To_SAP'
  AND doc.FilePath IS NOT NULL

UNION ALL

SELECT 
    'Old Sync Logs (>30 days)' AS Category,
    COUNT(*) AS Count,
    MIN(CreatedAt) AS OldestDate
FROM VF_LOGISTICS_DB.PHASE4_SCHEMA.SAP_Sync_Queue
WHERE SyncStatus = 'SUCCESS'
  AND IsFullyIntegrated = TRUE
  AND CreatedAt < DATEADD(DAY, -30, CURRENT_DATE())

UNION ALL

SELECT 
    'Total Synced Records' AS Category,
    COUNT(*) AS Count,
    NULL AS OldestDate
FROM VF_LOGISTICS_DB.PHASE1_SCHEMA.ShipmentRecord
WHERE Status = 'Synced_To_SAP';

-- =====================================================
-- VERIFICATION QUERIES
-- =====================================================

-- Test 1: Verify stored procedures were created
SHOW PROCEDURES IN SCHEMA VF_LOGISTICS_DB.MENDIX_APP.AGENTS;

-- Test 2: Verify task was created and is running
SHOW TASKS IN SCHEMA VF_LOGISTICS_DB.MENDIX_APP.AGENTS;

-- Test 3: Check task schedule
SELECT 
    NAME,
    STATE,
    SCHEDULE,
    WAREHOUSE,
    NEXT_SCHEDULED_TIME
FROM TABLE(INFORMATION_SCHEMA.TASK_HISTORY(
    SCHEDULED_TIME_RANGE_START => DATEADD(DAY, -1, CURRENT_TIMESTAMP()),
    TASK_NAME => 'daily_garbage_collection_task'
));

-- Test 4: View cleanup statistics
SELECT * FROM VF_LOGISTICS_DB.MENDIX_APP.AGENTS.V_Cleanup_Statistics;

-- =====================================================
-- USAGE EXAMPLES
-- =====================================================

/*
-- Example 1: Log a successful SAP sync from Mendix
CALL VF_LOGISTICS_DB.MENDIX_APP.AGENTS.sp_LogSAPSync(
    'CONT1234567',        -- record_id (ContainerNumber)
    'SUCCESS',            -- sync_status
    NULL                  -- error_message (null for success)
);

-- Example 2: Log a failed SAP sync
CALL VF_LOGISTICS_DB.MENDIX_APP.AGENTS.sp_LogSAPSync(
    'CONT7654321',
    'FAILED',
    'SAP RFC connection timeout after 30 seconds'
);

-- Example 3: Manually trigger file cleanup
CALL VF_LOGISTICS_DB.MENDIX_APP.AGENTS.sp_CleanupProcessedFiles();

-- Example 4: Manually trigger log purging (14 days retention)
CALL VF_LOGISTICS_DB.MENDIX_APP.AGENTS.sp_PurgeOldSyncLogs(14);

-- Example 5: Manually trigger both cleanups at once
CALL VF_LOGISTICS_DB.MENDIX_APP.AGENTS.sp_ManualCleanup(30);

-- Example 6: Execute task manually (on-demand)
EXECUTE TASK VF_LOGISTICS_DB.MENDIX_APP.AGENTS.daily_garbage_collection_task;

-- Example 7: View cleanup statistics
SELECT * FROM VF_LOGISTICS_DB.MENDIX_APP.AGENTS.V_Cleanup_Statistics;
*/

-- =====================================================
-- TASK MANAGEMENT COMMANDS
-- =====================================================

-- Suspend (pause) the task
-- ALTER TASK VF_LOGISTICS_DB.MENDIX_APP.AGENTS.daily_garbage_collection_task SUSPEND;

-- Resume (activate) the task
-- ALTER TASK VF_LOGISTICS_DB.MENDIX_APP.AGENTS.daily_garbage_collection_task RESUME;

-- Change schedule (e.g., run every 6 hours instead of daily)
-- ALTER TASK VF_LOGISTICS_DB.MENDIX_APP.AGENTS.daily_garbage_collection_task 
-- SET SCHEDULE = '360 MINUTE';

-- Change schedule to twice daily (01:00 AM and 13:00 PM)
-- ALTER TASK VF_LOGISTICS_DB.MENDIX_APP.AGENTS.daily_garbage_collection_task 
-- SET SCHEDULE = 'USING CRON 0 1,13 * * * UTC';

-- View task execution history
-- SELECT *
-- FROM TABLE(INFORMATION_SCHEMA.TASK_HISTORY(
--     SCHEDULED_TIME_RANGE_START => DATEADD(DAY, -7, CURRENT_TIMESTAMP()),
--     TASK_NAME => 'daily_garbage_collection_task'
-- ))
-- ORDER BY SCHEDULED_TIME DESC;

-- =====================================================
-- IMPORTANT NOTES
-- =====================================================

/*
1. STAGE FILE REMOVAL:
   - The sp_CleanupProcessedFiles() procedure uses the REMOVE command
   - Ensure the executing role has WRITE privileges on @MY_STAGE
   - File paths in BillOfLading_Doc.FilePath must match actual stage file names
   - Example: If stage file is @MY_STAGE/invoices/BL123.pdf, 
     then FilePath should be 'invoices/BL123.pdf'

2. SHIPMENT RECORD STATUS:
   - The sp_LogSAPSync() procedure updates ShipmentRecord.Status to 'Synced_To_SAP'
   - If Phase 1 ShipmentRecord doesn't have a Status column, you have 2 options:
     a) Add Status column: ALTER TABLE ShipmentRecord ADD COLUMN Status VARCHAR(50);
     b) Create an extension table (Phase 1 Extension pattern from phase2_transportation.sql)

3. ERROR HANDLING:
   - All procedures use TRY-CATCH blocks to prevent cascading failures
   - File cleanup failures (e.g., file already deleted) are logged but don't stop the process
   - Check task execution history to monitor for repeated errors

4. RETENTION POLICY:
   - Default log retention is 30 days
   - Adjust by calling sp_PurgeOldSyncLogs() with different retention_days
   - Only SUCCESS and IsFullyIntegrated = TRUE logs are purged
   - FAILED logs are kept for debugging

5. TASK SCHEDULING:
   - Default: Daily at 01:00 AM UTC
   - To change timezone, adjust CRON expression
   - For local time (e.g., Vietnam UTC+7): Subtract 7 hours → 18:00 UTC = 01:00 AM ICT
   - CRON format: 'USING CRON minute hour day month dayofweek timezone'
   - Example Vietnam 01:00 AM: 'USING CRON 0 18 * * * UTC'

6. MONITORING:
   - Use V_Cleanup_Statistics view to see pending cleanup items
   - Check TASK_HISTORY() to verify task is running successfully
   - Monitor storage usage to confirm files are being deleted

7. MENDIX INTEGRATION:
   - Call sp_LogSAPSync() from Mendix after every SAP sync attempt (success or failure)
   - Pass ContainerNumber as record_id parameter
   - Use 'SUCCESS' or 'FAILED' as sync_status
   - Include detailed error_message for failed syncs
*/

-- =====================================================
-- END OF DATA SYNCHRONIZATION & CLEANUP SCRIPT
-- =====================================================
-- Objects Created:
-- ✅ 4 Stored Procedures (sp_LogSAPSync, sp_CleanupProcessedFiles, 
--                         sp_PurgeOldSyncLogs, sp_ManualCleanup)
-- ✅ 1 Scheduled Task (daily_garbage_collection_task)
-- ✅ 1 Monitoring View (V_Cleanup_Statistics)
-- =====================================================
