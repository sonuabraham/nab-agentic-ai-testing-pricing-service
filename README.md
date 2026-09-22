# pricing-service (demo)

A minimal, realistic service used to exercise the
[nab-agentic-testing](../nab-agentic-testing) pipeline end-to-end from a
real Harness CI/CD run against a real GitHub repo, rather than the
fixture-based local demo.

```
src/api/openapi.yaml         - the API contract
src/pricing/rules.py         - the business logic (discount calculation)
src/api/app.py                - a minimal FastAPI service implementing the contract
tests/test_rules.py           - unit tests for the business logic
scripts/run_agentic_gate.sh   - diffs a PR/push, calls the deployed agentic-testing API, polls, gates
.harness/pipelines/           - the Harness CI pipeline (unit tests + the agentic-testing gate)
.harness/triggers/            - PR and push-to-main triggers for that pipeline
```

## Why these two files specifically

The nab-agentic-testing agents route on exactly these two signals:

- **`src/api/openapi.yaml` changing** -> a schema/contract signal (Change
  Detection Agent diffs this file's before/after content).
- **`src/pricing/rules.py` changing** -> a business-logic signal (it matches
  the `*pricing/rules*` glob in `agents/change_detection_agent/logic.py`'s
  `DEFAULT_LOGIC_CHANGE_GLOBS`).

Push a branch/PR that touches one, the other, or both, and the Classification
Agent should route it to contract tests, system tests, or a combined run
accordingly - see nab-agentic-testing's README for the full flow.

## Changes to try

- **Additive, non-breaking schema change** (should PASS): add a new optional
  response field to `src/api/openapi.yaml`, e.g. `taxAmount: {type: number}`
  under the `/quotes` response schema. `src/pricing/rules.py` untouched.
- **Breaking schema change** (should FAIL contract tests): remove the
  `currency` field from the `/quotes` response schema in
  `src/api/openapi.yaml`.
- **Business-logic regression** (should FAIL system tests, contract tests
  stay green): lower `DISCOUNT_PCT_LARGE_ORDER` in `src/pricing/rules.py`
  (e.g. `0.10` -> `0.05`). The API shape doesn't change at all - this is
  exactly the kind of regression a contract diff can't catch, which is why
  the System-Test Agent runs the real calculation instead.
- **Both at once**: do both of the above in the same PR - the Classification
  Agent should route to `BOTH`, contract tests run first, and system tests
  are skipped if contract tests fail (fail-fast).

## Running it locally

```bash
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements-dev.txt
pytest tests/
uvicorn src.api.app:app --reload   # serves POST /quotes on :8000
```

## Wiring to Harness

The gate pipeline lives in this repo (`.harness/pipelines/agentic-testing-gate.yaml`)
and calls nab-agentic-testing's **deployed** API - as opposed to
nab-agentic-testing's own fixture-based simulation pipeline, which needs no
AWS account at all (see `nab-agentic-testing/docs/harness-simulation-pipeline.md`).

One-time setup:

1. **Deploy nab-agentic-testing** if you haven't (`docs/deploying-to-aws.md`
   in that repo), with `enable_agentcore = true`.
2. From `nab-agentic-testing/infra/environments/dev`, get two Terraform
   outputs:
   ```bash
   terraform output -raw api_endpoint          # -> agentApiEndpoint pipeline variable
   terraform output -raw harness_invoker_user  # -> the IAM user to key below
   ```
3. Generate an access key for that user (it can only call
   `execute-api:Invoke` on this one API - nothing else):
   ```bash
   aws iam create-access-key --user-name <harness_invoker_user output>
   ```
   Store the `AccessKeyId`/`SecretAccessKey` as two Harness secrets named
   `pricing_service_harness_invoker_access_key_id` and
   `pricing_service_harness_invoker_secret_access_key` (or edit the
   `<+secrets.getValue(...)>` references in the pipeline YAML to match
   whatever you name them).
4. Create a Harness **GitHub connector** for this repo
   (`nab-agentic-ai-testing-pricing-service`).
5. Import `.harness/pipelines/agentic-testing-gate.yaml` into Harness
   (Pipelines -> Create Pipeline -> Import From Git), filling in every
   `<+input>` (org/project identifiers, the GitHub connector, the build
   spec, and the `agentApiEndpoint` pipeline variable from step 2).
6. Import the two triggers under `.harness/triggers/` the same way, or
   recreate them via Harness's trigger wizard if the YAML doesn't import
   cleanly (Harness's trigger schema has shifted across versions - see the
   comment at the top of each trigger file).

After that: open a PR touching `src/api/openapi.yaml` and/or
`src/pricing/rules.py` (see "Changes to try" above) and watch the Agentic
Testing Gate stage call the real deployed pipeline.
