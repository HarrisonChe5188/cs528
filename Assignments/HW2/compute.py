from collections import defaultdict
import os
import statistics
from bs4 import BeautifulSoup
from urllib.parse import urlparse
from pathlib import Path

import numpy as np

incoming = defaultdict(int)
outgoing = defaultdict(int)

BASE_DIR = Path(__file__).resolve().parent

LINK_DIR = BASE_DIR / "generated_links"
dir = LINK_DIR

print(dir.exists())
files = {
    f for f in os.listdir(dir)
    if f.endswith(".html")
}

for fname in files:
    path = os.path.join(dir, fname)

    with open(path, encoding="utf-8", errors="ignore") as f:
        soup = BeautifulSoup(f, "html.parser")

    outgoing[fname] += 0
    incoming[fname] += 0

    for a in soup.find_all("a", href=True):
        href = a["href"]

        target = os.path.basename(urlparse(href).path)

        if target in files:
            outgoing[fname] += 1
            incoming[target] += 1

incoming_counts = list(incoming.values())
outgoing_counts = list(outgoing.values())

def print_stats(name, arr):
    print(f"\n{name} Links:")
    print(f"Min: {min(arr)}")
    print(f"Max: {max(arr)}")
    print(f"Mean: {statistics.mean(arr):.2f}")
    print(f"Median: {statistics.median(arr)}")
    q = np.percentile(arr, [20, 40, 60, 80])
    print(f"Quintiles (20/40/60/80 %): {q.astype(int)}")

print_stats("Incoming", incoming_counts)
print_stats("Outgoing", outgoing_counts)
