"""Minimal pricing-service API - implements POST /quotes per src/api/openapi.yaml."""
from __future__ import annotations

from fastapi import FastAPI
from pydantic import BaseModel

from src.pricing.rules import compute_quote

app = FastAPI(title="pricing-service")


class QuoteRequest(BaseModel):
    amount: float


@app.post("/quotes")
def get_quote(request: QuoteRequest) -> dict:
    return compute_quote({"amount": request.amount})
