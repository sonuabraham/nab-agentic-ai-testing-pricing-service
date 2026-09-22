from src.pricing.rules import compute_quote


def test_large_order_gets_discount():
    result = compute_quote({"amount": 150})
    assert result["discountPct"] == 0.10
    assert result["total"] == 135.0


def test_small_order_gets_no_discount():
    result = compute_quote({"amount": 40})
    assert result["discountPct"] == 0.0
    assert result["total"] == 40.0
