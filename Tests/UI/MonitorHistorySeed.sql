-- Seven days of realistic minute history for the monitor range-switch probe.
-- Times are minute-aligned, ending at the current minute. Two recording gaps
-- (a 2 h break and an overnight 7 h sleep) keep the chart's gap handling real.
-- The schema mirrors the GRDB migrations so the app opens it as an existing database.
BEGIN;

CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY);
CREATE TABLE "sample" ("time" DATETIME PRIMARY KEY ON CONFLICT REPLACE, "cpu" DOUBLE, "gpu" DOUBLE, "memory" DOUBLE, "temperature" DOUBLE, "fan" DOUBLE, "power" DOUBLE, "networkIn" DOUBLE, "networkOut" DOUBLE, "diskRead" DOUBLE, "diskWrite" DOUBLE, "battery" DOUBLE);
CREATE TABLE "sample_accumulator" ("time" DATETIME NOT NULL, "column" TEXT NOT NULL, "total_sum" DOUBLE NOT NULL, "total_count" INTEGER NOT NULL, PRIMARY KEY ("time", "column"));
CREATE TABLE "history_setting" ("key" TEXT PRIMARY KEY, "value" TEXT NOT NULL);
CREATE TABLE "process_sample" ("time" DATETIME NOT NULL, "name" TEXT NOT NULL, "cpu_sum" DOUBLE NOT NULL, "cpu_count" INTEGER NOT NULL, "memory_sum" DOUBLE NOT NULL, "memory_count" INTEGER NOT NULL, PRIMARY KEY ("time", "name"));
CREATE TABLE "process_sample_minute" ("time" DATETIME PRIMARY KEY, "hidden_count" INTEGER NOT NULL);
CREATE TABLE "series_sample" ("time" DATETIME NOT NULL, "series" TEXT NOT NULL, "value_sum" DOUBLE NOT NULL, "value_count" INTEGER NOT NULL, PRIMARY KEY ("time", "series"));
CREATE TABLE "disk_space" ("time" DATETIME PRIMARY KEY, "free" DOUBLE NOT NULL, "total" DOUBLE NOT NULL);
INSERT INTO grdb_migrations (identifier) VALUES ('v1'), ('v2'), ('v3'), ('v4'), ('v5'), ('v6');
INSERT INTO history_setting (key, value) VALUES ('retentionSeconds', '604800');

WITH RECURSIVE m(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM m WHERE i < 10080),
minutes AS (
    SELECT i,
           strftime('%Y-%m-%d %H:%M:%f',
                    (CAST(strftime('%s', 'now') AS INTEGER) / 60) * 60 - i * 60,
                    'unixepoch') AS t
    FROM m
    WHERE NOT (i BETWEEN 600 AND 719)       -- 2 h gap, 10–12 h ago
      AND NOT (i BETWEEN 3600 AND 4019)     -- 7 h gap, 2.5–1.5 days ago
)
INSERT INTO sample (time, cpu, gpu, memory, temperature, fan, power, networkIn, networkOut, diskRead, diskWrite, battery)
SELECT t,
       0.08 + (abs(random()) % 700) / 1000.0,
       (abs(random()) % 550) / 1000.0,
       0.48 + (abs(random()) % 260) / 1000.0,
       42 + (abs(random()) % 340) / 10.0,
       1200 + (abs(random()) % 2200),
       6 + (abs(random()) % 320) / 10.0,
       (abs(random()) % 4000000),
       (abs(random()) % 900000),
       (abs(random()) % 18000000),
       (abs(random()) % 6000000),
       0.62 + (abs(random()) % 330) / 1000.0
FROM minutes;

