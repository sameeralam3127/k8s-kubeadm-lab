import asyncio

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from app.api.routes import router
from app.core.config import get_settings
from app.db.base import Base, engine
from app.db import models  # noqa: F401
from app.services.compute_central_service import scheduled_compute_central_refresh


settings = get_settings()

app = FastAPI(title=settings.app_name)
app.include_router(router, prefix=settings.api_prefix)
app.add_middleware(
    CORSMiddleware,
    allow_origins=settings.cors_origins,
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.on_event("startup")
async def on_startup() -> None:
    Base.metadata.create_all(bind=engine)
    app.state.compute_central_refresh_task = asyncio.create_task(scheduled_compute_central_refresh())


@app.on_event("shutdown")
async def on_shutdown() -> None:
    task = getattr(app.state, "compute_central_refresh_task", None)
    if task:
        task.cancel()
