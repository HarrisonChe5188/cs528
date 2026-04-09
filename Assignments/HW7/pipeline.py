import os
import re
import time
import logging
import argparse

_creds_path = os.environ.get("GOOGLE_APPLICATION_CREDENTIALS", "")
if _creds_path and not os.path.isfile(_creds_path):
    os.environ.pop("GOOGLE_APPLICATION_CREDENTIALS")

import apache_beam as beam
from apache_beam.io.fileio import MatchFiles, ReadMatches
from apache_beam.options.pipeline_options import PipelineOptions, SetupOptions  # FIX 1: import SetupOptions
from google.cloud import storage

# === CONFIG ===
PROJECT_ID       = "superb-memory-485622-u3"
REGION           = "us-central1"
DF_BUCKET        = f"gs://{PROJECT_ID}-hw7-dataflow"
TEMP_LOCATION    = f"{DF_BUCKET}/temp"
STAGING_LOCATION = f"{DF_BUCKET}/staging"

BUCKET_NAME      = "hche-cs528-hw2"
FILE_PREFIX      = "20000/"
LOCAL_FILE_LIMIT = 100

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger(__name__)


# === GCS MANIFEST DoFn (workaround for DirectRunner timeout) ===

class ListGCSFilesFn(beam.DoFn):
    def setup(self):
        # FIX 2: import inside setup() so the import is available on workers
        from google.cloud import storage as gcs
        self.client = gcs.Client(project=PROJECT_ID)

    def process(self, element):
        bucket_name, prefix, limit = element
        bucket = self.client.bucket(bucket_name)
        blobs  = bucket.list_blobs(prefix=prefix)
        count  = 0
        for blob in blobs:
            if blob.name.endswith(".html"):
                yield f"gs://{bucket_name}/{blob.name}"
                count += 1
                if limit and count >= limit:
                    break
        log.info("GCS manifest: yielded %d files", count)


# === TRANSFORMS ===

def read_file(uri):
    from apache_beam.io.filesystems import FileSystems
    with FileSystems.open(uri) as f:
        content = f.read().decode("utf-8", errors="replace")
    return os.path.basename(uri), content


# FIX 3: replace the inline lambda (which captured `os` and could fail to
# serialize on remote workers) with a plain top-level function.
def decode_readable_file(readable_file):
    path    = readable_file.metadata.path
    content = readable_file.read_utf8()
    return os.path.basename(path), content


def count_outgoing(file_kv):
    filename, content = file_kv
    links = re.findall(r'<a\s+href="(\d+)\.html"', content, re.IGNORECASE)
    return filename, len(links)


def extract_incoming(file_kv):
    _, content = file_kv
    links = re.findall(r'<a\s+href="(\d+)\.html"', content, re.IGNORECASE)
    return [(f"{lnk}.html", 1) for lnk in links]


def extract_bigrams(file_kv):
    _, content = file_kv
    text  = re.sub(r"<[^>]+>", " ", content)
    words = re.findall(r"\w+", text.lower())
    return [(" ".join(pair), 1) for pair in zip(words, words[1:])]


def format_result(label):
    def _fmt(ranked_list):
        lines = [f"=== {label} ==="]
        for rank, (name, count) in enumerate(ranked_list, 1):
            lines.append(f"  {rank}. {name}  ({count})")
        return "\n".join(lines)
    return _fmt


# === FILE PCOLLECTION (runner-aware) ===

def build_file_pcollection(p, runner):
    if runner == "DataflowRunner":
        return (
            p
            | "Match files"  >> MatchFiles(f"gs://{BUCKET_NAME}/{FILE_PREFIX}*.html")
            | "Read matches" >> ReadMatches()
            | "Decode"       >> beam.Map(decode_readable_file)  # FIX 3 applied here
        )
    else:
        log.info("DirectRunner: capping input at %d files to avoid gRPC timeout", LOCAL_FILE_LIMIT)
        return (
            p
            | "Seed manifest"  >> beam.Create([(BUCKET_NAME, FILE_PREFIX, LOCAL_FILE_LIMIT)])
            | "List GCS files" >> beam.ParDo(ListGCSFilesFn())
            | "Read each file" >> beam.Map(read_file)
        )


# === MAIN PIPELINE ===

def run(runner):
    run_id = int(time.time())
    output_prefix = f"output/run-{run_id}" if runner != "DataflowRunner" else f"{DF_BUCKET}/output/run-{run_id}"
    job_name = f"hw7-beam-{run_id}"
    log.info("Starting pipeline  runner=%s  job=%s", runner, job_name)

    if runner == "DataflowRunner":
        pipeline_args = [
            f"--runner={runner}",
            f"--project={PROJECT_ID}",
            f"--region={REGION}",
            f"--machine_type=e2-medium",
            f"--num_workers=1",
            f"--temp_location={TEMP_LOCATION}",
            f"--staging_location={STAGING_LOCATION}",
            f"--job_name={job_name}",
            "--save_main_session",
            "--no_use_public_ips",
        ]
    else:
        pipeline_args = [
            f"--runner={runner}",
            "--save_main_session",
            "--direct_num_workers=4",
        ]

    options = PipelineOptions(pipeline_args)
    # FIX 4: also set save_main_session on the options object directly —
    # passing it only as a string arg is sometimes not picked up by the SDK.
    options.view_as(SetupOptions).save_main_session = True

    start = time.perf_counter()

    with beam.Pipeline(options=options) as p:

        files = build_file_pcollection(p, runner)

        (
            files
            | "Count outgoing"  >> beam.Map(count_outgoing)
            | "Top 5 outgoing"  >> beam.combiners.Top.Of(5, key=lambda x: x[1])
            | "Format outgoing" >> beam.Map(format_result("TOP 5 OUTGOING LINKS"))
            | "Write outgoing"  >> beam.io.WriteToText(
                f"{output_prefix}/top_outgoing",
                file_name_suffix=".txt", shard_name_template=""
            )
        )

        (
            files
            | "Extract incoming" >> beam.FlatMap(extract_incoming)
            | "Sum incoming"     >> beam.CombinePerKey(sum)
            | "Top 5 incoming"   >> beam.combiners.Top.Of(5, key=lambda x: x[1])
            | "Format incoming"  >> beam.Map(format_result("TOP 5 INCOMING LINKS"))
            | "Write incoming"   >> beam.io.WriteToText(
                f"{output_prefix}/top_incoming",
                file_name_suffix=".txt", shard_name_template=""
            )
        )

        (
            files
            | "Extract bigrams" >> beam.FlatMap(extract_bigrams)
            | "Count bigrams"   >> beam.CombinePerKey(sum)
            | "Top 5 bigrams"   >> beam.combiners.Top.Of(5, key=lambda x: x[1])
            | "Format bigrams"  >> beam.Map(format_result("TOP 5 WORD BIGRAMS"))
            | "Write bigrams"   >> beam.io.WriteToText(
                f"{output_prefix}/top_bigrams",
                file_name_suffix=".txt", shard_name_template=""
            )
        )

    elapsed = time.perf_counter() - start
    log.info("Pipeline finished in %.1f s", elapsed)
    print(f"\nElapsed time: {elapsed:.1f}s\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--runner", default="DirectRunner",
        choices=["DirectRunner", "DataflowRunner"]
    )
    args = parser.parse_args()

    actual_runner = "BundleBasedDirectRunner" if args.runner == "DirectRunner" else "DataflowRunner"
    run(actual_runner)