WITH RECURSIVE m(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM m WHERE i < 10080),
minutes AS (
    SELECT i,
           strftime('%Y-%m-%d %H:%M:%f',
                    (CAST(strftime('%s', 'now') AS INTEGER) / 60) * 60 - i * 60,
                    'unixepoch') AS t
    FROM m
    WHERE NOT (i BETWEEN 600 AND 719)
      AND NOT (i BETWEEN 3600 AND 4019)
),
series(name, base, span) AS (
    VALUES ('temperature.PMU tdie1', 48.0, 26.0),
           ('temperature.PMU tdie2', 46.0, 24.0),
           ('temperature.PMU tdie3', 45.0, 22.0),
           ('temperature.PMU tdev1', 40.0, 16.0),
           ('temperature.PMU tdev2', 39.0, 15.0),
           ('temperature.PMU tcal1', 35.0, 10.0),
           ('temperature.NAND CH0 temp', 38.0, 12.0),
           ('temperature.gas gauge battery', 30.0, 6.0),
           ('cpu.performance', 0.12, 0.55),
           ('cpu.efficiency', 0.06, 0.30)
)
INSERT INTO series_sample (time, series, value_sum, value_count)
SELECT t, name,
       -- value_sum is a sum over value_count observations, so a 30-observation minute
       -- stores 30× the displayed value. Dividing by 30 must give the base…base+span
       -- range, not a value 30 times too small.
       (base + (abs(random()) % 1000) / 1000.0 * span) * 30,
       30
FROM minutes CROSS JOIN series;

WITH RECURSIVE m(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM m WHERE i < 10080),
minutes AS (
    SELECT i,
           strftime('%Y-%m-%d %H:%M:%f',
                    (CAST(strftime('%s', 'now') AS INTEGER) / 60) * 60 - i * 60,
                    'unixepoch') AS t
    FROM m
    WHERE NOT (i BETWEEN 600 AND 719)
      AND NOT (i BETWEEN 3600 AND 4019)
),
names(n, cpu, memory) AS (
    VALUES ('kernel_task', 0.12, 2200000000),
           ('Xcode', 0.34, 4100000000),
           ('Safari', 0.08, 1800000000),
           ('WindowServer', 0.11, 900000000),
           ('mds_stores', 0.05, 220000000),
           ('Finder', 0.02, 180000000),
           ('Terminal', 0.03, 240000000),
           ('Google Chrome', 0.16, 2600000000),
           ('Slack', 0.04, 700000000),
           ('Docker', 0.07, 1200000000),
           ('node', 0.09, 800000000),
           ('WindowManager', 0.02, 150000000),
           ('Spotlight', 0.01, 120000000),
           ('coreaudiod', 0.01, 60000000),
           ('launchd', 0.01, 40000000)
)
INSERT INTO process_sample (time, name, cpu_sum, cpu_count, memory_sum, memory_count)
SELECT t, n,
       cpu * 30 + (abs(random()) % 1000) / 10000.0,
       30,
       -- memory_sum is the sum of 30 observations, so the average is the byte count
       -- below, not that count divided by 30 (which showed GB processes as MB).
       memory * 30 + (abs(random()) % 100000000),
       30
FROM minutes CROSS JOIN names;

WITH RECURSIVE m(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM m WHERE i < 10080),
minutes AS (
    SELECT i,
           strftime('%Y-%m-%d %H:%M:%f',
                    (CAST(strftime('%s', 'now') AS INTEGER) / 60) * 60 - i * 60,
                    'unixepoch') AS t
    FROM m
    WHERE NOT (i BETWEEN 600 AND 719)
      AND NOT (i BETWEEN 3600 AND 4019)
)
INSERT INTO process_sample_minute (time, hidden_count)
SELECT t, 0 FROM minutes;

WITH RECURSIVE h(i) AS (SELECT 0 UNION ALL SELECT i + 1 FROM h WHERE i < 167)
INSERT INTO disk_space (time, free, total)
SELECT strftime('%Y-%m-%d %H:%M:%f',
                (CAST(strftime('%s', 'now') AS INTEGER) / 3600) * 3600 - i * 3600, 'unixepoch'),
       410000000000 + (abs(random()) % 20000000000),
       994000000000
FROM h;

COMMIT;
