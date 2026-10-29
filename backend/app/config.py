from typing import Annotated

from pydantic import field_validator
from pydantic_settings import BaseSettings, NoDecode, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    database_url: str = "postgresql+asyncpg://meetings:meetings@localhost:5432/meetings"
    # Lambda serves one request per instance at a time, so it runs with a pool of 1.
    db_pool_size: int = 5
    db_max_overflow: int = 10
    # Cognito user pool and app client whose ID tokens the API accepts (make deploy-auth).
    cognito_user_pool_id: str = ""
    cognito_client_id: str = ""
    # The pool's jwks.json. Set on AWS, where the function has no internet access; locally the
    # keys are downloaded on first use.
    cognito_jwks: str = ""
    # S3 bucket the weekly report builder writes to (set on the report-builder function).
    reports_bucket: str = ""
    # Claude on Amazon Bedrock, used by the agenda parser (app.ai). The model id is configuration,
    # not code, so it can be changed (and compared) without a new release.
    parser_model: str = "anthropic.claude-opus-5-5"
    parser_effort: str = "low"
    bedrock_region: str = "us-east-1"
    # Only for trying the parser from a laptop while Bedrock is not available: "openai" sends the
    # same prompt and schema to OpenAI. The deployed function always uses Bedrock.
    parser_provider: str = "bedrock"
    openai_api_key: str = ""
    openai_model: str = "gpt-4o-mini"
    # Any OpenAI-compatible endpoint works, e.g. Gemini's
    # https://generativelanguage.googleapis.com/v1beta/openai
    openai_base_url: str = "https://api.openai.com/v1"
    cors_origins: Annotated[list[str], NoDecode] = [
        "http://localhost:5173",
        "http://localhost:3000",
    ]

    @field_validator("cors_origins", mode="before")
    @classmethod
    def split_origins(cls, value: object) -> object:
        if isinstance(value, str):
            return [origin.strip() for origin in value.split(",") if origin.strip()]
        return value


settings = Settings()
