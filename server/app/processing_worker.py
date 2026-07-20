from __future__ import annotations

import logging
import os
import time

from .main import claim_next_processing_job, fail_processing_job, process_claimed_job


logging.basicConfig(level=os.environ.get("LOG_LEVEL", "INFO"))
logger = logging.getLogger(__name__)


def main() -> None:
    idle_seconds = max(1.0, float(os.environ.get("PROCESSING_WORKER_IDLE_SECONDS", "3")))
    logger.info("server processing worker started")
    while True:
        row = claim_next_processing_job()
        if row is None:
            time.sleep(idle_seconds)
            continue
        try:
            process_claimed_job(row)
        except Exception as exc:
            logger.exception("server processing job failed")
            fail_processing_job(row, exc)


if __name__ == "__main__":
    main()
