#!/usr/bin/env python3

import os
import sys
import time

import mysql.connector
from mysql.connector import Error

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


DDL_REQUEST_LOGS = """
CREATE TABLE IF NOT EXISTS request_logs (
    id            BIGINT       AUTO_INCREMENT PRIMARY KEY,
    country       TEXT,
    client_ip     TEXT,
    gender        TEXT,
    age           TEXT,
    income        TEXT,
    is_banned     BOOLEAN,
    time_of_day   DATETIME,
    requested_file TEXT
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
"""

DDL_ERROR_LOGS = """
CREATE TABLE IF NOT EXISTS error_logs (
    id              BIGINT   AUTO_INCREMENT PRIMARY KEY,
    time_of_request DATETIME,
    requested_file  TEXT,
    error_code      INT
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
"""


def main() -> None:
    if not DB_USER or not DB_PASSWORD or not DB_NAME:
        print("[setup_schema] ERROR: DB_USER, DB_PASSWORD, and DB_NAME must all be set.")
        sys.exit(1)

    conn = wait_for_db()
    cursor = conn.cursor()

    try:
        cursor.execute(DDL_REQUEST_LOGS)
        print("[setup_schema] request_logs table ensured.")

        cursor.execute(DDL_ERROR_LOGS)
        print("[setup_schema] error_logs table ensured.")

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