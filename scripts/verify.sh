#!/bin/bash

source .env

get_mysql_info() {
    docker-compose exec -T mysql mysql -u root -p"${MYSQL_ROOT_PASSWORD}" -D "${MYSQL_DATABASE}" -se "$1" 2>/dev/null
}

get_pg_info() {
    docker-compose exec -T postgres psql -U ${POSTGRES_USER} -d ${POSTGRES_DB} -t -c "$1" | tr -d ' '
}


compare_structure() {
    echo "구조 비교:"
    echo "---------------------------------------------------"
    printf "| %-20s | %-10s | %-10s | %-5s |\n" "Metric" "MySQL" "PostgreSQL" "Match"
    echo "---------------------------------------------------"

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
        printf "| %-20s | %-10s | %-10s | %-5s |\n" "$name" "$mysql_value" "$pg_value" "$match"
    done

    echo "---------------------------------------------------"
}

compare_record_counts() {
    echo -e "\n테이블별 레코드 수 비교:"
    echo "---------------------------------------------------------------"
    printf "| %-28s | %10s | %10s | %-5s |\n" "Table Name" "MySQL" "PostgreSQL" "Match"
    echo "---------------------------------------------------------------"

    TABLES=$(get_mysql_info "SHOW TABLES;")

    for table in $TABLES; do
        mysql_count=$(get_mysql_info "SELECT COUNT(*) FROM $table;")
        pg_count=$(get_pg_info "SELECT COUNT(*) FROM public.$table;")
        match=$([ "$mysql_count" = "$pg_count" ] && echo "Yes" || echo "No")
        printf "| %-28s | %10s | %10s | %-5s |\n" "$table" "$mysql_count" "$pg_count" "$match"
    done

    echo "---------------------------------------------------------------"
}

compare_indexes() {
    echo -e "\n인덱스 비교:"
    echo "---------------------------------------------------------------------------------"
    printf "| %-35s | %-35s | %-7s |\n" "MySQL Index" "PostgreSQL Index" "Match"
    echo "---------------------------------------------------------------------------------"

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
        printf "| %-35s | %-35s | %-7s |\n" "${mysql_index:0:35}" "${pg_index:0:35}" "$match"
    done <<< "$mysql_indexes"

    echo "---------------------------------------------------------------------------------"
}

main() {
    echo "마이그레이션 결과를 검증합니다..."
    compare_structure
    compare_record_counts
    compare_indexes
}

main