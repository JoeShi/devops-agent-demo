FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py .

# Non-root user with numeric UID for K8s runAsNonRoot
RUN useradd -u 1000 -m botuser
USER 1000

CMD ["python", "app.py"]
