-- Q8 - Transport Fleet Maintenance
-- Service due when >= 5000 km since last service.
-- Each new trip must start at vehicle's current odometer.

-- (a) Tables
CREATE TABLE IF NOT EXISTS vehicles (
    vehicle_id SERIAL PRIMARY KEY,
    registration VARCHAR(20) UNIQUE NOT NULL,
    current_odometer NUMERIC(12,2) NOT NULL CHECK (current_odometer >= 0),
    last_service_odometer NUMERIC(12,2) NOT NULL CHECK (last_service_odometer >= 0),
    CHECK (last_service_odometer <= current_odometer)
);

CREATE TABLE IF NOT EXISTS trips (
    trip_id SERIAL PRIMARY KEY,
    vehicle_id INT NOT NULL REFERENCES vehicles(vehicle_id),
    trip_on DATE NOT NULL,
    start_odometer NUMERIC(12,2) NOT NULL CHECK (start_odometer >= 0),
    end_odometer NUMERIC(12,2) NOT NULL CHECK (end_odometer >= 0)
);

CREATE TABLE IF NOT EXISTS service_alerts (
    vehicle_id INT PRIMARY KEY REFERENCES vehicles(vehicle_id),
    km_since_service NUMERIC(12,2) NOT NULL,
    flagged_on DATE NOT NULL DEFAULT CURRENT_DATE
);

-- (b) Function: is service due?
CREATE OR REPLACE FUNCTION fn_service_due(p_vehicle_id INT)
RETURNS BOOLEAN AS $$
DECLARE
    v_km NUMERIC(12,2);
BEGIN
    SELECT (current_odometer - last_service_odometer) INTO v_km
    FROM vehicles WHERE vehicle_id = p_vehicle_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown vehicle: %', p_vehicle_id;
    END IF;
    RETURN v_km >= 5000;
END;
$$ LANGUAGE plpgsql;

-- (c) Procedure: record trip. Does NOT update vehicle odometer - trigger does that.
CREATE OR REPLACE PROCEDURE pr_record_trip(p_vehicle_id INT, p_trip_on DATE, p_start NUMERIC, p_end NUMERIC)
AS $$
BEGIN
    IF NOT EXISTS(SELECT 1 FROM vehicles WHERE vehicle_id = p_vehicle_id) THEN
        RAISE EXCEPTION 'Unknown vehicle: %', p_vehicle_id;
    END IF;
    IF p_end <= p_start THEN
        RAISE EXCEPTION 'end_odometer (%) must be greater than start_odometer (%)', p_end, p_start;
    END IF;
    INSERT INTO trips(vehicle_id, trip_on, start_odometer, end_odometer)
    VALUES (p_vehicle_id, p_trip_on, p_start, p_end);
END;
$$ LANGUAGE plpgsql;

-- (d) Trigger: verify start = current, reject invalid, update odometer exactly once
CREATE OR REPLACE FUNCTION trg_trip_check_fn()
RETURNS TRIGGER AS $$
DECLARE
    v_current NUMERIC(12,2);
BEGIN
    SELECT current_odometer INTO v_current FROM vehicles WHERE vehicle_id = NEW.vehicle_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown vehicle: %', NEW.vehicle_id;
    END IF;
    IF NEW.start_odometer <> v_current THEN
        RAISE EXCEPTION 'Trip must start at current odometer % but got %', v_current, NEW.start_odometer;
    END IF;
    IF NEW.end_odometer <= NEW.start_odometer THEN
        RAISE EXCEPTION 'end_odometer must be greater than start_odometer';
    END IF;
    UPDATE vehicles SET current_odometer = NEW.end_odometer
    WHERE vehicle_id = NEW.vehicle_id;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_trip_check ON trips;
CREATE TRIGGER trg_trip_check
BEFORE INSERT ON trips
FOR EACH ROW EXECUTE FUNCTION trg_trip_check_fn();

-- (a) Seed data: 3 vehicles, different service positions
INSERT INTO vehicles(registration, current_odometer, last_service_odometer) VALUES
('BAJ 1234', 12000.00, 10000.00), -- 2000 km since service, NOT due
('ABC 5678', 26000.00, 20000.00), -- 6000 km since service, DUE
('XYZ 9012', 8000.00, 5000.00)    -- 3000 km since service, NOT due
ON CONFLICT (registration) DO NOTHING;

-- 6 trips through the procedure AFTER trigger installed.
-- Each trip starts at the vehicle's CURRENT odometer (updated by trigger).
CALL pr_record_trip(1, '2026-01-05', 12000.00, 12500.00);
CALL pr_record_trip(1, '2026-01-06', 12500.00, 13000.00);
CALL pr_record_trip(2, '2026-01-05', 26000.00, 26500.00);
CALL pr_record_trip(2, '2026-01-07', 26500.00, 27000.00);
CALL pr_record_trip(3, '2026-01-05', 8000.00, 8500.00);
CALL pr_record_trip(3, '2026-01-08', 8500.00, 9000.00);

-- (e) View: vehicles that meet service threshold
CREATE OR REPLACE VIEW v_service_due AS
SELECT registration, (current_odometer - last_service_odometer) AS km_since_service
FROM vehicles
WHERE (current_odometer - last_service_odometer) >= 5000;

-- (f) Index: one vehicle's trips within a date range
-- Justification: Equality on vehicle_id + range on trip_on matches
-- WHERE vehicle_id = ? AND trip_on BETWEEN ? AND ? exactly,
-- so Postgres seeks instead of scanning all trips.
CREATE INDEX IF NOT EXISTS idx_trips_vehicle_trip_on
ON trips(vehicle_id, trip_on);

-- Matching query + plan:
-- EXPLAIN SELECT * FROM trips WHERE vehicle_id = 1 AND trip_on BETWEEN '2026-01-01' AND '2026-01-31';
EXPLAIN SELECT * FROM trips WHERE vehicle_id = 1 AND trip_on BETWEEN '2026-01-01' AND '2026-01-31';

-- (g) Scheduled job: refresh service alerts
-- Inserts/updates alert for each due vehicle, removes alert once no longer due.
CREATE OR REPLACE PROCEDURE pr_refresh_service_alerts()
AS $$
BEGIN
    -- Upsert alerts for due vehicles
    INSERT INTO service_alerts(vehicle_id, km_since_service, flagged_on)
    SELECT vehicle_id, (current_odometer - last_service_odometer), CURRENT_DATE
    FROM vehicles
    WHERE (current_odometer - last_service_odometer) >= 5000
    ON CONFLICT (vehicle_id) DO UPDATE
    SET km_since_service = EXCLUDED.km_since_service,
        flagged_on = EXCLUDED.flagged_on;
    -- Remove alerts for vehicles no longer due
    DELETE FROM service_alerts
    WHERE vehicle_id IN (
        SELECT vehicle_id FROM vehicles
        WHERE (current_odometer - last_service_odometer) < 5000
    );
END;
$$ LANGUAGE plpgsql;

-- Test refresh:
CALL pr_refresh_service_alerts();

-- Schedule every Monday at 06:00 (pg_cron):
-- SELECT cron.schedule('refresh-service-alerts-weekly', '0 6 * * 1',
--   $$CALL pr_refresh_service_alerts()$$);

-- Checks:
SELECT * FROM v_service_due;
SELECT fn_service_due(1);
SELECT fn_service_due(2);
SELECT * FROM vehicles;
SELECT * FROM trips;
SELECT * FROM service_alerts;