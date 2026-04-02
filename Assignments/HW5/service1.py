#!/usr/bin/env python3
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse
from datetime import datetime, timezone
import json
import logging
import os
import threading
import time

from google.api_core.exceptions import NotFound
from google.cloud import logging as cloud_logging
from google.cloud import pubsub_v1
from google.cloud import storage
from mysql.connector import pooling

# ----------------------------
# Config
# ----------------------------
PROJECT = os.environ.get("GCP_PROJECT", "superb-memory-485622-u3")
BUCKET = os.environ.get("BUCKET", "hche-cs528-hw2")
FOLDER = os.environ.get("FOLDER", "20000")
PORT = int(os.environ.get("PORT", "8080"))
FORB_TOPIC = os.environ.get(
    "FORB_TOPIC", f"projects/{PROJECT}/topics/hw5-forbidden-exports"
)

DB_HOST = os.environ.get("DB_HOST")
DB_USER = os.environ.get("DB_USER")
DB_PASSWORD = os.environ.get("DB_PASSWORD")
DB_NAME = os.environ.get("DB_NAME")

BANNED_COUNTRIES = {
    "north korea", "iran", "cuba", "myanmar", "iraq",
    "libya", "sudan", "zimbabwe", "syria"
}

# ----------------------------
# Logging / clients
# ----------------------------
cloud_client = cloud_logging.Client()
cloud_client.setup_logging()

logger = logging.getLogger("webserver")
logger.setLevel(logging.INFO)

storage_client = storage.Client()
publisher = pubsub_v1.PublisherClient()

# ----------------------------
# DB pool
# ----------------------------
_db_pool = None
_db_lock = threading.Lock()


def _now_utc():
    return datetime.now(timezone.utc)


def _pick_header(headers, *names, default=""):
    for name in names:
        val = headers.get(name)
        if val is not None:
            val = val.strip()
            if val:
                return val
    return default


def _client_ip(handler):
    forwarded = _pick_header(
        handler.headers,
        "X-Forwarded-For",
        "X-Real-IP",
        "Client-IP",
        default=""
    )
    if forwarded:
        return forwarded.split(",")[0].strip()
    return handler.client_address[0]


def _requested_file(path):
    parsed = urlparse(path).path
    return parsed.rsplit("/", 1)[-1].strip()


def _extract_request_context(handler):
    start = time.perf_counter_ns()

    country = _pick_header(handler.headers, "X-Country", "Country")
    gender = _pick_header(handler.headers, "X-Gender", "Gender")
    age = _pick_header(handler.headers, "X-Age", "Age")
    income = _pick_header(handler.headers, "X-Income", "Income")
    requested_file = _requested_file(handler.path)
    client_ip = _client_ip(handler)
    request_time = _now_utc()
    is_banned = country.strip().lower() in BANNED_COUNTRIES if country else False

    elapsed = time.perf_counter_ns() - start
    return {
        "country": country or None,
        "client_ip": client_ip or None,
        "gender": gender or None,
        "age": age or None,
        "income": income or None,
        "is_banned": is_banned,
        "time_of_day": request_time,
        "requested_file": requested_file or None,
        "path": handler.path,
        "headers_ns": elapsed,
    }


# ----------------------------
# MySQL connection pool
# ----------------------------
def _create_pool():
    return pooling.MySQLConnectionPool(
        pool_name="mypool",
        pool_size=20,
        host=DB_HOST,
        user=DB_USER,
        password=DB_PASSWORD,
        database=DB_NAME
    )


def _ensure_db_pool():
    global _db_pool
    if _db_pool is not None:
        return _db_pool

    with _db_lock:
        if _db_pool is not None:
            return _db_pool
        try:
            _db_pool = _create_pool()
            logger.info("Connected to Cloud SQL.")
            return _db_pool
        except Exception as exc:
            raise RuntimeError(f"Cloud SQL connection failed: {exc}")


def _db_execute(sql, params):
    pool = _ensure_db_pool()
    conn = pool.get_connection()
    cursor = conn.cursor()

    start = time.perf_counter_ns()
    try:
        cursor.execute(sql, params)
        conn.commit()
    finally:
        cursor.close()
        conn.close()

    return time.perf_counter_ns() - start


# ----------------------------
# MySQL helper functions (3NF-aware)
# ----------------------------
def _record_client_if_missing(client_ip, country):
    """Insert into clients only if the client_ip doesn't exist."""
    if not client_ip:
        return

    pool = _ensure_db_pool()
    conn = pool.get_connection()
    cursor = conn.cursor()
    try:
        cursor.execute(
            "INSERT IGNORE INTO clients(client_ip, country) VALUES (%s, %s)",
            (client_ip, country)
        )
        conn.commit()
    finally:
        cursor.close()
        conn.close()


def _record_success(ctx):
    """
    Insert a request into request_logs and ensure the client exists in clients.
    """
    client_ip = ctx.get("client_ip")
    country = ctx.get("country")

    # Ensure the client exists in clients table
    _record_client_if_missing(client_ip, country)

    sql = """
        INSERT INTO request_logs
        (client_ip, gender, age, income, is_banned, time_of_day, requested_file)
        VALUES (%s, %s, %s, %s, %s, %s, %s)
    """
    params = (
        client_ip,
        ctx.get("gender"),
        ctx.get("age"),
        ctx.get("income"),
        ctx.get("is_banned"),
        ctx.get("time_of_day"),
        ctx.get("requested_file")
    )

    return _db_execute(sql, params)


