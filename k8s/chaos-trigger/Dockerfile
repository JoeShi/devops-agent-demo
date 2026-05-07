FROM python:3.12-slim
RUN pip install --no-cache-dir flask flask-cors && \
    apt-get update && apt-get install -y --no-install-recommends curl && \
    curl -LO "https://dl.k8s.io/release/v1.33.0/bin/linux/amd64/kubectl" && \
    chmod +x kubectl && mv kubectl /usr/local/bin/ && \
    apt-get remove -y curl && apt-get autoremove -y && rm -rf /var/lib/apt/lists/*
USER 1000
COPY app.py /app/app.py
WORKDIR /app
EXPOSE 8080
CMD ["python", "app.py"]
