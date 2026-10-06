# Base image pinned by digest (python:3.14-slim); Dependabot bumps it.
FROM python:3.14-slim@sha256:f85c5697265c178cc6887276c55fe16cf3d14ca35c3df6a5eab3b360534a55d2 AS build

# Install the hashed lock into a venv, so the runtime stage needs no pip cache or build tools.
# The venv has no pip of its own: the base image's pip installs into it, so pip and the
# libraries it bundles (urllib3, msgpack, setuptools) are not copied to the runtime stage.
COPY requirements.txt .
RUN python -m venv --without-pip /opt/venv \
    && pip --python /opt/venv/bin/python install --no-cache-dir --require-hashes -r requirements.txt


FROM python:3.14-slim@sha256:f85c5697265c178cc6887276c55fe16cf3d14ca35c3df6a5eab3b360534a55d2

ENV PATH="/opt/venv/bin:$PATH" \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

# Nothing is installed at runtime, so the base image's pip goes too
RUN python -m pip uninstall --yes pip

WORKDIR /app

COPY --from=build /opt/venv /opt/venv
COPY riskcheck/ riskcheck/

# Numeric non-root user: Kubernetes runAsNonRoot can only verify a numeric UID
USER 10001:10001

EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD ["python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/health', timeout=2)"]

CMD ["uvicorn", "riskcheck.main:app", "--host", "0.0.0.0", "--port", "8000"]
