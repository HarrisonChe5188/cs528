#!/usr/bin/env python3
import os
import json
import pickle
from datetime import datetime

import pandas as pd
import mysql.connector
from google.cloud import storage

from sklearn.model_selection import train_test_split
from sklearn.metrics import accuracy_score
from sklearn.ensemble import RandomForestClassifier
from sklearn.pipeline import Pipeline
from sklearn.compose import ColumnTransformer
from sklearn.preprocessing import OneHotEncoder
from sklearn.impute import SimpleImputer


DB_HOST = os.environ.get("DB_HOST", "127.0.0.1")
DB_PORT = int(os.environ.get("DB_PORT", "3306"))
DB_USER = os.environ.get("DB_USER", "")
DB_PASSWORD = os.environ.get("DB_PASSWORD", "")
DB_NAME = os.environ.get("DB_NAME", "")
OUTPUT_BUCKET = os.environ.get("OUTPUT_BUCKET", "")
GCP_PROJECT = os.environ.get("GCP_PROJECT", "")

OUTPUT_PREFIX = "hw6_outputs"


def connect_db():
    return mysql.connector.connect(
        host=DB_HOST,
        port=DB_PORT,
        user=DB_USER,
        password=DB_PASSWORD,
        database=DB_NAME,
        ssl_disabled=True,
    )


def load_data(conn):
    query = """
    SELECT
        r.client_ip,
        c.country,
        r.gender,
        r.age,
        r.income,
        r.is_banned,
        r.time_of_day,
        r.requested_file
    FROM request_logs r
    JOIN clients c ON r.client_ip = c.client_ip
    """
    return pd.read_sql(query, conn)


def upload_file(local_path, bucket_name, dest_name):
    if not bucket_name:
        print(f"Skipping upload for {local_path}: OUTPUT_BUCKET not set.")
        return
    client = storage.Client()
    bucket = client.bucket(bucket_name)
    blob = bucket.blob(dest_name)
    blob.upload_from_filename(local_path)
    print(f"Uploaded gs://{bucket_name}/{dest_name}")


def save_text(path, text):
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)


def model_ip_to_country(df):
    # Build map from ALL unique IPs - every IP has exactly one country
    ip_country_map = df.groupby("client_ip")["country"].first().to_dict()
    
    # Test on a random 20% sample of rows
    _, test_df = train_test_split(df, test_size=0.2, random_state=42)
    test_df = test_df.copy()
    test_df["predicted_country"] = test_df["client_ip"].map(ip_country_map)
    test_df["correct"] = (test_df["predicted_country"] == test_df["country"]).astype(int)

    acc = accuracy_score(test_df["country"], test_df["predicted_country"])

    out_csv = "ip_country_test_predictions.csv"
    test_df[["client_ip", "country", "predicted_country", "correct"]].to_csv(out_csv, index=False)

    metrics = f"IP -> Country accuracy: {acc:.4f}\nRows: {len(test_df)}\n"
    save_text("ip_country_metrics.txt", metrics)

    return acc, out_csv, "ip_country_metrics.txt"


def model_income(df):
    work = df.copy()

    # Clean up types
    work["age"] = pd.to_numeric(work["age"], errors="coerce")
    work["is_banned"] = work["is_banned"].astype(int)
    work["time_of_day"] = pd.to_datetime(work["time_of_day"], format="%H:%M:%S", errors="coerce")
    work["hour"] = work["time_of_day"].dt.hour

    # Target
    y = work["income"].fillna("UNKNOWN")

    # Features
    X = work[["country", "gender", "is_banned", "hour"]].copy()

    categorical_features = ["country", "gender"]
    numeric_features = ["is_banned", "hour"]

    preprocess = ColumnTransformer(
        transformers=[
            ("cat", Pipeline(steps=[
                ("imputer", SimpleImputer(strategy="most_frequent")),
                ("onehot", OneHotEncoder(handle_unknown="ignore")),
            ]), categorical_features),
            ("num", Pipeline(steps=[
                ("imputer", SimpleImputer(strategy="median")),
            ]), numeric_features),
        ]
    )

    clf = RandomForestClassifier(
        n_estimators=200,
        random_state=42,
        class_weight="balanced_subsample",
        n_jobs=-1,
    )

    model = Pipeline(steps=[
        ("preprocess", preprocess),
        ("clf", clf),
    ])

    X_train, X_test, y_train, y_test = train_test_split(
        X, y, test_size=0.2, random_state=42, stratify=y if y.nunique() > 1 else None
    )

    model.fit(X_train, y_train)
    preds = model.predict(X_test)
    acc = accuracy_score(y_test, preds)

    out_df = X_test.copy()
    out_df["true_income"] = y_test.values
    out_df["predicted_income"] = preds
    out_df["correct"] = (out_df["true_income"] == out_df["predicted_income"]).astype(int)

    out_csv = "income_test_predictions.csv"
    out_df.to_csv(out_csv, index=False)

    metrics = f"Income prediction accuracy: {acc:.4f}\nRows: {len(out_df)}\n"
    save_text("income_metrics.txt", metrics)

    with open("income_model.pkl", "wb") as f:
        pickle.dump(model, f)

    return acc, out_csv, "income_metrics.txt", "income_model.pkl"


def main():
    if not all([DB_USER, DB_PASSWORD, DB_NAME]):
        raise SystemExit("DB_USER, DB_PASSWORD, and DB_NAME must be set.")

    conn = connect_db()
    try:
        df = load_data(conn)
        print(df[["client_ip", "country"]].drop_duplicates().head())
        print("Unique IPs:", df["client_ip"].nunique())
        print("Null countries:", df["country"].isna().sum())
    finally:
        conn.close()

    if df.empty:
        raise SystemExit("No data found in the database.")

    print(f"Loaded {len(df)} rows from DB.")

    ip_acc, ip_csv, ip_metrics = model_ip_to_country(df)
    print(f"IP -> Country accuracy: {ip_acc:.4f}")

    income_acc, income_csv, income_metrics, income_model_file = model_income(df)
    print(f"Income accuracy: {income_acc:.4f}")

    # Upload outputs
    timestamp = datetime.utcnow().strftime("%Y%m%dT%H%M%SZ")

    upload_file(ip_csv, OUTPUT_BUCKET, f"{OUTPUT_PREFIX}/{timestamp}_{ip_csv}")
    upload_file(ip_metrics, OUTPUT_BUCKET, f"{OUTPUT_PREFIX}/{timestamp}_{ip_metrics}")

    upload_file(income_csv, OUTPUT_BUCKET, f"{OUTPUT_PREFIX}/{timestamp}_{income_csv}")
    upload_file(income_metrics, OUTPUT_BUCKET, f"{OUTPUT_PREFIX}/{timestamp}_{income_metrics}")
    upload_file(income_model_file, OUTPUT_BUCKET, f"{OUTPUT_PREFIX}/{timestamp}_{income_model_file}")

    print("Done.")


if __name__ == "__main__":
    main()