#!/bin/bash

set -e

# dumps 디렉토리에서 SQL 파일들을 찾아 데이터베이스 생성 및 덤프 임포트
for dump_file in /docker-entrypoint-initdb.d/dumps/*_dumps.sql; do
    if [ -f "$dump_file" ]; then
        db_name=$(basename "$dump_file" _dumps.sql)
        
        # 데이터베이스 존재 여부 확인
        db_exists=$(mysql -u root -p"$MYSQL_ROOT_PASSWORD" -se "SELECT COUNT(*) FROM information_schema.schemata WHERE schema_name = '$db_name';")
        
        if [ "$db_exists" -eq 0 ]; then
            echo "Creating database and importing dump: $db_name"
            mysql -u root -p"$MYSQL_ROOT_PASSWORD" <<-EOSQL
                CREATE DATABASE $db_name;
                USE $db_name;
EOSQL
            mysql -u root -p"$MYSQL_ROOT_PASSWORD" $db_name < "$dump_file"
            echo "Import completed for $db_name"
        else
            echo "Database $db_name already exists. Skipping creation and import."
        fi
    fi
done