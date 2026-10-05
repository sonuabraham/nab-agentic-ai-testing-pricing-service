#!/usr/bin/env bash
# Computes this PR/push's diff against its base, calls the deployed
# nab-agentic-testing API with it, and polls until the agent-routed
# pipeline reaches a verdict - exits non-zero on FAIL or timeout, which is
# what fails the Harness stage (see .harness/pipelines/agentic-testing-gate.yaml).
#
# Env vars (set by the Harness pipeline step):
#   AGENT_API_ENDPOINT    - e.g. https://abc123.execute-api.ap-southeast-2.amazonaws.com/v1
#   AWS_REGION            - region the API is deployed in
#   SERVICE_NAME          - logical service name sent to the pipeline
#   OPENAPI_PATH          - path to this repo's OpenAPI spec
#   BUILD_TYPE            - "PR" or "branch" (Harness's <+codebase.build.type>)
#   TARGET_BRANCH         - PR base branch (only meaningful when BUILD_TYPE=PR)
#   SOURCE_BRANCH         - pushed branch (only meaningful when BUILD_TYPE=branch)
#   COMMIT_SHA            - commit under test
#   AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY (/ AWS_SESSION_TOKEN) - base
#     credentials for an identity in the nab-agentic-testing account
#   HARNESS_INVOKER_ROLE_ARN - optional; if set, the base credentials are
#     used to assume this role (scoped to execute-api:Invoke on this API only
#     - see infra/environments/dev/main.tf's aws_iam_role.harness_invoker in
#     the nab-agentic-testing repo) and the calls are signed as the role
set -euo pipefail

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

if [ -n "${HARNESS_INVOKER_ROLE_ARN:-}" ]; then
  echo "==> Assuming ${HARNESS_INVOKER_ROLE_ARN}"
  CREDS="$(aws sts assume-role \
    --role-arn "$HARNESS_INVOKER_ROLE_ARN" \
    --role-session-name "agentic-gate-${COMMIT_SHA:0:12}" \
    --query Credentials --output json)"
  AWS_ACCESS_KEY_ID="$(echo "$CREDS" | jq -r .AccessKeyId)"
  AWS_SECRET_ACCESS_KEY="$(echo "$CREDS" | jq -r .SecretAccessKey)"
  AWS_SESSION_TOKEN="$(echo "$CREDS" | jq -r .SessionToken)"
fi

# Temporary credentials (assumed role, SSO) must send their session token
# alongside the SigV4 signature or API Gateway rejects the call with 403.
SIGV4_ARGS=(
  --aws-sigv4 "aws:amz:${AWS_REGION}:execute-api"
  --user "${AWS_ACCESS_KEY_ID}:${AWS_SECRET_ACCESS_KEY}"
)
if [ -n "${AWS_SESSION_TOKEN:-}" ]; then
  SIGV4_ARGS+=(-H "x-amz-security-token: ${AWS_SESSION_TOKEN}")
fi

echo "==> Determining base ref (BUILD_TYPE=${BUILD_TYPE})"
if [ "$BUILD_TYPE" = "PR" ]; then
  git fetch origin "$TARGET_BRANCH" --quiet
  BASE_REF="origin/${TARGET_BRANCH}"
else
  # Push trigger: compare against the commit before this push. Works for the
  # common single-commit-push case; a multi-commit push still gets a
  # reasonable (if slightly broader) diff since it just walks back one more
  # commit than strictly needed.
  git fetch --deepen=1 origin "$SOURCE_BRANCH" --quiet || true
  BASE_REF="HEAD~1"
fi
echo "base ref: ${BASE_REF}"

echo "==> Extracting before/after OpenAPI spec (${OPENAPI_PATH})"
git show "${BASE_REF}:${OPENAPI_PATH}" >"${WORKDIR}/before.yaml" 2>/dev/null || echo "{}" >"${WORKDIR}/before.yaml"
cp "${OPENAPI_PATH}" "${WORKDIR}/after.yaml"

python3 -c "import yaml" 2>/dev/null || pip install --quiet pyyaml

python3 -c "
import json
import yaml

for name in ('before', 'after'):
    with open('${WORKDIR}/' + name + '.yaml') as f:
        data = yaml.safe_load(f) or {}
    with open('${WORKDIR}/' + name + '.json', 'w') as f:
        json.dump(data, f)
"

echo "==> Computing changed files"
git diff --name-only "${BASE_REF}...HEAD" >"${WORKDIR}/changed_files.txt" || true
jq -R -s -c 'split("\n") | map(select(length > 0))' "${WORKDIR}/changed_files.txt" >"${WORKDIR}/changed_files.json"
echo "changed files: $(cat "${WORKDIR}/changed_files.json")"

echo "==> Building request payload"
jq -n \
  --arg repo "$(git remote get-url origin)" \
  --arg commitSha "$COMMIT_SHA" \
  --arg serviceName "$SERVICE_NAME" \
  --slurpfile before "${WORKDIR}/before.json" \
  --slurpfile after "${WORKDIR}/after.json" \
  --slurpfile changedFiles "${WORKDIR}/changed_files.json" \
  '{
    repo: $repo,
    commitSha: $commitSha,
    environment: "ST",
    change: {
      serviceName: $serviceName,
      openapiBefore: $before[0],
      openapiAfter: $after[0],
      changedFiles: $changedFiles[0]
    }
  }' >"${WORKDIR}/payload.json"

echo "==> Starting a test run"
START_RESPONSE="$(curl -sS -X POST "${AGENT_API_ENDPOINT%/}/test-runs" \
  "${SIGV4_ARGS[@]}" \
  -H "Content-Type: application/json" \
  -d @"${WORKDIR}/payload.json")"
echo "response: ${START_RESPONSE}"

RUN_ID="$(echo "$START_RESPONSE" | jq -r '.runId // empty')"
if [ -z "$RUN_ID" ]; then
  echo "error: no runId in response - see above" >&2
  exit 1
fi
echo "runId: ${RUN_ID}"

echo "==> Polling for a verdict"
for _ in $(seq 1 60); do
  POLL_RESPONSE="$(curl -sS "${AGENT_API_ENDPOINT%/}/test-runs/${RUN_ID}" \
    "${SIGV4_ARGS[@]}")"
  STATUS="$(echo "$POLL_RESPONSE" | jq -r '.status // empty')"
  echo "status: ${STATUS:-<none>}"
  case "$STATUS" in
  PASSED)
    echo "$POLL_RESPONSE" | jq '.'
    exit 0
    ;;
  FAILED)
    echo "$POLL_RESPONSE" | jq '.'
    exit 1
    ;;
  esac
  sleep 30
done

echo "error: timed out waiting for the agentic testing pipeline" >&2
exit 1
