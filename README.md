# pricing-service (demo)

A minimal, realistic service used to exercise the
[nab-agentic-testing](../nab-agentic-testing) pipeline end-to-end from a
real Harness CI/CD run against a real GitHub repo, rather than the
fixture-based local demo.

```
src/api/openapi.yaml   - the API contract
src/pricing/rules.py   - the business logic (discount calculation)
src/api/app.py         - a minimal FastAPI service implementing the contract
tests/test_rules.py    - unit tests for the business logic
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

This repo doesn't carry its own agentic-testing gate pipeline - that lives
in nab-agentic-testing's `.harness/` directory (or is added here once you
point a Harness pipeline's codebase connector at this repo). See
`nab-agentic-testing/docs/harness-integration.md` for how a Harness stage
extracts this repo's before/after `openapi.yaml` and changed-files list from
the PR diff and calls the deployed nab-agentic-testing API with them.
