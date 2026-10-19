"""What every API module shares: the error answer and the strict request body."""

from __future__ import annotations

from pydantic import BaseModel, ConfigDict


class ApiError(Exception):
    """Answered as `{"error": code, "message": text}` with `status`."""

    def __init__(self, status: int, code: str, message: str, headers: dict[str, str] | None = None) -> None:
        super().__init__(message)
        self.status = status
        self.code = code
        self.message = message
        self.headers = headers


class Body(BaseModel):
    model_config = ConfigDict(extra="forbid")
