FROM python:3.14-alpine
COPY requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir --no-deps -r /app/requirements.txt
WORKDIR /app
COPY server.py original.py snapshot_policy.py live.py player_anims.py controller.py central_bank.py theme.css live_map.js bot_controller.js central_bank.js /app/
ENV PYTHONDONTWRITEBYTECODE=1
