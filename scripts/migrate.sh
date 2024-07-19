#!/bin/bash

set -e

MYSQL_ROOT_PASSWORD="qwer1234"

# PostgreSQL 연결 정보
POSTGRES_HOST=""
POSTGRES_PORT=""
POSTGRES_USER=""
POSTGRES_PASSWORD=""
POSTGRES_DB=""

# Docker Compose 명령어 설정
DOCKER_COMPOSE_CMD="docker compose"

create_docker_network() {
    docker network create migration_network
}

start_docker_compose() {
    echo "Starting Docker Compose services..."
    $DOCKER_COMPOSE_CMD up -d
    if [ $? -eq 0 ]; then
        echo "Docker Compose services have been started."
    else
        echo "Failed to start Docker Compose services."
        exit 1
    fi
}



wait_for_mysql() {
    echo "MySQL: 실행 대기..."
    local max_attempts=30
    local attempt=0
    while [ $attempt -lt $max_attempts ]; do
        if $DOCKER_COMPOSE_CMD exec -T mysql mysqladmin ping -h localhost -u root -p"${MYSQL_ROOT_PASSWORD}" --silent &> /dev/null; then
            echo "MySQL: 실행 완료."
            return 0
        fi
        attempt=$((attempt+1))
        echo "MySQL 연결 시도 중... ($attempt/$max_attempts)"
        sleep 5
    done
    echo "MySQL: 시작 실패. 최대 시도 횟수 초과."
    return 1
}

import_mysql_dump() {
    local dump_file="$1"
    local db_name="$2"
    echo "Importing MySQL dump file: ${dump_file}"
    
    # 데이터베이스 생성
    $DOCKER_COMPOSE_CMD exec -T mysql mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" -e "CREATE DATABASE IF NOT EXISTS ${db_name};"
    
    # 덤프 파일 임포트
    $DOCKER_COMPOSE_CMD exec -T mysql mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" "${db_name}" < "${dump_file}"
    
    if [ $? -eq 0 ]; then
        echo "MySQL dump file imported successfully."
    else
        echo "Failed to import MySQL dump file."
        exit 1
    fi
}

create_pgloader_config() {
    local mysql_db=$1
    local pg_db=$2
    echo "PGLoader 설정 파일 생성 (${mysql_db} -> ${pg_db})..."
    mkdir -p ./pgloader_config
    cat > ./pgloader_config/pgloader.load <<EOF

LOAD DATABASE
    FROM mysql://root:${MYSQL_ROOT_PASSWORD}@localhost:3306/${mysql_db}
    INTO postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@${POSTGRES_HOST}:${POSTGRES_PORT}/${pg_db}

WITH include drop, create tables, drop indexes, create indexes, foreign keys, uniquify index names

SET maintenance_work_mem to '128MB', work_mem to '12MB'

CAST type datetime to timestamp using zero-dates-to-null,
     type date to date using zero-dates-to-null,
     type int with extra auto_increment to serial,
     type bigint with extra auto_increment to bigserial

ALTER SCHEMA '${mysql_db}' RENAME TO 'public'

BEFORE LOAD DO
   \$\$ CREATE SCHEMA IF NOT EXISTS public; \$\$,
   \$\$ CREATE EXTENSION IF NOT EXISTS pgcrypto; \$\$
;
EOF
}

recreate_mysql_root_user() {
    echo "MySQL: Root계정 재생성..."
    $DOCKER_COMPOSE_CMD exec -T mysql mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" <<EOF
DROP USER IF EXISTS 'root'@'%';
CREATE USER 'root'@'%' IDENTIFIED WITH mysql_native_password BY '${MYSQL_ROOT_PASSWORD}';
GRANT ALL PRIVILEGES ON *.* TO 'root'@'%' WITH GRANT OPTION;
FLUSH PRIVILEGES;
EOF
}


