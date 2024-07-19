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

execute_psql() {
    docker run --rm --network host -e PGPASSWORD="${POSTGRES_PASSWORD}" postgres:latest psql -h "${POSTGRES_HOST}" -p ${POSTGRES_PORT} -U "${POSTGRES_USER}" "$@"
}

migrate_database() {
    local db_name=$1
    echo "Migrating ${db_name} database..."

    # PostgreSQL 데이터베이스 존재 여부 확인
    db_exists=$(execute_psql -tAc "SELECT 1 FROM pg_database WHERE datname='${db_name}';")
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
get_mysql_info() {
    $DOCKER_COMPOSE_CMD exec -T mysql mysql -u root -p"${MYSQL_ROOT_PASSWORD}" -D "${MYSQL_DATABASE}" -se "$1" 2>/dev/null
}

get_pg_info() {
    # echo "Executing PostgreSQL query: $1" >&2
    result=$(execute_psql -t -c "$1")
    # echo "Raw result: '$result'" >&2
    trimmed_result=$(echo "$result" | tr -d ' ')
    # echo "Trimmed result: '$trimmed_result'" >&2
    echo "$trimmed_result"
}

compare_structure() {
    echo "구조 비교:"
    printf "%-20s | %-10s | %-10s | %-5s\n" "Metric" "MySQL" "PostgreSQL" "Match"
    printf "%s\n" "---------------------------------------------------"

    metrics=(
        "Table Count:SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${MYSQL_DATABASE}':SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='public'"
        "Column Count:SELECT COUNT(*) FROM information_schema.columns WHERE table_schema='${MYSQL_DATABASE}':SELECT COUNT(*) FROM information_schema.columns WHERE table_schema='public'"
        "Index Count:SELECT COUNT(DISTINCT CONCAT(TABLE_NAME, '.', INDEX_NAME)) FROM INFORMATION_SCHEMA.STATISTICS WHERE TABLE_SCHEMA = '${MYSQL_DATABASE}':SELECT COUNT(*) FROM pg_indexes WHERE schemaname='public'"
        "Foreign Key Count:SELECT COUNT(*) FROM information_schema.key_column_usage WHERE referenced_table_schema='${MYSQL_DATABASE}':SELECT COUNT(*) FROM information_schema.table_constraints WHERE constraint_type='FOREIGN KEY' AND table_schema='public'"
        "Primary Key Count:SELECT COUNT(*) FROM information_schema.table_constraints WHERE constraint_type='PRIMARY KEY' AND table_schema='${MYSQL_DATABASE}':SELECT COUNT(*) FROM information_schema.table_constraints WHERE constraint_type='PRIMARY KEY' AND table_schema='public'"
    )

    for metric in "${metrics[@]}"; do
        IFS=':' read -r name mysql_query pg_query <<< "$metric"
        mysql_value=$(get_mysql_info "$mysql_query")
        pg_value=$(get_pg_info "$pg_query")
        match=$([ "$mysql_value" = "$pg_value" ] && echo "Yes" || echo "No")
        printf "%-20s | %-10s | %-10s | %-5s\n" "$name" "$mysql_value" "$pg_value" "$match"
    done
}

compare_record_counts() {
    echo -e "\n테이블별 레코드 수 비교:"
    printf "%-35s | %10s | %10s | %-5s\n" "Table Name" "MySQL" "PostgreSQL" "Match"
    printf "%s\n" "-------------------------------------------------------------------------"

    TABLES=$(get_mysql_info "SHOW TABLES;")
    for table in $TABLES; do
        mysql_count=$(get_mysql_info "SELECT COUNT(*) FROM \`$table\`;" 2>/dev/null || echo "N/A")
        pg_count=$(get_pg_info "SELECT COUNT(*) FROM public.\"$table\";" 2>/dev/null || echo "N/A")
        match=$([ "$mysql_count" = "$pg_count" ] && echo "Yes" || echo "No")
        printf "%-35s | %10s | %10s | %-5s\n" "$table" "$mysql_count" "$pg_count" "$match"
    done
}

compare_indexes() {
    echo -e "\n인덱스 비교:"
    printf "%-35s | %-35s | %-7s\n" "MySQL Index" "PostgreSQL Index" "Match"
    printf "%s\n" "---------------------------------------------------------------------------------"

    mysql_indexes=$(get_mysql_info "
        SELECT CONCAT(TABLE_NAME, '.', INDEX_NAME) 
        FROM INFORMATION_SCHEMA.STATISTICS 
        WHERE TABLE_SCHEMA = '${MYSQL_DATABASE}' 
        GROUP BY TABLE_NAME, INDEX_NAME 
        ORDER BY TABLE_NAME, INDEX_NAME;
    ")

    pg_indexes=$(get_pg_info "
        SELECT CONCAT(tablename, '.', indexname) 
        FROM pg_indexes 
        WHERE schemaname = 'public' 
        ORDER BY tablename, indexname;
    ")

    while IFS= read -r mysql_index; do
        table_name=${mysql_index%.*}
        index_name=${mysql_index#*.}
        
        pg_index=$(echo "$pg_indexes" | grep -i "^${table_name}\." | grep -i "${index_name:0:30}")
        
        if [ -n "$pg_index" ]; then
            match="Yes"
        else
            pg_index=$(echo "$pg_indexes" | grep -i "^${table_name}\." | grep -i "${index_name:0:20}")
            match=$([ -n "$pg_index" ] && echo "Yes*" || echo "No")
            pg_index=${pg_index:-"N/A"}
        fi
        printf "%-35s | %-35s | %-7s\n" "${mysql_index:0:35}" "${pg_index:0:35}" "$match"
    done <<< "$mysql_indexes"
}


verify_migration() {
    local db_name=$1
    echo "마이그레이션 결과를 검증합니다..."
    MYSQL_DATABASE="${db_name}"
    compare_structure
    compare_record_counts
    compare_indexes
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

    echo "Processing database: $db_name"
    if migrate_database "${db_name}"; then
        verify_migration "${db_name}"
        echo "Migration completed for $db_name."

        
        # verify.sh 호출 시 db_name과 함께 DOCKER_COMPOSE_CMD를 인자로 전달
        # ./scripts/verify.sh "${db_name}" "${POSTGRES_HOST}" "${POSTGRES_PORT}" "${POSTGRES_USER}" "${POSTGRES_PASSWORD}" "${POSTGRES_DB}" "${DOCKER_COMPOSE_CMD}"

        if [ $? -eq 0 ]; then
            echo "Verification completed successfully."
        else
            echo "Verification failed. Please check the results."
        fi
    else
        echo "Migration failed for $db_name."
        exit 1
    fi
}

main "$@"