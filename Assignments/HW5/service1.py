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


def _pick_header(headers, *names):
    for name in names:
        val = headers.get(name)
        if val:
            return val.strip()
    return None


def _client_ip(handler):
    forwarded = _pick_header(
        handler.headers,
        "X-Forwarded-For", "X-Real-IP", "Client-IP"
    )
    if forwarded:
        return forwarded.split(",")[0].strip()
    return handler.client_address[0]


def _requested_file(path):
    parsed = urlparse(path).path
    return parsed.rsplit("/", 1)[-1].strip()


# ----------------------------
# HEADER EXTRACTION (TIMED)
# ----------------------------
def _extract_request_context(handler):
    start = time.perf_counter_ns()

    country = _pick_header(handler.headers, "X-Country", "Country")
    gender = _pick_header(handler.headers, "X-Gender", "Gender")
    age_raw = _pick_header(handler.headers, "X-Age", "Age")
    income = _pick_header(handler.headers, "X-Income", "Income")

    age = int(age_raw) if age_raw and age_raw.isdigit() else None

    requested_file = _requested_file(handler.path)
    client_ip = _client_ip(handler)
    now = _now_utc()

    country_clean = country.lower() if country else None
    is_banned = country_clean in BANNED_COUNTRIES if country_clean else False

    elapsed = time.perf_counter_ns() - start

    return {
        "country": country_clean,
        "client_ip": client_ip,
        "gender": gender,
        "age": age,
        "income": income,
        "is_banned": is_banned,
        "time_of_day": now.hour,
        "timestamp": now,
        "requested_file": requested_file,
        "path": handler.path,
        "headers_ns": elapsed,
    }


# ----------------------------
# DB
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
    if _db_pool:
        return _db_pool

    with _db_lock:
        if _db_pool:
            return _db_pool

        try:
            _db_pool = _create_pool()
            logger.info("Connected to Cloud SQL.")
            return _db_pool
        except Exception as exc:
            raise RuntimeError(f"Cloud SQL connection failed: {exc}")


def _db_execute(sql, params):
    conn = _ensure_db_pool().get_connection()
    cursor = conn.cursor()

    start = time.perf_counter_ns()
    try:
        cursor.execute(sql, params)
        conn.commit()
    finally:
        cursor.close()
        conn.close()

    return time.perf_counter_ns() - start


def _record_success(ctx):
    return _db_execute("""
        INSERT INTO request_logs
        (country, client_ip, gender, age, income, is_banned, time_of_day, requested_file)
        VALUES (%s,%s,%s,%s,%s,%s,%s,%s)
    """, (
        ctx["country"], ctx["client_ip"], ctx["gender"],
        ctx["age"], ctx["income"], ctx["is_banned"],
        ctx["time_of_day"], ctx["requested_file"]
    ))


def _record_error(ctx, code):
    return _db_execute("""
        INSERT INTO error_logs
        (time_of_request, requested_file, error_code)
        VALUES (%s,%s,%s)
    """, (
        ctx["timestamp"], ctx["requested_file"], code
    ))


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
        "timestamp": ctx["timestamp"].isoformat(),
    }
    try:
        publisher.publish(FORB_TOPIC, json.dumps(payload).encode()).result(timeout=5)
    except Exception as e:
        logger.error(f"PubSub error: {e}")


# ----------------------------
# RESPONSE (TIMED)
# ----------------------------
def _send(handler, code, body, ctype):
    start = time.perf_counter_ns()
    handler.send_response(code)
    handler.send_header("Content-Type", ctype)
    handler.send_header("Content-Length", str(len(body)))
    handler.end_headers()
    handler.wfile.write(body)
    return time.perf_counter_ns() - start


# ----------------------------
# HANDLER
# ----------------------------
class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        return

    def do_GET(self):
        start = time.perf_counter_ns()
        ctx = _extract_request_context(self)

        status = 200
        body = b""
        read_ns = 0
        db_ns = 0

        try:
            if not ctx["requested_file"]:
                status = 404
                body = b"404 Not Found\n"
                logger.warning(f"404 Not Found: {ctx['requested_file']}")

            elif ctx["is_banned"]:
                status = 400
                body = b"400 Bad Request\n"
                logger.critical(json.dumps({
                    "event": "forbidden_country_request",
                    "country": ctx["country"],
                    "file": ctx["requested_file"],
                    "client_ip": ctx["client_ip"]
                }))
                _publish_forbidden(ctx)

            else:
                try:
                    body, read_ns = _download_file(ctx["requested_file"])
                except NotFound:
                    status = 404
                    body = b"404 Not Found\n"
                    logger.warning(f"404 Not Found: {ctx['requested_file']}")
                except Exception as e:
                    status = 500
                    body = b"500 Internal Server Error\n"
                    logger.error(f"GCS error: {e}")

            if status == 200:
                db_ns = _record_success(ctx)
            else:
                db_ns = _record_error(ctx, status)

            send_ns = _send(
                self,
                status,
                body,
                "text/html" if status == 200 else "text/plain"
            )

        except Exception as e:
            logger.error(f"Unhandled: {e}")
            status = 500
            send_ns = _send(self, 500, b"500 Internal Server Error\n", "text/plain")

        total_ns = time.perf_counter_ns() - start

        logger.info(json.dumps({
            "status_code": status,
            "headers_ns": ctx["headers_ns"],
            "read_ns": read_ns,
            "db_ns": db_ns,
            "send_ns": send_ns,
            "total_ns": total_ns
        }))

    def _other(self):
        ctx = _extract_request_context(self)
        logger.warning(f"501 Not Implemented: {self.command} {self.path}")
        _record_error(ctx, 501)
        _send(self, 501, b"501 Not Implemented\n", "text/plain")

    do_POST = do_PUT = do_DELETE = do_HEAD = do_OPTIONS = do_TRACE = do_PATCH = _other


# ----------------------------
# MAIN
# ----------------------------
if __name__ == "__main__":
    ThreadingHTTPServer(("", PORT), Handler).serve_forever()