from collections import defaultdict
from bs4 import BeautifulSoup
from urllib.parse import urlparse
from concurrent.futures import ThreadPoolExecutor, as_completed
from google.cloud import storage
import os
import statistics
import numpy as np
import lxml

# Process a single blob to extract outgoing links and count them
def process_blob(blob, files):
    fname = os.path.basename(blob.name)
    try:
        html = blob.download_as_text()
    except Exception as e:
        
        return fname, 0, set(), True

    out_count = 0
    targets = set()
    for a in BeautifulSoup(html, "lxml").find_all   ("a", href=True):
        target = os.path.basename(urlparse(a["href"]).path)
        if target in files:
            out_count += 1
            targets.add(target)
    return fname, out_count, targets, False  

# Concurrently parse all blobs
def parse_links_gcs_concurrent(bucket_name, prefix, max_workers=32):
    incoming = defaultdict(int)
    outgoing = defaultdict(int)
    graph = defaultdict(set)

    client = storage.Client()
    bucket = client.bucket(bucket_name)
    blobs = [
        blob for blob in bucket.list_blobs(prefix=prefix)
        if blob.name.endswith(".html")
    ]
    files = {os.path.basename(blob.name) for blob in blobs if blob.name.endswith(".html")}

    failed_count = 0
    processed = 0

    with ThreadPoolExecutor(max_workers=max_workers) as executor:
        futures = {executor.submit(process_blob, blob, files): blob for blob in blobs}
        for future in as_completed(futures):
            fname, out_count, links, failed = future.result()
            if failed:
                failed_count += 1

            outgoing[fname] = out_count
            for target in links:
                incoming[target] += 1
                graph[target].add(fname)

            processed += 1
            if processed % 1000 == 0:
                print(f"Processed {processed}/{len(files)} files...")

    print(f"Finished processing {len(files)} files. Failed to read {failed_count} files.")
    return files, outgoing, incoming, graph

def compute_pagerank(files, graph, outgoing, tol=0.005, d=0.85):
    n = len(files)
    base = (1 - d) / n
    pagerank = {page: 1 / n for page in files}
    out_degree = {page: outgoing.get(page, 0) for page in files}

    iteration = 0
    while True:
        iteration += 1
        new_pr = {}
        for page in files:
            rank_sum = 0.0
            for incoming_page in graph.get(page, []):
                if out_degree[incoming_page] > 0:
                    rank_sum += pagerank[incoming_page] / out_degree[incoming_page]
            new_pr[page] = base + d * rank_sum

        delta = sum(abs(new_pr[p] - pagerank[p]) for p in files)
        print(f"Iteration {iteration}: delta={delta:.6f}")

        if delta <= tol:
            print(f"PageRank converged after {iteration} iterations.")
            print(f"PageRank sum: {sum(new_pr.values()):.6f}")

            return new_pr

        pagerank = new_pr
def print_stats(name, arr):
    print(f"\n{name} Links:")
    print(f"Min: {min(arr)}")
    print(f"Max: {max(arr)}")
    print(f"Mean: {statistics.mean(arr):.2f}")
    print(f"Median: {statistics.median(arr)}")
    q = np.percentile(arr, [0, 20, 40, 60, 80, 100])
    print(f"Quintiles (20/40/60/80 %): {q.astype(int)}")

def compute_stats(incoming, outgoing):
    incoming_counts = list(incoming.values())
    outgoing_counts = list(outgoing.values())
    print_stats("Incoming", incoming_counts)
    print_stats("Outgoing", outgoing_counts)

def print_top_pagerank(pagerank, top_n=5):
    top_pages = sorted(pagerank.items(), key=lambda x: x[1], reverse=True)[:top_n]
    print("\nTop Pages by PageRank:")
    for page, score in top_pages:
        print(f"{page}: {score:.6f}")

# Same hardcoded test used in local compute file

def test():
    files = {"A.html", "B.html", "C.html", "D.html"}
    graph = {
        "A.html": {"C.html"},
        "B.html": {"A.html"},
        "C.html": {"A.html", "B.html", "D.html"},
        "D.html": set(),
    }
    outgoing = {
        "A.html": 2,
        "B.html": 1,
        "C.html": 1,
        "D.html": 1,
    }

    pr1 = compute_pagerank(files, graph, outgoing)
    pr2 = compute_pagerank(files, graph, outgoing)

    total = sum(pr1.values())
    assert abs(total - 1.0) < 1e-6, f"Total PR {total} != 1.0"
    for pr in pr1.values():
        assert pr > 0
    assert pr1["C.html"] > pr1["A.html"]
    assert pr1["A.html"] > pr1["B.html"]
    assert pr1["B.html"] > pr1["D.html"]
    for page in files:
        assert abs(pr1[page] - pr2[page]) < 1e-9, f"Non-deterministic score for {page}"

    print("\nDeterministic PageRank scores:")
    for page, score in sorted(pr1.items(), key=lambda x: x[1], reverse=True):
        print(f"{page}: {score:.6f}")

# Main
def main():
    BUCKET_NAME = "hche-cs528-hw2"
    PREFIX = "20000/"

    print("Reading and parsing files from Google Cloud Storage concurrently...")
    files, outgoing, incoming, graph = parse_links_gcs_concurrent(BUCKET_NAME, PREFIX, max_workers=32)

    compute_stats(incoming, outgoing)
    pagerank = compute_pagerank(files, graph, outgoing)
    print_top_pagerank(pagerank)

    # test()

if __name__ == "__main__":
    main()