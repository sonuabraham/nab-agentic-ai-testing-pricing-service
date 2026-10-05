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

# Check the AWS credentials up front so a bad secret fails in seconds with a
# useful message, not after the build. Prints shape only, never values.
echo "==> Checking AWS credentials"
KEY="${AWS_ACCESS_KEY_ID:-}" SECRET="${AWS_SECRET_ACCESS_KEY:-}" TOKEN="${AWS_SESSION_TOKEN:-}"
# fp = first 8 hex chars of the value's sha256 - compare against a local run of
#   for v in AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN; do printf '%s' "${!v}" | sha256sum | cut -c1-8; done
# to tell which Harness secret doesn't match the credentials you exported.
fp() { printf '%s' "$1" | sha256sum | cut -c1-8; }
echo "    access key id: prefix=${KEY:0:4} length=${#KEY} fp=$(fp "$KEY") (expect AKIA/ASIA, 20)"
echo "    secret key: length=${#SECRET} fp=$(fp "$SECRET") (expect 40)"
echo "    session token: length=${#TOKEN} fp=$(fp "$TOKEN") (0 = not set; required for ASIA keys)"
for var in AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN; do
  case "${!var:-}" in
    *[[:space:]=\"\']*) echo "    WARNING: ${var} contains whitespace, '=' or quotes - paste only the value, without 'export ${var}='" >&2 ;;
  esac
done
case "$KEY" in
  ASIA*) [ -n "${AWS_SESSION_TOKEN:-}" ] || echo "    WARNING: ASIA (temporary) key without AWS_SESSION_TOKEN - AWS will reject it" >&2 ;;
esac
if ! aws sts get-caller-identity --region "$AWS_REGION" --query Arn --output text; then
  echo "AWS rejected these credentials - update the pricing_service_harness_invoker_* secrets (InvalidClientTokenId = wrong/mangled key, ExpiredToken = refresh them)" >&2
  exit 1
fi

if [ -n "${ECG_TOOL_DIR:-}" ]; then
  # The checkout root is whichever dir holds ecg/__init__.py - normally
  # ECG_TOOL_DIR itself, but allow for the clone landing one level deeper.
  INIT="$(find "$ECG_TOOL_DIR" -maxdepth 3 -path '*/ecg/__init__.py' 2>/dev/null | head -1)"
  if [ -z "$INIT" ]; then
    echo "No ecg/ package under ECG_TOOL_DIR=${ECG_TOOL_DIR}. Contents:" >&2
    ls -la "$ECG_TOOL_DIR" >&2 || true
    echo "Workspace (${REPO_ROOT}):" >&2
    ls -la "$REPO_ROOT" >&2
    exit 1
  fi
  ECG_TOOL_DIR="$(dirname "$(dirname "$INIT")")"
  echo "==> Using ecg tool checkout at ${ECG_TOOL_DIR} ($(git -C "$ECG_TOOL_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown))"
  # A checkout inside this repo would be scanned into its graph - move it out.
  case "$(cd "$ECG_TOOL_DIR" && pwd)/" in
    "$REPO_ROOT"/*)
      mv "$ECG_TOOL_DIR" "$WORKDIR/ecg-tool"
      ECG_TOOL_DIR="$WORKDIR/ecg-tool"
      ;;
  esac
else
  : "${ECG_REPO_URL:?set ECG_TOOL_DIR or ECG_REPO_URL}"
  ECG_REPO_REF="${ECG_REPO_REF:-main}"
  echo "==> Cloning ${ECG_REPO_URL} @ ${ECG_REPO_REF}"
  ECG_TOOL_DIR="$WORKDIR/ecg-tool"
  git clone --quiet "$ECG_REPO_URL" "$ECG_TOOL_DIR"
  git -C "$ECG_TOOL_DIR" checkout --quiet "$ECG_REPO_REF"
fi

# test-graph's requirements-server.txt pins versions (e.g. numpy 2.4.x) that
# need Python >= 3.11, but the Harness Cloud image ships 3.10 - so build a
# 3.12 venv with uv, which fetches that interpreter itself.
ECG_PYTHON_VERSION="${ECG_PYTHON_VERSION:-3.12}"
export UV_CACHE_DIR="$WORKDIR/uv-cache" UV_PYTHON_INSTALL_DIR="$WORKDIR/uv-python"
echo "==> Creating Python ${ECG_PYTHON_VERSION} venv for ecg"
if ! command -v uv >/dev/null 2>&1; then
  python3 -m pip install --quiet --disable-pip-version-check --target "$WORKDIR/uv-bin" uv
  export PATH="$WORKDIR/uv-bin/bin:$PATH"
fi
uv venv --quiet --python "$ECG_PYTHON_VERSION" "$WORKDIR/venv"
VENV_PY="$WORKDIR/venv/bin/python"

echo "==> Installing ecg dependencies"
uv pip install --quiet --python "$VENV_PY" -r "$ECG_TOOL_DIR/requirements-server.txt"

echo "==> Building ECG graph for ${SERVICE_NAME} @ ${COMMIT_SHA}"
PYTHONPATH="$ECG_TOOL_DIR${PYTHONPATH:+:$PYTHONPATH}" \
  "$VENV_PY" "$REPO_ROOT/scripts/build_ecg_graph.py" "$REPO_ROOT" "$REPO_ROOT/$ECG_OUTPUT_DIR"
ls -l "$REPO_ROOT/$ECG_OUTPUT_DIR"

S3_BASE="s3://${ECG_S3_BUCKET}/${ECG_S3_PREFIX}/${SERVICE_NAME}"
echo "==> Uploading to ${S3_BASE}/${COMMIT_SHA}/"
aws s3 cp --recursive --region "$AWS_REGION" \
  "$REPO_ROOT/$ECG_OUTPUT_DIR" "${S3_BASE}/${COMMIT_SHA}/"
aws s3 sync --delete --region "$AWS_REGION" \
  "$REPO_ROOT/$ECG_OUTPUT_DIR" "${S3_BASE}/latest/"
echo "==> ECG graph uploaded"
