"""`python -m rackoon.app`: serve the API (the Docker image's entry point). Listens on RACKOON_HOST:RACKOON_PORT
(default 0.0.0.0:8080). Forwarded headers are handled by the app itself, only from RACKOON_TRUSTED_PROXIES."""

from __future__ import annotations

import logging
import os

import uvicorn

from .api import create_app
from .settings import Settings


def main() -> None:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    app = create_app(Settings.from_env())
    uvicorn.run(app, host=os.environ.get("RACKOON_HOST", "0.0.0.0"), port=int(os.environ.get("RACKOON_PORT", "8080")),
                proxy_headers=False, server_header=False, access_log=False)


if __name__ == "__main__":
    main()
