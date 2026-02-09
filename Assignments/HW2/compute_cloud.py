from collections import defaultdict
import statistics
from bs4 import BeautifulSoup
from urllib.parse import urlparse
from concurrent.futures import ThreadPoolExecutor, as_completed
from google.cloud import storage
import numpy as np
import os
import lxml

# Process a single blob to extract outgoing links and count them
def process_blob(blob, files):
    fname = os.path.basename(blob.name)
    try:
        html_bytes = blob.download_as_bytes()
        html = html_bytes.decode("utf-8", errors="ignore")
    except Exception as e:
        print(f"Failed to read {fname}: {e}")
        return fname, 0, []

    soup = BeautifulSoup(html, "lxml")  
    links = []
    out_count = 0
    for a in soup.find_all("a", href=True):
        target = os.path.basename(urlparse(a["href"]).path)
        if target in files:
            out_count += 1
            links.append(target)
    return fname, out_count, links

# Incorporate concurrent processing to read and parse files from GCS efficiently (runs slow without concurrency)
def parse_links_gcs_concurrent(bucket_name, prefix, max_workers=32):
    incoming = defaultdict(int)
    outgoing = defaultdict(int)
    graph = defaultdict(set)

    client = storage.Client()
    bucket = client.bucket(bucket_name)
    blobs = list(bucket.list_blobs(prefix=prefix))
    files = {os.path.basename(blob.name) for blob in blobs if blob.name.endswith(".html")}

    with ThreadPoolExecutor(max_workers=max_workers) as executor:
        futures = {executor.submit(process_blob, blob, files): blob for blob in blobs}
        for future in as_completed(futures):
            fname, out_count, links = future.result()
            outgoing[fname] = out_count
            for target in links:
                incoming[target] += 1
                graph[target].add(fname)

    return files, outgoing, incoming, graph

def compute_pagerank(files, graph, outgoing, tol=0.005, d=0.85):
    n = len(files)
    base = (1 - d) / n
    pagerank = {page: 1 / n for page in files}

    def total_pr(pr):
        return sum(pr.values())

    while True:
        new_pr = {}
        for page in files:
            rank_sum = 0.0
            for incoming_page in graph.get(page, []):
                if outgoing[incoming_page] > 0:
                    rank_sum += pagerank[incoming_page] / outgoing[incoming_page]
            new_pr[page] = base + d * rank_sum

        old_sum = total_pr(pagerank)
        new_sum = total_pr(new_pr)
        if abs(new_sum - old_sum) / old_sum <= tol:
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
    PREFIX = "generated_links/"

    print("Reading and parsing files from Google Cloud Storage concurrently...")
    files, outgoing, incoming, graph = parse_links_gcs_concurrent(BUCKET_NAME, PREFIX, max_workers=32)

    compute_stats(incoming, outgoing)
    pagerank = compute_pagerank(files, graph, outgoing)
    print_top_pagerank(pagerank)

    test()

if __name__ == "__main__":
    main()