#!/usr/bin/env python3
"""
HW8 client — mirrors http-client.exe interface + prints X-Zone header
Usage: python3 client.py -d <LB_IP> -b <bucket> -n <num_requests> -p 80 -v
"""
import argparse
import random
import sys
import time
import urllib.request
import urllib.error
from datetime import datetime
from google.cloud import storage

def parse_args():
    p = argparse.ArgumentParser()
    p.add_argument("-d", "--domain",       default="localhost",  help="Domain to make requests to")
    p.add_argument("-b", "--bucket",       default="none",       help="Cloud bucket containing your files. Use none if running local")
    p.add_argument("-w", "--webdir",       default="none",       help="Directory containing your files. Use none if you did not make one")
    p.add_argument("-n", "--num_requests", default=100, type=int,help="Number of requests to make")
    p.add_argument("-i", "--index",        default=None, type=int,help="Maximum existing file index")
    p.add_argument("-p", "--port",         default=8080, type=int,help="Server Port")
    p.add_argument("-f", "--follow",       action="store_true",  help="Follow Redirects")
    p.add_argument("-s", "--ssl",          action="store_true",  help="Use HTTPS")
    p.add_argument("-v", "--verbose",      action="store_true",  help="Print the responses from the server on stdout")
    p.add_argument("-r", "--random",       default=42, type=int, help="Initial random seed")
    p.add_argument("-t", "--timeout",      default=5,  type=float, help="Timeout in seconds for requests")
    return p.parse_args()


def get_file_list(bucket_name, webdir):
    """Pull the list of filenames from GCS bucket/webdir."""
    client = storage.Client()
    prefix = f"{webdir}/" if webdir and webdir != "none" else ""
    blobs = client.list_blobs(bucket_name, prefix=prefix)
    files = []
    for b in blobs:
        name = b.name
        if prefix:
            name = name[len(prefix):]  # strip folder prefix
        if name:
            files.append(name)
    return files


def main():
    args = parse_args()
    rng = random.Random(args.random)
    scheme = "https" if args.ssl else "http"
    base_url = f"{scheme}://{args.domain}:{args.port}"

    # Build file list
    if args.bucket != "none":
        print(f"Fetching file list from gs://{args.bucket}/{args.webdir} ...")
        files = get_file_list(args.bucket, args.webdir if args.webdir != "none" else "")
        if not files:
            print("ERROR: No files found in bucket/webdir.", file=sys.stderr)
            sys.exit(1)
        if args.index is not None:
            files = files[:args.index]
        print(f"Found {len(files)} files.\n")
    elif args.index is not None:
        # fallback: generate numeric filenames up to --index
        files = [str(i) for i in range(args.index)]
    else:
        print("ERROR: provide --bucket or --index", file=sys.stderr)
        sys.exit(1)

    # Stats
    zone_counts = {}
    success = 0
    errors = 0
    error_start = None

    print(f"Sending {args.num_requests} requests to {base_url}  (1/sec)\n")
    print(f"{'#':<6} {'Time':<25} {'Status':<8} {'Zone':<22} {'File'}")
    print("-" * 80)

    for i in range(args.num_requests):
        filename = rng.choice(files)
        url = f"{base_url}/{filename}"
        ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S.%f")[:-3]
        zone = "-"
        status = "-"
        body = b""

        try:
            req = urllib.request.Request(url)
            with urllib.request.urlopen(req, timeout=args.timeout) as resp:
                status = resp.status
                zone = resp.headers.get("X-Zone", "missing")
                body = resp.read()
                success += 1
                zone_counts[zone] = zone_counts.get(zone, 0) + 1
                if error_start:
                    now = datetime.now().strftime("%Y-%m-%d %H:%M:%S.%f")[:-3]
                    print(f"\n*** RECOVERED at {now} (was down since {error_start}) ***\n")
                    error_start = None

        except urllib.error.HTTPError as e:
            status = e.code
            zone = e.headers.get("X-Zone", "-") if e.headers else "-"
            body = e.read()
            errors += 1
            if not error_start:
                error_start = ts
                print(f"\n*** FAILOVER DETECTED at {ts} ***\n")

        except Exception as e:
            status = "ERR"
            errors += 1
            if not error_start:
                error_start = ts
                print(f"\n*** FAILOVER DETECTED at {ts} — {e} ***\n")

        print(f"{i+1:<6} {ts:<25} {str(status):<8} {zone:<22} {filename}")
        if args.verbose and body:
            print(f"       BODY: {body[:120]}")

        time.sleep(1)

    # Summary
    print("\n" + "=" * 80)
    print(f"SUMMARY: {args.num_requests} requests — {success} OK, {errors} errors")
    print("\nRequests per zone:")
    total = sum(zone_counts.values())
    for z, count in sorted(zone_counts.items()):
        pct = 100 * count / total if total else 0
        print(f"  {z:<25} {count:>5}  ({pct:.1f}%)")
    print("=" * 80)


if __name__ == "__main__":
    main()