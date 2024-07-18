#!/bin/bash

# 환경 변수 로드
source .env

# MySQL 컨테이너 재시작
echo "MySQL 컨테이너를 재시작합니다..."
docker-compose down
docker-compose up -d mysql

echo "MySQL이 시작될 때까지 대기 중..."
until docker-compose exec -T mysql mysqladmin ping -h localhost --silent; do
    sleep 1
done
echo "MySQL이 준비되었습니다."

# MySQL root 사용자 재생성
echo "MySQL root 사용자를 재생성합니다..."
docker-compose exec -T mysql mysql -u root -p"${MYSQL_ROOT_PASSWORD}" <<EOF
DROP USER IF EXISTS 'root'@'%';
CREATE USER 'root'@'%' IDENTIFIED WITH mysql_native_password BY '${MYSQL_ROOT_PASSWORD}';
GRANT ALL PRIVILEGES ON *.* TO 'root'@'%' WITH GRANT OPTION;
FLUSH PRIVILEGES;
EOF

# local mysql에 user 테이블 존재 여부 확인 및 dumps/user_dumps.sql 임포트
echo "user 테이블 존재 여부를 확인합니다..."
TABLE_EXISTS=$(docker-compose exec -T mysql mysql -u root -p"${MYSQL_ROOT_PASSWORD}" -D "${MYSQL_DATABASE}" -se "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${MYSQL_DATABASE}' AND table_name='user';")

if [ "$TABLE_EXISTS" -eq 0 ]; then
    echo "user 테이블이 존재하지 않습니다. dumps/user_dumps.sql을 임포트합니다..."
    docker-compose exec -T mysql mysql -u root -p"${MYSQL_ROOT_PASSWORD}" "${MYSQL_DATABASE}" < dumps/user_dumps.sql
    echo "dumps/user_dumps.sql 임포트가 완료되었습니다."
else
    echo "user 테이블이 이미 존재합니다. dumps/user_dumps.sql 임포트를 건너뜁니다."
fi

# PostgreSQL 컨테이너 시작
echo "PostgreSQL 컨테이너를 시작합니다..."
docker-compose up -d postgres

echo "PostgreSQL이 시작될 때까지 대기 중..."
until docker-compose exec -T postgres pg_isready -h localhost -U ${POSTGRES_USER} --quiet; do
    sleep 1
done
echo "PostgreSQL이 준비되었습니다."

# pgloader 설정 파일 생성
echo "pgloader 설정 파일을 생성합니다..."
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
   \$\$ create schema if not exists public; \$\$,
   \$\$ CREATE EXTENSION IF NOT EXISTS pgcrypto; \$\$
;
EOF

# pgloader를 사용하여 MySQL에서 PostgreSQL로 데이터 마이그레이션
echo "MySQL에서 PostgreSQL로 데이터 마이그레이션 중..."
docker-compose run --rm pgloader pgloader --verbose /pgloader_config/pgloader.load

# 마이그레이션 결과 확인
echo "PostgreSQL 테이블 목록 확인 중..."
docker-compose exec postgres psql -U ${POSTGRES_USER} -d ${POSTGRES_DB} -c "\dt"

echo "마이그레이션이 완료되었습니다."

# 검증 스크립트 실행
./verify.sh