def _record_error(ctx, error_code):
    """Insert into error_logs (unchanged from original)."""
    sql = """
        INSERT INTO error_logs
        (time_of_request, requested_file, error_code)
        VALUES (%s, %s, %s)
    """
    params = (ctx["time_of_day"], ctx["requested_file"], error_code)
    return _db_execute(sql, params)


# ----------------------------
# GCS
# ----------------------------
def _download_file(filename):
    start = time.perf_counter_ns()
    blob = storage_client.bucket(BUCKET).blob(f"{FOLDER}/{filename}")
    data = blob.download_as_bytes()
    return data, time.perf_counter_ns() - start


# ----------------------------
# PUBSUB
# ----------------------------
def _publish_forbidden(ctx):
    payload = {
        "event": "forbidden_country_request",
        "country": ctx["country"],
        "client_ip": ctx["client_ip"],
        "file": ctx["requested_file"],
        "path": ctx["path"],
        "timestamp": ctx["time_of_day"].isoformat(),
    }
    try:
        future = publisher.publish(
            FORB_TOPIC,
            json.dumps(payload).encode("utf-8")
        )
        future.result(timeout=5)
    except Exception as exc:
        logger.error("Failed to publish forbidden event: %s", exc)


# ----------------------------
# Response
# ----------------------------
def _send_bytes(handler, status_code, body, content_type="text/plain; charset=utf-8"):
    start = time.perf_counter_ns()
    handler.send_response(status_code)
    handler.send_header("Content-Type", content_type)
    handler.send_header("Content-Length", str(len(body)))
    handler.end_headers()
    handler.wfile.write(body)
    return time.perf_counter_ns() - start


# ----------------------------
# Handler
# ----------------------------
class Handler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        return

    def _handle_get(self):
        request_start = time.perf_counter_ns()
        ctx = _extract_request_context(self)

        status_code = 200
        body = b""
        read_ns = 0
        db_ns = 0

        try:
            if not ctx["requested_file"]:
                status_code = 404
                body = b"404 Not Found\n"
            elif ctx["is_banned"]:
                status_code = 400
                body = b"400 Bad Request\n"
                _publish_forbidden(ctx)
            else:
                try:
                    body, read_ns = _download_file(ctx["requested_file"])
                except NotFound:
                    status_code = 404
                    body = b"404 Not Found\n"
                except Exception as exc:
                    logger.error("Error reading file from GCS: %s", exc)
                    status_code = 500
                    body = b"500 Internal Server Error\n"

            if status_code == 200:
                try:
                    db_ns = _record_success(ctx)
                except Exception as exc:
                    logger.error("Failed to insert success row: %s", exc)
            else:
                try:
                    db_ns = _record_error(ctx, status_code)
                except Exception as exc:
                    logger.error("Failed to insert error row: %s", exc)

            send_ns = _send_bytes(
                self,
                status_code,
                body,
                content_type="text/html; charset=utf-8" if status_code == 200 else "text/plain; charset=utf-8",
            )
        except Exception as exc:
            logger.error("Unhandled request error: %s", exc)
            try:
                _record_error(ctx, 500)
            except Exception:
                pass
            send_ns = _send_bytes(self, 500, b"500 Internal Server Error\n")
            status_code = 500

        total_ns = time.perf_counter_ns() - request_start
        logger.info(json.dumps({
            "status_code": status_code,
            "country": ctx["country"],
            "client_ip": ctx["client_ip"],
            "gender": ctx["gender"],
            "age": ctx["age"],
            "income": ctx["income"],
            "is_banned": ctx["is_banned"],
            "requested_file": ctx["requested_file"],
            "headers_ns": ctx["headers_ns"],
            "read_ns": read_ns,
            "send_ns": send_ns,
            "db_ns": db_ns,
            "total_ns": total_ns,
        }))

    def do_GET(self):
        self._handle_get()

    def _handle_other_methods(self):
        request_start = time.perf_counter_ns()
        ctx = _extract_request_context(self)
        status_code = 501
        body = b"501 Not Implemented\n"

        try:
            _record_error(ctx, status_code)
        except Exception as exc:
            logger.error("Failed to log 501 error: %s", exc)

        send_ns = _send_bytes(self, status_code, body)
        total_ns = time.perf_counter_ns() - request_start
        logger.info(json.dumps({
            "status_code": status_code,
            "country": ctx["country"],
            "client_ip": ctx["client_ip"],
            "gender": ctx["gender"],
            "age": ctx["age"],
            "income": ctx["income"],
            "is_banned": ctx["is_banned"],
            "requested_file": ctx["requested_file"],
            "headers_ns": ctx["headers_ns"],
            "read_ns": 0,
            "send_ns": send_ns,
            "db_ns": 0,
            "total_ns": total_ns,
        }))

    do_POST = _handle_other_methods
    do_PUT = _handle_other_methods
    do_DELETE = _handle_other_methods
    do_HEAD = _handle_other_methods
    do_CONNECT = _handle_other_methods
    do_OPTIONS = _handle_other_methods
    do_TRACE = _handle_other_methods
    do_PATCH = _handle_other_methods


# ----------------------------
# Main
# ----------------------------
if __name__ == "__main__":
    ThreadingHTTPServer(("", PORT), Handler).serve_forever()