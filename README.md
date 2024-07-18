# MySQL에서 PostgreSQL로의 데이터 마이그레이션 가이드

Docker와 pgloader를 사용하여 MySQL에서 PostgreSQL로 데이터를 마이그레이션하는 스크립트

## 사전 요구사항

- Docker와 Docker Compose 설치
- Docker Compose v2

## 설정

1. 이 저장소를 로컬 머신에 클론합니다.

2. 프로젝트 루트에 다음 내용으로 `.env` 파일을 생성합니다:

```
// MySQL 설정
MYSQL_ROOT_PASSWORD=qwer1234
MYSQL_PORT=3333

// PostgreSQL 설정
POSTGRES_HOST=postgres
POSTGRES_PORT=5432
POSTGRES_USER=custody
POSTGRES_PASSWORD=qwer1234

// 공통 설정
DATA_PATH_HOST=./data
```

**`POSTGRES_HOST=postgres`는 로컬 Docker 설정용(강제)입니다. 원격 PostgreSQL의 경우 실제 호스트 주소를 입력하세요.**

3. MySQL 덤프 파일을 `dumps` 디렉토리에 넣습니다. 파일 이름은 `[데이터베이스명]_dumps.sql` 형식이어야 합니다. 
   
   **[데이터베이스명]_dumps.sql에서 [데이터베이스명]은 postgres의 데이터베이스 이름이 됩니다.**

## 사용 방법

1. 스크립트에 실행 권한을 부여합니다:
```
chmod +x migrate.sh
```

2. 마이그레이션 스크립트를 실행합니다:
```
./migrate.sh
```

## 스크립트 동작 방식

1. `.env`에서 환경 변수를 로드합니다.
2. 실행 중인 Docker 컨테이너를 중지하고 다시 시작합니다.
3. MySQL과 PostgreSQL 서비스가 준비될 때까지 기다립니다.
4. MySQL root 사용자를 재생성합니다.
5. `dumps` 디렉토리의 각 덤프 파일에 대해:
- PostgreSQL에 해당 데이터베이스가 없으면 생성합니다.
- pgloader 설정 파일을 생성합니다.
- pgloader를 실행하여 MySQL에서 PostgreSQL로 데이터를 마이그레이션합니다.
- PostgreSQL 데이터베이스의 테이블을 나열하여 마이그레이션을 확인합니다.
