#!/usr/bin/env bash
# Clones the test-graph repo, uses its `ecg` package to build an ECG content
# graph of this repo (scripts/build_ecg_graph.py), writes it locally, then
# uploads it to S3 (see .harness/pipelines/agentic-testing-gate.yaml).
#
# Env vars (set by the Harness pipeline step):
#   ECG_REPO_URL      - git URL of the repo holding the `ecg` package
#   ECG_REPO_REF      - branch / tag / commit of that repo to use (default: main)
#   ECG_OUTPUT_DIR    - local output dir (default: ecg-output)
#   ECG_S3_BUCKET     - bucket to upload the graph to
#   ECG_S3_PREFIX     - key prefix (default: ecg-graphs)
#   SERVICE_NAME      - logical service name, used in the S3 key
#   COMMIT_SHA        - commit the graph was built from, used in the S3 key
#   AWS_REGION, AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY (/ AWS_SESSION_TOKEN)
#     - credentials allowed s3:PutObject on the bucket/prefix
#
# Uploads to s3://$ECG_S3_BUCKET/$ECG_S3_PREFIX/$SERVICE_NAME/$COMMIT_SHA/ and
# mirrors the same files to .../$SERVICE_NAME/latest/.
set -euo pipefail

: "${ECG_REPO_URL:?ECG_REPO_URL must be set}"
: "${ECG_S3_BUCKET:?ECG_S3_BUCKET must be set (pipeline variable ecgS3Bucket)}"
: "${SERVICE_NAME:?SERVICE_NAME must be set}"
: "${COMMIT_SHA:?COMMIT_SHA must be set}"
ECG_REPO_REF="${ECG_REPO_REF:-main}"
ECG_OUTPUT_DIR="${ECG_OUTPUT_DIR:-ecg-output}"
ECG_S3_PREFIX="${ECG_S3_PREFIX:-ecg-graphs}"

REPO_ROOT="$(pwd)"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

echo "==> Cloning ${ECG_REPO_URL} @ ${ECG_REPO_REF}"
git clone --quiet "$ECG_REPO_URL" "$WORKDIR/ecg-tool"
git -C "$WORKDIR/ecg-tool" checkout --quiet "$ECG_REPO_REF"

echo "==> Installing ecg dependencies"
python3 -m pip install --quiet --upgrade pip
python3 -m pip install --quiet -r "$WORKDIR/ecg-tool/requirements-server.txt"

echo "==> Building ECG graph for ${SERVICE_NAME} @ ${COMMIT_SHA}"
PYTHONPATH="$WORKDIR/ecg-tool${PYTHONPATH:+:$PYTHONPATH}" \
  python3 "$REPO_ROOT/scripts/build_ecg_graph.py" "$REPO_ROOT" "$REPO_ROOT/$ECG_OUTPUT_DIR"
ls -l "$REPO_ROOT/$ECG_OUTPUT_DIR"

S3_BASE="s3://${ECG_S3_BUCKET}/${ECG_S3_PREFIX}/${SERVICE_NAME}"
echo "==> Uploading to ${S3_BASE}/${COMMIT_SHA}/"
aws s3 cp --recursive --region "$AWS_REGION" \
  "$REPO_ROOT/$ECG_OUTPUT_DIR" "${S3_BASE}/${COMMIT_SHA}/"
aws s3 sync --delete --region "$AWS_REGION" \
  "$REPO_ROOT/$ECG_OUTPUT_DIR" "${S3_BASE}/latest/"
echo "==> ECG graph uploaded"
