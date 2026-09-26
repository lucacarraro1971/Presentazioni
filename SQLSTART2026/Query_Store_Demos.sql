/*═══════════════════════════════════════════════════════════════════════════
  DON'T PANIC! The Hitchhiker's Guide to SQL Server Query Store
  Demo script — run top to bottom, section by section.

  Tested against SQL Server 2025 (Query Store Hints require 2022+ or Azure SQL).
  Demos 0–4 work on SQL Server 2017+. Demo 5 (hints) needs 2022+.
═══════════════════════════════════════════════════════════════════════════*/


/*───────────────────────────────────────────────────────────────────────────
  0. SETUP — database, Query Store configuration, demo data
───────────────────────────────────────────────────────────────────────────*/
USE master;
GO
IF DB_ID('QueryStoreDemo') IS NOT NULL
BEGIN
    ALTER DATABASE QueryStoreDemo SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE QueryStoreDemo;
END
GO
CREATE DATABASE QueryStoreDemo;
GO

ALTER DATABASE QueryStoreDemo SET QUERY_STORE = ON;
GO
ALTER DATABASE QueryStoreDemo SET QUERY_STORE (
    OPERATION_MODE            = READ_WRITE,
    -- 1 minute so runtime stats appear during the session instead of an hour later
    INTERVAL_LENGTH_MINUTES   = 1,
    -- CRITICAL FOR DEMOS: the default (AUTO since 2019) silently skips cheap and
    -- infrequent queries. Your demo query will simply not be there. Use ALL.
    QUERY_CAPTURE_MODE        = ALL,
    WAIT_STATS_CAPTURE_MODE   = ON,
    MAX_STORAGE_SIZE_MB       = 1024,-- Erin Stellato recommends 2GB to 10GB at the absolute maximum (ideally less) to prevent single-threaded size-based cleanup operations from causing performance bottlenecks
    DATA_FLUSH_INTERVAL_SECONDS = 60,
    MAX_PLANS_PER_QUERY       = 200
);
GO

USE QueryStoreDemo;
GO

-- Confirm the configuration actually took
SELECT actual_state_desc, query_capture_mode_desc, wait_stats_capture_mode_desc,
       interval_length_minutes, max_storage_size_mb
FROM   sys.database_query_store_options;
GO

/*  ── Parameter Sensitive Plan Optimization (PSPO) ────────────────────────
    From SQL Server 2022 (compatibility level 160+) the engine tries to fix
    parameter sniffing BY ITSELF: it detects a skewed parameterised predicate,
    builds a dispatcher plan, and keeps up to three separate plans — one per
    cardinality bucket — routing each execution to the right one.

    In Query Store this shows up as extra queries you never wrote, carrying
    OPTION (PLAN PER VALUE(... predicate_range(...) ...)).

    It is excellent in production and RUINS the classic sniffing demo, because
    the whale and the minnow quietly get different plans. Turn it off for
    demos 2, 2b and 3, then turn it back on for the bonus demo 2c.          */
SELECT compatibility_level FROM sys.databases WHERE name = 'QueryStoreDemo';
--SELECT name, value FROM sys.database_scoped_configurations
--WHERE  name = 'PARAMETER_SENSITIVE_PLAN_OPTIMIZATION';
--GO

ALTER DATABASE SCOPED CONFIGURATION SET PARAMETER_SENSITIVE_PLAN_OPTIMIZATION = OFF;
GO

CREATE TABLE dbo.Orders (
    OrderID    INT IDENTITY(1,1) NOT NULL,
    CustomerID INT           NOT NULL,
    OrderDate  DATE          NOT NULL,
    Amount     DECIMAL(10,2) NOT NULL,
    Filler     CHAR(200)     NOT NULL DEFAULT 'x',   -- makes scans genuinely expensive
    CONSTRAINT PK_Orders PRIMARY KEY CLUSTERED (OrderID)
);
GO

/*  Load ~500k rows for one huge customer and a handful for a tiny one.
    NOTE: RAND() is evaluated ONCE per statement, so it would give every row the
    same value. ABS(CHECKSUM(NEWID())) is evaluated per row — use that instead.  */
WITH n AS (
    SELECT TOP (500000) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS i
    FROM sys.all_objects a CROSS JOIN sys.all_objects b
)
INSERT INTO dbo.Orders (CustomerID, OrderDate, Amount)
SELECT 1,
       DATEADD(DAY, -CAST(i % 730 AS INT), CAST(GETDATE() AS DATE)),
       ABS(CHECKSUM(NEWID())) % 10000 / 100.0
FROM n;
GO

