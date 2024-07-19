#!/bin/bash
set -e

# 색상 정의
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' 

# 환경 변수 확인 및 사용자 입력 요청
read -p "Enter database name: " POSTGRES_DB
read -p "Enter database user: " POSTGRES_USER
read -s -p "Enter database password: " POSTGRES_PASSWORD
echo

IMAGE_NAME="postgres:latest"

if docker ps -a --format '{{.Names}}' | grep -q "^postgres$"; then
    echo -e "${YELLOW}Existing 'postgres' container found.${NC}"
    echo -e "${YELLOW}Please remove it manually if you want to create a new one.${NC}"
    exit 1
fi


echo -e "${GREEN}Starting PostgreSQL Docker container...${NC}"
docker run -d \
  --name postgres \
  -e POSTGRES_DB="$POSTGRES_DB" \
  -e POSTGRES_USER="$POSTGRES_USER" \
  -e POSTGRES_PASSWORD="$POSTGRES_PASSWORD" \
  -p 5432:5432 \
  $IMAGE_NAME

echo -e "${CYAN}PostgreSQL container is starting. You can connect to it using:${NC}"
echo -e "${MAGENTA}Host:${NC} localhost"
echo -e "${MAGENTA}Port:${NC} 5432"
echo -e "${MAGENTA}Database:${NC} $POSTGRES_DB"
echo -e "${MAGENTA}User:${NC} $POSTGRES_USER"
echo -e "${MAGENTA}Password:${NC} [The password you entered]"

wait_for_postgres() {
    echo "Waiting for PostgreSQL to be ready..."
    local max_attempts=30
    local attempt=0
    while [ $attempt -lt $max_attempts ]; do
        if docker exec postgres pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB" -h localhost -p 5432; then
            echo "PostgreSQL is ready."
            return 0
        fi
        attempt=$((attempt+1))
        echo "Waiting for PostgreSQL... ($attempt/$max_attempts)"
        sleep 5
    done
    echo "PostgreSQL is not ready after $max_attempts attempts."
    return 1
}

if ! wait_for_postgres; then
    echo -e "${RED}Failed to connect to PostgreSQL.${NC}"
    exit 1
fi
