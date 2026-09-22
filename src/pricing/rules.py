"""Pricing rules for order quotes.

Computes the discount and total price for an order. This is the business
logic a system test exercises end-to-end - changing
DISCOUNT_PCT_LARGE_ORDER here, without touching the API contract in
src/api/openapi.yaml, is exactly the kind of regression a schema/contract
diff alone can never catch.
"""
from __future__ import annotations

LARGE_ORDER_THRESHOLD = 100
DISCOUNT_PCT_LARGE_ORDER = 0.05
DISCOUNT_PCT_STANDARD = 0.0


def compute_quote(order: dict) -> dict:
    amount = order.get("amount", 0)
    discount_pct = DISCOUNT_PCT_LARGE_ORDER if amount >= LARGE_ORDER_THRESHOLD else DISCOUNT_PCT_STANDARD
    total = round(amount * (1 - discount_pct), 2)
    return {"discountPct": discount_pct, "total": total, "currency": "AUD"}