INSERT INTO dbo.Orders (CustomerID, OrderDate, Amount) VALUES
    (9999, GETDATE(), 100.00),
    (9999, GETDATE(), 250.00),
    (9999, GETDATE(), 399.00);
GO

CREATE NONCLUSTERED INDEX IX_Orders_CustomerID ON dbo.Orders (CustomerID);
GO
UPDATE STATISTICS dbo.Orders WITH FULLSCAN;
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetOrdersByCustomer
    @CustomerID INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT OrderID, CustomerID, OrderDate, Amount, Filler
    FROM   dbo.Orders
    WHERE  CustomerID = @CustomerID;
END
GO

PRINT 'Setup complete. Let Query Store run for a while before testing.';
GO


/*───────────────────────────────────────────────────────────────────────────
  DEMO 1 — The Flight Recorder  

  Point: Query Store answers "what was happening, and when".
  Mostly clicking, not typing.
───────────────────────────────────────────────────────────────────────────*/

-- Generate some background noise first so the reports are not empty
SET NOCOUNT ON;
DECLARE @i INT = 0;
WHILE @i < 40
BEGIN
    EXEC dbo.usp_GetOrdersByCustomer @CustomerID = 9999;
    SELECT COUNT(*) FROM dbo.Orders WHERE OrderDate > DATEADD(DAY,-30,GETDATE());
    SELECT TOP 100 * FROM dbo.Orders ORDER BY Amount DESC;
    SET @i += 1;
END
GO

EXEC sys.sp_query_store_flush_db;   -- push in-memory data to disk immediately
GO

EXEC dbo.usp_GetOrdersByCustomer @CustomerID = 9999;

/*  IN SSMS, walk through:
      Object Explorer > QueryStoreDemo > Query Store
        1. Overall Resource Consumption  — switch Last hour
        2. Top Resource Consuming Queries
             → change the metric dropdown: Duration → CPU Time → Logical Reads
               and show that the ranking CHANGES. This is the whole point.
        3. Click a query on the chart → the plan appears in the lower pane */


/*───────────────────────────────────────────────────────────────────────────
  DEMO 2 — Parameter sniffing  

  Point: ONE plan, TWO parameter values, wildly different outcomes.
───────────────────────────────────────────────────────────────────────────*/

SET STATISTICS IO ON;
GO

-- (a) Clear the cached plan for this proc only (sp_recompile is surgical;
--     DBCC FREEPROCCACHE would nuke the whole instance — never do that on shared kit)
EXEC sp_recompile 'dbo.usp_GetOrdersByCustomer';
GO

-- (b) First call sniffs the huge customer → optimizer picks a Clustered Index Scan.
--     Correct for 500k rows.
EXEC dbo.usp_GetOrdersByCustomer @CustomerID = 1;
GO

-- (c) Same plan is now reused for the tiny one. Watch the logical reads:
--     thousands of pages read to return 3 rows.
EXEC dbo.usp_GetOrdersByCustomer @CustomerID = 9999;
GO 

-- (d) Now reverse it: recompile, sniff the minnow first
EXEC sp_recompile 'dbo.usp_GetOrdersByCustomer';
GO
EXEC dbo.usp_GetOrdersByCustomer @CustomerID = 9999;   -- Seek + Key Lookup
GO 
EXEC dbo.usp_GetOrdersByCustomer @CustomerID = 1;      -- 500k key lookups. Not optimal but in production it depends on your workload.
GO 

SET STATISTICS IO OFF;
GO
EXEC sys.sp_query_store_flush_db;
GO

-- (e) The Query Store view of the same story.
--     Sniffing shows as HIGH VARIATION WITHIN A SINGLE plan_id (11).
SELECT  p.plan_id,
        q.query_id,
        rs.count_executions,
        rs.avg_duration      / 1000.0 AS avg_ms,
        rs.min_duration      / 1000.0 AS min_ms,
        rs.max_duration      / 1000.0 AS max_ms,
        rs.avg_logical_io_reads
FROM    sys.query_store_query          q
JOIN    sys.query_store_plan           p  ON p.query_id  = q.query_id
JOIN    sys.query_store_runtime_stats  rs ON rs.plan_id  = p.plan_id
WHERE   q.object_id = OBJECT_ID('dbo.usp_GetOrdersByCustomer')
ORDER BY p.plan_id, rs.last_execution_time DESC;
GO

/*  In SSMS: Query Store > "Queries with High Variation", metric = Duration.
    Look for a large gap between min_ms and max_ms on the SAME plan_id (prefer Std Dev ). */



/*Activae Parameter Sensitive Plan Optimization to check how many plans we have*/

