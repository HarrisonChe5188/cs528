#!/usr/bin/env python3

import os
import sys
import time
import mysql.connector
from mysql.connector import Error

# ---------------------------
# Database connection
# ---------------------------
DB_HOST     = os.environ.get("DB_HOST", "127.0.0.1")
DB_PORT     = int(os.environ.get("DB_PORT", "3306"))
DB_USER     = os.environ.get("DB_USER", "")
DB_PASSWORD = os.environ.get("DB_PASSWORD", "")
DB_NAME     = os.environ.get("DB_NAME", "")

def wait_for_db(retries: int = 20, delay: float = 5.0) -> mysql.connector.MySQLConnection:
    """Retry connecting so the proxy has time to start."""
    for attempt in range(1, retries + 1):
        try:
            conn = mysql.connector.connect(
                host=DB_HOST,
                port=DB_PORT,
                user=DB_USER,
                password=DB_PASSWORD,
                database=DB_NAME,
                connection_timeout=10,
            )
            print(f"[setup_schema] Connected to MySQL on attempt {attempt}.")
            return conn
        except Error as exc:
            print(f"[setup_schema] Attempt {attempt}/{retries} failed: {exc}")
            if attempt < retries:
                time.sleep(delay)
    print("[setup_schema] Could not connect to MySQL. Aborting.")
    sys.exit(1)

# ---------------------------
# DDL statements (3NF ready)
# ---------------------------
DDL_CLIENTS = """
CREATE TABLE IF NOT EXISTS clients (
    client_ip VARCHAR(45) PRIMARY KEY,
    country TEXT
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
"""

DDL_REQUEST_LOGS = """
CREATE TABLE IF NOT EXISTS request_logs (
    id            BIGINT AUTO_INCREMENT PRIMARY KEY,
    client_ip     VARCHAR(45),
    gender        TEXT,
    age           TEXT,
    income        TEXT,
    is_banned     BOOLEAN,
    time_of_day   DATETIME,
    requested_file TEXT,
    FOREIGN KEY (client_ip) REFERENCES clients(client_ip)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
"""

DDL_ERROR_LOGS = """
CREATE TABLE IF NOT EXISTS error_logs (
    id              BIGINT AUTO_INCREMENT PRIMARY KEY,
    time_of_request DATETIME,
    requested_file  TEXT,
    error_code      INT
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
"""

# ---------------------------
# 3NF migration
# ---------------------------
def migrate_to_3nf(cursor):
    """Move country out of request_logs into clients table if it exists."""
    cursor.execute("SHOW COLUMNS FROM request_logs LIKE 'country'")
    if cursor.fetchone():
        print("[setup_schema] Migrating request_logs to 3NF...")

        # Insert unique client_ip → country into clients
        cursor.execute("""
            INSERT IGNORE INTO clients(client_ip, country)
            SELECT DISTINCT client_ip, country
            FROM request_logs
            WHERE client_ip IS NOT NULL
        """)

        # Drop country column from request_logs
        cursor.execute("ALTER TABLE request_logs DROP COLUMN country")
        print("[setup_schema] Migration complete.")
    else:
        print("[setup_schema] request_logs already in 3NF; skipping migration.")

# ---------------------------
# Main
# ---------------------------
def main() -> None:
    if not DB_USER or not DB_PASSWORD or not DB_NAME:
        print("[setup_schema] ERROR: DB_USER, DB_PASSWORD, and DB_NAME must all be set.")
        sys.exit(1)

    conn = wait_for_db()
    cursor = conn.cursor()

    try:
        # Ensure tables exist
        cursor.execute(DDL_CLIENTS)
        print("[setup_schema] clients table ensured.")

        cursor.execute(DDL_REQUEST_LOGS)
        print("[setup_schema] request_logs table ensured.")

        cursor.execute(DDL_ERROR_LOGS)
        print("[setup_schema] error_logs table ensured.")

        # Run 3NF migration if needed
        migrate_to_3nf(cursor)

        conn.commit()
        print("[setup_schema] Schema setup complete.")
    except Error as exc:
        print(f"[setup_schema] DDL error: {exc}")
        sys.exit(1)
    finally:
        cursor.close()
        conn.close()

if __name__ == "__main__":
    main()