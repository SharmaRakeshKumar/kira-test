from pydantic_settings import BaseSettings


class Settings(BaseSettings):
    APP_VERSION: str = "1.0.0"
    ENVIRONMENT: str = "local"
    GIT_SHA: str = "unknown"

    # Blockchain mock service
    BLOCKCHAIN_SERVICE_URL: str = "http://blockchain-mock:8001"
    BLOCKCHAIN_TIMEOUT_SECONDS: float = 5.0

    # Observability
    OTLP_ENDPOINT: str = ""
    LOG_LEVEL: str = "INFO"

    # SOC 2: secrets should come from Vault/SSM in production
    SECRET_VENDOR_A_KEY: str = "mock-vendor-a-key"
    SECRET_VENDOR_B_KEY: str = "mock-vendor-b-key"

    class Config:
        env_file = ".env"


settings = Settings()
