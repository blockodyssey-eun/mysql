#!/bin/bash

# Docker Compose 버전 확인 및 명령어 설정
set_docker_compose_cmd() {
    if docker compose version &> /dev/null; then
        DOCKER_COMPOSE_CMD="docker compose"
    elif docker-compose --version &> /dev/null; then
        DOCKER_COMPOSE_CMD="docker-compose"
    else
        echo "Error: Docker Compose not found. Please install Docker Compose."
        exit 1
    fi
    echo "Using Docker Compose command: $DOCKER_COMPOSE_CMD"
}

load_env() {
    source .env
}

docker_down_and_up() {
    $DOCKER_COMPOSE_CMD down -v
    $DOCKER_COMPOSE_CMD up -d
}

wait_for_service() {
    local service=$1
    local max_attempts=30
    local attempt=0
    
    echo "${service}: 실행 대기..."
    while [ $attempt -lt $max_attempts ]; do
        if [ "$service" = "MySQL" ] && $DOCKER_COMPOSE_CMD exec -T mysql mysqladmin ping -h mysql -u root -p"${MYSQL_ROOT_PASSWORD}" --silent &> /dev/null; then
            echo "${service}: 실행 완료."
            return 0
        elif [ "$service" = "PostgreSQL" ]; then
            echo "PostgreSQL이 시작될 때까지 대기 중..."
            if [ "$POSTGRES_HOST" = "postgres" ]; then
                if $DOCKER_COMPOSE_CMD exec -T postgres pg_isready -h localhost -U ${POSTGRES_USER} --quiet &> /dev/null; then
                    echo "PostgreSQL이 준비되었습니다."
                    return 0
                fi
            else
                if docker run --rm postgres:16 pg_isready -h ${POSTGRES_HOST} -p ${POSTGRES_PORT} -U ${POSTGRES_USER} --quiet &> /dev/null; then
                    echo "PostgreSQL이 준비되었습니다."
                    return 0
                fi
            fi
        fi
        attempt=$((attempt+1))
        echo "${service} 연결 시도 중... ($attempt/$max_attempts)"
        sleep 5
    done
    
    echo "${service}: 시작 실패. 최대 시도 횟수 초과."
    return 1
}


create_pgloader_config() {
    local mysql_db=$1
    local pg_db=$2
    echo "PGLoader 설정 파일 생성 (${mysql_db} -> ${pg_db})..."
    cat > pgloader.load <<EOF
LOAD DATABASE
    FROM mysql://root:${MYSQL_ROOT_PASSWORD}@mysql:3306/${mysql_db}
    INTO postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@${POSTGRES_HOST}:${POSTGRES_PORT}/${pg_db}

WITH include drop, create tables, drop indexes, create indexes, foreign keys, uniquify index names, quote identifiers

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
    $DOCKER_COMPOSE_CMD exec -T mysql mysql -h mysql -u root -p"${MYSQL_ROOT_PASSWORD}" <<EOF
DROP USER IF EXISTS 'root'@'%';
CREATE USER 'root'@'%' IDENTIFIED WITH mysql_native_password BY '${MYSQL_ROOT_PASSWORD}';
GRANT ALL PRIVILEGES ON *.* TO 'root'@'%' WITH GRANT OPTION;
FLUSH PRIVILEGES;
EOF
}

execute_psql() {
    if [ "$POSTGRES_HOST" = "postgres" ]; then
        $DOCKER_COMPOSE_CMD exec -T postgres psql -U ${POSTGRES_USER} "$@"
    else
        docker run --rm -e PGPASSWORD=${POSTGRES_PASSWORD} postgres:16 psql -h ${POSTGRES_HOST} -p ${POSTGRES_PORT} -U ${POSTGRES_USER} "$@"
    fi
}


migrate_database() {
    local db_name=$1
    echo "Migrating ${db_name} database..."

    # PostgreSQL 데이터베이스 존재 여부 확인
    db_exists=$(execute_psql -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname='${db_name}'")
    
    if [ -z "$db_exists" ]; then
        echo "Creating database ${db_name}..."
        execute_psql -d postgres -c "CREATE DATABASE ${db_name};"
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
    execute_psql -d ${db_name} -c "\dt"
}

main() {
    set_docker_compose_cmd
    load_env
    docker_down_and_up
    wait_for_service "MySQL"
    wait_for_service "PostgreSQL"

    recreate_mysql_root_user

    # 명령줄 인자 확인
    if [ $# -eq 0 ]; then
        echo "Usage: $0 <dump_file_path>"
        exit 1
    fi

    dump_file="$1"
    if [ ! -f "$dump_file" ]; then
        echo "Error: File $dump_file does not exist."
        exit 1
    fi

    # 파일 이름에서 데이터베이스 이름 추출
    db_name=$(basename "$dump_file" _dumps.sql)
    
    echo "Processing database: $db_name"
    migrate_database ${db_name}
    verify_migration ${db_name}

    echo "Migration completed for $db_name."
}

main "$@"