ALTER DATABASE SCOPED CONFIGURATION SET PARAMETER_SENSITIVE_PLAN_OPTIMIZATION = ON;
GO
EXEC sp_recompile 'dbo.usp_GetOrdersByCustomer';
GO
EXEC dbo.usp_GetOrdersByCustomer @CustomerID = 9999;   -- Seek + Key Lookup
GO
EXEC dbo.usp_GetOrdersByCustomer @CustomerID = 1;      -- 500k key lookups. Painful.
GO
EXEC sys.sp_query_store_flush_db;
GO



-- ══ Controlling WHI

/*───────────────────────────────────────────────────────────────────────────
  DEMO 4 — Wait statistics  (slide 11, ~4 min)

  Point: Query Store stores wait CATEGORIES, not individual wait types.
  Run the blocker in one window, the victim in another.
───────────────────────────────────────────────────────────────────────────*/

-- ── Window 1: the blocker. Leave this transaction open. ──
/*
BEGIN TRANSACTION;
UPDATE dbo.Orders SET Amount = Amount + 1 WHERE CustomerID = 9999;
-- deliberately do NOT commit yet
*/

-- ── Window 2: the victim. This will block. ──
/*
SELECT * FROM dbo.Orders WHERE CustomerID = 9999;
*/

-- ── Back in Window 1, after ~20 seconds: ──
/*
ROLLBACK TRANSACTION;
*/

EXEC sys.sp_query_store_flush_db;
GO

-- Now check what Query Store recorded in "Query Wait Statistics". 
-- Note wait_category_desc — you cannot filter on LCK_M_X here; 
-- QS rolled it up into the "Lock" category.
SELECT  ws.wait_category_desc,
        SUM(ws.total_query_wait_time_ms)              AS total_wait_ms,
        MAX(ws.max_query_wait_time_ms)                AS max_wait_ms,
        AVG(ws.avg_query_wait_time_ms)                AS avg_wait_ms,
        qt.query_sql_text
FROM    sys.query_store_wait_stats  ws
JOIN    sys.query_store_plan        p  ON p.plan_id       = ws.plan_id
JOIN    sys.query_store_query       q  ON q.query_id      = p.query_id
JOIN    sys.query_store_query_text  qt ON qt.query_text_id = q.query_text_id
GROUP BY ws.wait_category_desc, qt.query_sql_text
ORDER BY total_wait_ms DESC;
GO


/*───────────────────────────────────────────────────────────────────────────
  DEMO 5 — Query Store Hints  (slides 18–20, ~8 min)   SQL Server 2022+ only
───────────────────────────────────────────────────────────────────────────*/
-- disable PSPO to simulate pre SQL Server 2022 situation
ALTER DATABASE SCOPED CONFIGURATION SET PARAMETER_SENSITIVE_PLAN_OPTIMIZATION = OFF;
GO

-- (a) Get the query_id again (same object_id join as Demo 3)
DECLARE @query_id BIGINT;
SELECT TOP 1 @query_id = query_id
FROM   sys.query_store_query
WHERE  object_id = OBJECT_ID('dbo.usp_GetOrdersByCustomer');

-- (b) Fix the sniffing without touching one line of the procedure
EXEC sys.sp_query_store_set_hints
     @query_id    = @query_id,
     @query_hints = N'OPTION (RECOMPILE)';

PRINT CONCAT('RECOMPILE hint applied to query_id ', @query_id);
GO

-- (c) Confirm the hint is registered
SELECT query_hint_id, query_id, query_hint_text, last_query_hint_failure_reason_desc
FROM   sys.query_store_query_hints;
GO

-- (d) Both calls now get an appropriate plan. Watch the logical reads.
EXEC sp_recompile 'dbo.usp_GetOrdersByCustomer';
GO
SET STATISTICS IO ON;
EXEC dbo.usp_GetOrdersByCustomer @CustomerID = 1;
GO
EXEC dbo.usp_GetOrdersByCustomer @CustomerID = 9999;
SET STATISTICS IO OFF;
GO
EXEC sys.sp_query_store_flush_db;
GO

-- (e) Swap it for a MAXDOP hint to show hints are replaced, not merged.
--     Setting hints again OVERWRITES the previous hint string for that query.
DECLARE @query_id BIGINT;
SELECT TOP 1 @query_id = query_id
FROM   sys.query_store_query
WHERE  object_id = OBJECT_ID('dbo.usp_GetOrdersByCustomer');

EXEC sys.sp_query_store_set_hints
     @query_id    = @query_id,
     @query_hints = N'OPTION (MAXDOP 1, RECOMPILE)';
