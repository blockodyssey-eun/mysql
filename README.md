# MySQL에서 PostgreSQL로의 데이터 마이그레이션

## 환경 설정

1. `.env` 파일 생성:
   ```
   $ cp env.example .env
   ```

2. `.env` 파일 내용 설정:
   ```
   # MySQL 설정 (dump파일을 임시로 로컬에 구현하기위함)
   MYSQL_ROOT_PASSWORD=qwer1234
   MYSQL_DATABASE=user
   MYSQL_PORT=3333

   # PostgreSQL 설정
   POSTGRES_DB=
   POSTGRES_USER=
   POSTGRES_PASSWORD=
   POSTGRES_HOST=
   POSTGRES_PORT=

   # 공통 데이터 폴더
   DATA_PATH_HOST=./data
   ```

## 로컬 테스트 가이드

### 1. Docker를 사용한 PostgreSQL (기본 설정)

1. `docker-compose.yml` 파일에서 PostgreSQL 주석 해제:
  
   ```yaml
   postgres:
     image: postgres:16
     environment:
       POSTGRES_DB: ${POSTGRES_DB}
       POSTGRES_USER: ${POSTGRES_USER}
       POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
     ports:
       - "${POSTGRES_PORT}:5432"
     volumes:
       - ${DATA_PATH_HOST}/postgres:/var/lib/postgresql/data
     networks:
       - migration_network
   ```

2. Docker 컨테이너 실행:
   ```
   $ docker-compose up -d
   ```

## 마이그레이션 실행

#### 사전 준비

1. MySQL 덤프 파일 준비(dumps/[파일명]_dump.sql):

   *로컬 mysqldump 또는 tool 이용하기

   ```bash
   $ mysqldump -u root -p --databases user > user_dump.sql 



#### 실행

1. 마이그레이션 스크립트 실행 권한 부여:
   ```
   $ chmod +x migrate.sh
   $ chmod +x verify.sh
   ```

2. 마이그레이션 실행:
   ```
   $ ./migrate.sh
   ```

   