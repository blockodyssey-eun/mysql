#!/bin/bash

load_env() {
    source .env
}

docker_down_and_up() {
    docker-compose down
    docker-compose up -d
}

restart_mysql() {
    echo "Restarting MySQL container..."
    docker-compose restart mysql
}

wait_for_mysql() {
    echo "MySQL: 실행 대기..."
    local max_attempts=30
    local attempt=0
    
    while [ $attempt -lt $max_attempts ]; do
        if docker-compose exec -T mysql mysqladmin ping -h localhost --silent &> /dev/null; then
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

recreate_mysql_root_user() {
    echo "MySQL: Root계정 재생성..."
    docker-compose exec -T mysql mysql -u root -p"${MYSQL_ROOT_PASSWORD}" <<EOF
DROP USER IF EXISTS 'root'@'%';
CREATE USER 'root'@'%' IDENTIFIED WITH mysql_native_password BY '${MYSQL_ROOT_PASSWORD}';
GRANT ALL PRIVILEGES ON *.* TO 'root'@'%' WITH GRANT OPTION;
FLUSH PRIVILEGES;
EOF
}

import_user_table() {
    echo "MySQL: User 테이블 Import여부 체크..."
    TABLE_EXISTS=$(docker-compose exec -T mysql mysql -u root -p"${MYSQL_ROOT_PASSWORD}" -D "${MYSQL_DATABASE}" -se "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${MYSQL_DATABASE}' AND table_name='user';")

    if [ "$TABLE_EXISTS" -eq 0 ]; then
        echo "user 테이블이 존재하지 않습니다. dumps/user_dumps.sql을 임포트합니다..."
        docker-compose exec -T mysql mysql -u root -p"${MYSQL_ROOT_PASSWORD}" "${MYSQL_DATABASE}" < dumps/user_dumps.sql
        echo "dumps/user_dumps.sql 임포트가 완료되었습니다."
    else
        echo "user 테이블이 이미 존재합니다. dumps/user_dumps.sql 임포트를 건너뜁니다."
    fi
}

restart_postgres() {
    echo "Postgresql: 재실행..."
    docker-compose restart postgres
}

wait_for_postgres() {
    echo "Postgresql: 실행 대기..."
    until docker-compose exec -T postgres pg_isready -h localhost -U ${POSTGRES_USER} --quiet; do
        sleep 1
    done
    echo "Postgresql: 실행."
}

create_pgloader_config() {
    echo "PGLoader 설정 파일 생성..."
    cat > pgloader.load <<EOF
LOAD DATABASE
    FROM mysql://root:${MYSQL_ROOT_PASSWORD}@mysql:3306/${MYSQL_DATABASE}
    INTO postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@postgres:5432/${POSTGRES_DB}

WITH include drop, create tables, drop indexes, create indexes, foreign keys, uniquify index names, quote identifiers

SET maintenance_work_mem to '128MB', work_mem to '12MB'

CAST type datetime to timestamp using zero-dates-to-null,
     type date to date using zero-dates-to-null,
     type int with extra auto_increment to serial,
     type bigint with extra auto_increment to bigserial

ALTER SCHEMA '${MYSQL_DATABASE}' RENAME TO 'public'

BEFORE LOAD DO
   \$\$ CREATE SCHEMA IF NOT EXISTS public; \$\$,
   \$\$ CREATE EXTENSION IF NOT EXISTS pgcrypto; \$\$
;
EOF
}

migrate_data() {
    echo "MySQL -> Postgresql 마이그레이팅..."
    docker-compose run --rm pgloader pgloader --verbose /pgloader_config/pgloader.load
}

verify_migration() {
    echo "Postgresql: 마이그레이션 검증..."
    docker-compose exec postgres psql -U ${POSTGRES_USER} -d ${POSTGRES_DB} -c "\dt"
    echo "Migration completed."
}

run_verification_script() {
    ./verify.sh
}

main() {
    load_env
    docker_down_and_up
    wait_for_mysql
    wait_for_postgres

    
    recreate_mysql_root_user
    import_user_table

    # 유저 임포트 후 mysql restart 
    restart_mysql
    wait_for_mysql

    create_pgloader_config
    migrate_data
    verify_migration
    run_verification_script
}

main