GO

SELECT query_id, query_hint_text FROM sys.query_store_query_hints;
GO
EXEC sys.sp_query_store_flush_db;
GO

-- (f) Remove the hint entirely
DECLARE @query_id BIGINT;
SELECT TOP 1 @query_id = query_id
FROM   sys.query_store_query
WHERE  object_id = OBJECT_ID('dbo.usp_GetOrdersByCustomer');

EXEC sys.sp_query_store_clear_hints @query_id = @query_id;
GO

-- (e) Confirm the hint is no longer registered
SELECT query_hint_id, query_id, query_hint_text, last_query_hint_failure_reason_desc
FROM   sys.query_store_query_hints;
GO

-- reenable PSPO 
ALTER DATABASE SCOPED CONFIGURATION SET PARAMETER_SENSITIVE_PLAN_OPTIMIZATION = ON;
GO

/*───────────────────────────────────────────────────────────────────────────
  BONUS — the two queries worth having on a hotkey in a real incident
───────────────────────────────────────────────────────────────────────────*/
CREATE OR ALTER PROCEDURE dbo.usp_GetOrdersByCustomer_Dynamic
    @CustomerID INT
AS
BEGIN
    SET NOCOUNT ON;
    -- In this example I use sp name to identify query
    DECLARE @sql NVARCHAR(MAX) =
        N'SELECT OrderID, CustomerID, OrderDate, Amount, Filler
          /* usp_GetOrdersByCustomer_Dynamic */
          FROM   dbo.Orders
          WHERE  CustomerID = @CustomerID;';

    -- Executed via sp_executesql with parameters passed separately 
    -- to prevent SQL injection (NOT by direct string concatenation)
    EXEC sys.sp_executesql @sql, N'@CustomerID INT', @CustomerID = @CustomerID;
END
GO

EXEC dbo.usp_GetOrdersByCustomer_Dynamic @CustomerID = 1;
GO
EXEC dbo.usp_GetOrdersByCustomer_Dynamic @CustomerID = 9999;
GO
EXEC sys.sp_query_store_flush_db;
GO

/*  B0. FIND MY QUERY — from a fragment of text, down to its plans.
    The first thing you open in a real incident. Keep it on a hotkey.

    Path: query_store_query_text → query_store_query → query_store_plan
          → query_store_runtime_stats (windowed by runtime_stats_interval)

    Two things that trip people up:
      · query_sql_text holds the STATEMENT, never the procedure name.
        Searching for 'usp_Something' returns nothing — filter on @object.
      · one runtime_stats row exists per plan PER INTERVAL per execution_type,
        so averages must be weighted by count_executions. AVG(avg_duration)
        is an average of averages and quietly lies to you.                   */

DECLARE @fragment   NVARCHAR(400) = N'usp_GetOrdersByCustomer_Dynamic';   -- any substring you recall
DECLARE @object     SYSNAME       = NULL;            -- or N'dbo.usp_GetOrdersByCustomer'
DECLARE @hours_back INT           = 24;

WITH agg AS (
    SELECT  rs.plan_id,
            SUM(rs.count_executions)                                     AS execs,
            SUM(rs.avg_duration         * rs.count_executions)
              / NULLIF(SUM(rs.count_executions), 0)                      AS avg_us,
            SUM(rs.avg_cpu_time         * rs.count_executions)
              / NULLIF(SUM(rs.count_executions), 0)                      AS avg_cpu_us,
            SUM(rs.avg_logical_io_reads * rs.count_executions)
              / NULLIF(SUM(rs.count_executions), 0)                      AS avg_reads,
            MAX(rs.last_execution_time)                                  AS last_exec
    FROM    sys.query_store_runtime_stats rs
    JOIN    sys.query_store_runtime_stats_interval rsi
              ON rsi.runtime_stats_interval_id = rs.runtime_stats_interval_id
    WHERE   rsi.start_time >= DATEADD(HOUR, -@hours_back, SYSUTCDATETIME())
    GROUP BY rs.plan_id
)
SELECT TOP (50)
        q.query_id,
        p.plan_id,
        OBJECT_NAME(q.object_id)                        AS object_name,
        CASE WHEN p.query_plan LIKE '%Clustered Index Scan%' THEN 'SCAN'
             WHEN p.query_plan LIKE '%Index Seek%'           THEN 'SEEK'
             ELSE 'OTHER' END                           AS plan_shape,
        p.is_forced_plan,
        p.force_failure_count,
        p.last_force_failure_reason_desc,
        a.execs,
        CAST(a.avg_us     / 1000.0 AS DECIMAL(18,2))    AS avg_ms,
        CAST(a.avg_cpu_us / 1000.0 AS DECIMAL(18,2))    AS avg_cpu_ms,
        CAST(a.avg_reads AS BIGINT)                     AS avg_reads,
        a.last_exec,
        LEFT(qt.query_sql_text, 300)                    AS query_snippet,
        TRY_CAST(p.query_plan AS XML)                   AS click_to_open_plan
