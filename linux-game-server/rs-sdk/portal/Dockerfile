FROM python:3.14-alpine
COPY requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir --no-deps -r /app/requirements.txt
WORKDIR /app
COPY server.py original.py theme.css /app/
ENV PYTHONDONTWRITEBYTECODE=1
