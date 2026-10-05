#!/usr/bin/env bash
# Clones the test-graph repo, uses its `ecg` package to build an ECG content
# graph of this repo (scripts/build_ecg_graph.py), writes it locally, then
# uploads it to S3 (see .harness/pipelines/agentic-testing-gate.yaml).
#
# Env vars (set by the Harness pipeline step):
#   ECG_TOOL_DIR      - existing checkout of the repo holding the `ecg` package
#                       (Harness clones it with a GitClone step, since the repo
#                       is private and needs the GitHub connector's credentials)
#   ECG_REPO_URL      - only if ECG_TOOL_DIR is unset: git URL to clone instead
#                       (e.g. when running locally with your own git credentials)
#   ECG_REPO_REF      - branch / tag / commit of ECG_REPO_URL (default: main)
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

: "${ECG_S3_BUCKET:?ECG_S3_BUCKET must be set (pipeline variable ecgS3Bucket)}"
: "${SERVICE_NAME:?SERVICE_NAME must be set}"
: "${COMMIT_SHA:?COMMIT_SHA must be set}"
ECG_OUTPUT_DIR="${ECG_OUTPUT_DIR:-ecg-output}"
ECG_S3_PREFIX="${ECG_S3_PREFIX:-ecg-graphs}"

REPO_ROOT="$(pwd)"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

if [ -n "${ECG_TOOL_DIR:-}" ]; then
  [ -d "$ECG_TOOL_DIR/ecg" ] || { echo "ECG_TOOL_DIR=${ECG_TOOL_DIR} has no ecg/ package" >&2; exit 1; }
  echo "==> Using ecg tool checkout at ${ECG_TOOL_DIR} ($(git -C "$ECG_TOOL_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown))"
else
  : "${ECG_REPO_URL:?set ECG_TOOL_DIR or ECG_REPO_URL}"
  ECG_REPO_REF="${ECG_REPO_REF:-main}"
  echo "==> Cloning ${ECG_REPO_URL} @ ${ECG_REPO_REF}"
  ECG_TOOL_DIR="$WORKDIR/ecg-tool"
  git clone --quiet "$ECG_REPO_URL" "$ECG_TOOL_DIR"
  git -C "$ECG_TOOL_DIR" checkout --quiet "$ECG_REPO_REF"
fi

echo "==> Installing ecg dependencies"
python3 -m pip install --quiet --upgrade pip
python3 -m pip install --quiet -r "$ECG_TOOL_DIR/requirements-server.txt"

echo "==> Building ECG graph for ${SERVICE_NAME} @ ${COMMIT_SHA}"
PYTHONPATH="$ECG_TOOL_DIR${PYTHONPATH:+:$PYTHONPATH}" \
  python3 "$REPO_ROOT/scripts/build_ecg_graph.py" "$REPO_ROOT" "$REPO_ROOT/$ECG_OUTPUT_DIR"
ls -l "$REPO_ROOT/$ECG_OUTPUT_DIR"

S3_BASE="s3://${ECG_S3_BUCKET}/${ECG_S3_PREFIX}/${SERVICE_NAME}"
echo "==> Uploading to ${S3_BASE}/${COMMIT_SHA}/"
aws s3 cp --recursive --region "$AWS_REGION" \
  "$REPO_ROOT/$ECG_OUTPUT_DIR" "${S3_BASE}/${COMMIT_SHA}/"
aws s3 sync --delete --region "$AWS_REGION" \
  "$REPO_ROOT/$ECG_OUTPUT_DIR" "${S3_BASE}/latest/"
echo "==> ECG graph uploaded"