FROM    sys.query_store_query_text qt
JOIN    sys.query_store_query      q ON q.query_text_id = qt.query_text_id
JOIN    sys.query_store_plan       p ON p.query_id      = q.query_id
JOIN    agg                        a ON a.plan_id       = p.plan_id
WHERE   qt.query_sql_text LIKE N'%' + @fragment + N'%'
  AND   q.is_internal_query = 0
  AND  (@object IS NULL OR q.object_id = OBJECT_ID(@object))
ORDER BY avg_ms DESC;
GO

-- query ad hoc
DECLARE @CustomerID INT  = 9999;
SELECT OrderID, CustomerID, OrderDate, Amount, Filler
          /* QUERY RECUPERO CLIENTI */
          FROM   dbo.Orders
          WHERE  CustomerID = @CustomerID;
GO 10 -- repeat execution 10 times


DECLARE @fragment   NVARCHAR(400) = N'QUERY RECUPERO CLIENTI';   -- any substring you recall
DECLARE @object     SYSNAME       = NULL;            -- or N'dbo.usp_GetOrdersByCustomer_Dynamic'
DECLARE @hours_back INT           = 24;

WITH agg AS (
    SELECT  rs.plan_id,
            SUM(rs.count_executions)                                     AS execs,
            SUM(rs.avg_duration         * rs.count_executions)
              / NULLIF(SUM(rs.count_executions), 0)                      AS avg_us,
            SUM(rs.avg_cpu_time         * rs.count_executions)
              / NULLIF(SUM(rs.count_executions), 0)                      AS avg_cpu_us,
            SUM(rs.avg_logical_io_reads * rs.count_executions)
              / NULLIF(SUM(rs.count_executions), 0)                      AS avg_reads,
            MAX(rs.last_execution_time)                                  AS last_exec
    FROM    sys.query_store_runtime_stats rs
    JOIN    sys.query_store_runtime_stats_interval rsi
              ON rsi.runtime_stats_interval_id = rs.runtime_stats_interval_id
    WHERE   rsi.start_time >= DATEADD(HOUR, -@hours_back, SYSUTCDATETIME())
    GROUP BY rs.plan_id
)
SELECT TOP (50)
        q.query_id,
        p.plan_id,
        OBJECT_NAME(q.object_id)                        AS object_name,
        CASE WHEN p.query_plan LIKE '%Clustered Index Scan%' THEN 'SCAN'
             WHEN p.query_plan LIKE '%Index Seek%'           THEN 'SEEK'
             ELSE 'OTHER' END                           AS plan_shape,
        p.is_forced_plan,
        p.force_failure_count,
        p.last_force_failure_reason_desc,
        a.execs,
        CAST(a.avg_us     / 1000.0 AS DECIMAL(18,2))    AS avg_ms,
        CAST(a.avg_cpu_us / 1000.0 AS DECIMAL(18,2))    AS avg_cpu_ms,
        CAST(a.avg_reads AS BIGINT)                     AS avg_reads,
        a.last_exec,
        LEFT(qt.query_sql_text, 300)                    AS query_snippet,
        TRY_CAST(p.query_plan AS XML)                   AS click_to_open_plan
FROM    sys.query_store_query_text qt
JOIN    sys.query_store_query      q ON q.query_text_id = qt.query_text_id
JOIN    sys.query_store_plan       p ON p.query_id      = q.query_id
JOIN    agg                        a ON a.plan_id       = p.plan_id
WHERE   qt.query_sql_text LIKE N'%' + @fragment + N'%'
  AND   q.is_internal_query = 0
  AND  (@object IS NULL OR q.object_id = OBJECT_ID(@object))
ORDER BY avg_ms DESC;
GO


/*  The last column is the payoff: TRY_CAST to XML makes the plan a clickable
    link in the SSMS grid — one click opens the graphical plan. TRY_CAST and
    not CAST, so a plan that will not parse returns NULL instead of killing
    the whole result set.

    Once you have the query_id, everything else keys off it:
      sys.query_store_plan          → the plans
      sys.query_store_query_hints   → hints applied to it
      sys.query_store_query_variant → PSPO dispatcher and variants
      sp_query_store_force_plan / _set_hints  → the fixes                    */