check_postgres_host() {
    echo "check_postgres_host $POSTGRES_HOST"
    if [ "$POSTGRES_HOST" = "localhost" ] || [ "$POSTGRES_HOST" = "127.0.0.1" ]; then
        # Check if PostgreSQL is running in a Docker container
        if docker ps --format '{{.Names}}' | grep -q 'postgres'; then
            echo "PostgreSQL is running in a Docker container."
            POSTGRES_CONTAINER=$(docker ps --format '{{.Names}}' | grep 'postgres' | head -n 1)
            POSTGRES_NETWORK=$(docker inspect -f '{{range $key, $value := .NetworkSettings.Networks}}{{$key}}{{end}}' $POSTGRES_CONTAINER)
            echo "PostgreSQL container name: $POSTGRES_CONTAINER"
            echo "PostgreSQL network: $POSTGRES_NETWORK"
            POSTGRES_HOST=$POSTGRES_CONTAINER

            # Ensure MySQL container is connected to the same network
            docker network connect $POSTGRES_NETWORK mysql

            return 0
        else
            echo "PostgreSQL is running locally on the host."
            return 1
        fi
    fi
    return 2
}
   
execute_psql() {
    PGPASSWORD="${POSTGRES_PASSWORD}"  psql -h "${POSTGRES_HOST}" -p ${POSTGRES_PORT} -U "${POSTGRES_USER}" "$@"
}

migrate_database() {
    local db_name=$1
    echo "Migrating ${db_name} database..."
    echo "${POSTGRES_PASSWORD}"
    echo "${POSTGRES_HOST}"
    echo "${POSTGRES_PORT}"
    echo "${POSTGRES_USER}"

    # PostgreSQL 데이터베이스 존재 여부 확인
    db_exists=$(execute_psql -tAc "SELECT 1 FROM pg_database WHERE datname='${db_name}';")
    echo "db_exists: ${db_exists}"
    if [ -z "$db_exists" ]; then
        echo "Creating database ${db_name}..."
        execute_psql -d postgres -c "CREATE DATABASE \"${db_name}\";"
        if [ $? -ne 0 ]; then
            echo "Failed to create database ${db_name}. Exiting."
            return 1
        fi
        echo "Database ${db_name} created successfully."
    else
        echo "Database ${db_name} already exists. Skipping creation."
    fi

    create_pgloader_config ${db_name} ${db_name}
    $DOCKER_COMPOSE_CMD run --rm pgloader pgloader --verbose /pgloader_config/pgloader.load


    if [ $? -ne 0 ]; then
        echo "Migration for ${db_name} failed."
        return 1
    fi

    echo "Migration for ${db_name} completed successfully."
}

verify_migration() {
    local db_name=$1
    echo "Verifying migration for ${db_name}..."
    execute_psql -d "${db_name}" -c "\dt"
}

cleanup_docker_compose() {
    echo "Stopping and removing Docker Compose services..."
    $DOCKER_COMPOSE_CMD down -v
    if [ $? -eq 0 ]; then
        echo "Docker Compose services have been stopped and removed."
    else
        echo "Failed to stop and remove Docker Compose services."
    fi
}

main() {
    if [ $# -lt 6 ]; then
        echo "Usage: $0 <dump_file_path> <postgres_host> <postgres_port> <postgres_user> <postgres_password> <postgres_db>"
        exit 1
    fi

    local dump_file="$1"
    POSTGRES_HOST="$2"
    POSTGRES_PORT="$3"
    POSTGRES_USER="$4"
    POSTGRES_PASSWORD="$5"
    POSTGRES_DB="$6"

    if [ ! -f "$dump_file" ]; then
        echo "Error: File $dump_file does not exist."
        exit 1
    fi


    # 파일 이름에서 데이터베이스 이름 추출
    local db_name
    db_name=$(basename "$dump_file" _dumps.sql)
    
    # create_docker_network
    start_docker_compose
    wait_for_mysql
    recreate_mysql_root_user
    import_mysql_dump "${dump_file}" "${db_name}"

    # Check PostgreSQL host
    # check_postgres_host
    # postgres_host_type=$?
    echo "Processing database: $db_name"
    if migrate_database "${db_name}"; then
        verify_migration "${db_name}"
        echo "Migration completed for $db_name."
    else
        echo "Migration failed for $db_name."
        exit 1
    fi
}

main "$@"