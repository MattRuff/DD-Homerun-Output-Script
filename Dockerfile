# Python 3.12: rookiepy provides cp312 manylinux wheels; 3.13+ may not build.
FROM python:3.12-slim-bookworm

WORKDIR /app
ENV PYTHONUNBUFFERED=1

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY pull_info_from_opp.py .

ENTRYPOINT ["python", "pull_info_from_opp.py"]
CMD ["--help"]
