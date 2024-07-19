# MySQL에서 PostgreSQL로의 데이터 마이그레이션 가이드

Docker와 pgloader를 사용하여 MySQL에서 PostgreSQL로 데이터를 마이그레이션하는 스크립트

## 사전 요구사항

- postgresql
- Python 3.x
- Docker, Docker Compose

## postgresql

```
$ brew install postgresql
```


## 설치

1. 의존성 설치: `requirements.txt` 패키지 설치
```bash
$ pip install -r requirements.txt
```

## 사용 방법

1. 실행
```bash
$ python app.py
```

2. localhost:5000 접속

3. postgresql 설정 입력

4. 연결 후 dump파일 업로드 (***dump의 파일명 형식은 [데이터베이스명]_dumps.sql***)

5. migrate 진행



## 로컬 Postgres 띄우기

```sh
$ chmod +x ./docker/postgres/start.sh
$ ./docker/postgres/start.sh
Enter database name: custody
Enter database user: user
Enter database password: 
Starting PostgreSQL Docker container...
cd85d9fe596dfc46d01af60e58a4c4eb501a6432bfe2a97c074b608ddebe1b5a
PostgreSQL container is starting. You can connect to it using:
Host: localhost
Port: 5432
Database: custody
User: user
Password: [The password you entered]
```


## Trubleshooting

1. MySQL 접근 거부 오류

**메시지**:
```
ERROR 1045 (28000): Access denied for user 'root'@'localhost' (using password: YES)
data: Migration failed for user
```


**해결방안**
```
Migrate 버튼 재 클릭
```
