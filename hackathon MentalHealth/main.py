"""
Mental Health AI – Backend Entry Point
FastAPI application exposing the /api/commute-event endpoint.
"""

from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field
from typing import List, Union

from langflow_client import call_langflow, parse_ai_response

app = FastAPI(
    title="Mental Health AI – Commute Sensing API",
    description=(
        "Receives passive-sensing commute data from a mobile device, "
        "forwards it to a local Langflow AI flow, and returns a mental-health "
        "check-in response."
    ),
    version="1.0.0",
)

# ---------------------------------------------------------------------------
# Middleware: CORS Configuration (PENTING untuk Flutter)
# ---------------------------------------------------------------------------
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


# ---------------------------------------------------------------------------
# Request schema
# ---------------------------------------------------------------------------

class CommuteEvent(BaseModel):
    user_id: str = Field(..., example="user_001")
    origin: str = Field(..., example="Tenjo")
    destination: str = Field(..., example="Manggarai")
    duration_minutes: int = Field(..., ge=0, example=90)
    total_delay_minutes: int = Field(..., ge=0, example=30)
    transport_mode: str = Field(..., example="KRL")
    fatigue_level_sensor: Union[str, float] = Field(..., example=0.75)


# ---------------------------------------------------------------------------
# Response schema
# ---------------------------------------------------------------------------

class CommuteData(BaseModel):
    message: str
    recommendations: List[str]


class CommuteEventResponse(BaseModel):
    status: str
    user_id: str
    data: CommuteData


# ---------------------------------------------------------------------------
# Endpoints
# ---------------------------------------------------------------------------

@app.get("/", tags=["Health"])
def root():
    """Simple health-check endpoint."""
    return {"message": "Mental Health AI backend is running."}


@app.get("/api/health", tags=["Health"])
def health_check():
    """Endpoint khusus tes koneksi jaringan dari Flutter."""
    return {
        "status": "online",
        "message": "Server Commute Mind Companion Siap!"
    }


@app.post(
    "/api/commute-event",
    response_model=CommuteEventResponse,
    summary="Submit a commute passive-sensing event",
    tags=["Commute"],
)
def commute_event(event: CommuteEvent):
    """
    Accepts a passive-sensing commute payload from the mobile device,
    builds a natural-language summary, calls the Langflow AI flow, and
    returns the AI-generated mental-health response to the client.
    """
    try:
        result = call_langflow(event.model_dump())
    except Exception as exc:
        raise HTTPException(
            status_code=502,
            detail=f"Failed to reach Langflow: {exc}",
        ) from exc

    parsed = parse_ai_response(result["ai_response"])

    return CommuteEventResponse(
        status="ok",
        user_id=event.user_id,
        data=CommuteData(
            message=parsed["message"],
            recommendations=parsed["recommendations"],
        ),
    )