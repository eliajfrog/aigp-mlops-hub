import os

import httpx
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel

app = FastAPI(title="aigp-devops-helper-pod")

_ML_ENDPOINT = "https://a0kcaohwpdorq.ml.jfrog.io/v1/devops_helper_elia_v2/predict"
_ML_TENANT = "a0kcaohwpdorq"


class PredictRequest(BaseModel):
    prompt: str


def _extract_answer(body) -> str:
    """Pull a plain string from various MLflow response shapes."""
    if isinstance(body, dict):
        preds = body.get("predictions", body.get("outputs"))
        if preds is not None:
            first = preds[0] if isinstance(preds, list) else preds
            if isinstance(first, dict):
                return str(first.get("answer", first))
            return str(first)
    if isinstance(body, list):
        return str(body[0])
    return str(body)


@app.post("/predict")
async def predict(request: PredictRequest):
    token = os.getenv("JFROG_ML_TOKEN")
    if not token:
        raise HTTPException(status_code=503, detail="JFROG_ML_TOKEN not configured")

    payload = {
        "columns": ["prompt"],
        "index": [0],
        "data": [[request.prompt]],
    }

    try:
        async with httpx.AsyncClient(timeout=30.0) as client:
            response = await client.post(
                _ML_ENDPOINT,
                json=payload,
                headers={
                    "Authorization": f"Bearer {token}",
                    "X-JFrog-Tenant-Id": _ML_TENANT,
                    "Content-Type": "application/json",
                },
            )
            response.raise_for_status()
    except httpx.HTTPStatusError as e:
        raise HTTPException(
            status_code=502,
            detail=f"Model call failed: HTTP {e.response.status_code}",
        )
    except httpx.RequestError as e:
        raise HTTPException(status_code=502, detail=f"Model unreachable: {e}")

    try:
        answer = _extract_answer(response.json())
    except Exception:
        answer = response.text

    return {
        "answer": answer,
        "model": "devops_helper_elia_v2",
        "governed_by": "aigp-devops-helper-llm",
        "version": os.getenv("APP_VERSION", "unknown"),
        "apptrust_stage": "PROD",
        "trusted_release": True,
    }


@app.get("/health")
async def health():
    return {"status": "ok", "model": "devops_helper_elia_v2"}
