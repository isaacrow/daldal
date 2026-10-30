FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY schema.sql .
COPY daldal_api ./daldal_api
# No access log: the API never records client IPs.
CMD ["uvicorn", "daldal_api.app:app", "--host", "0.0.0.0", "--port", "8080", "--no-access-log", "--proxy-headers"]
