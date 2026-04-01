import json

with open("logs.json") as f:
    logs = json.load(f)

headers, reads, sends, dbs, totals = [], [], [], [], []

for entry in logs:
    p = entry.get("jsonPayload", {})
    if not isinstance(p, dict):
        continue
    if p.get("headers_ns", 0) > 0: headers.append(p["headers_ns"])
    if p.get("read_ns", 0) > 0:    reads.append(p["read_ns"])
    if p.get("send_ns", 0) > 0:    sends.append(p["send_ns"])
    if p.get("db_ns", 0) > 0:      dbs.append(p["db_ns"])
    if p.get("total_ns", 0) > 0:   totals.append(p["total_ns"])

def stats(name, vals):
    if not vals:
        print(f"{name}: no data")
        return
    avg = sum(vals)/len(vals)/1e6
    print(f"{name}: avg={avg:.2f}ms  min={min(vals)/1e6:.2f}ms  max={max(vals)/1e6:.2f}ms ")

stats("Header extraction", headers)
stats("GCS read        ", reads)
stats("Send response   ", sends)
stats("DB insert       ", dbs)
