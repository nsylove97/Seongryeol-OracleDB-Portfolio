# 🚀 Oracle DBA Portfolio & Practicum

오라클 데이터베이스 관리자(DBA)로서의 역량을 증명하기 위한 실무 중심의 인프라 구축, 운영 및 트러블슈팅 포트폴리오입니다.
GUI 툴에 의존하지 않고 리눅스 환경에서 CLI 기반으로 아키텍처를 구성하며, 단일 인스턴스부터 고가용성(HA) 클러스터 환경까지 단계별로 실습한 스크립트와 가이드를 기록했습니다.

<br/>

## 🛠️ Tech Stack
- **RDBMS:** Oracle Database 11g / 19c
- **OS:** Linux (CentOS / Oracle Enterprise Linux)
- **Languages:** SQL, PL/SQL, Shell Script
- **Tools:** SQL*Plus, RMAN, Data Pump, AWR, OEM

<br/>

## 📂 Repository Structure (학습 및 실습 주제)

이 레포지토리는 오라클 데이터베이스의 핵심 관리 영역을 7개의 파트로 나누어 구성했습니다.
각 폴더를 클릭하면 상세 스크립트 및 트러블슈팅 과정을 확인할 수 있습니다.

###(./01_Admin)
- DB 수동 생성 (PFILE 작성 및 `CREATE DATABASE` 스크립트)
- 다중 리스너(Listener) 및 로컬 네이밍(TNS) 네트워크 구성
- 테이블스페이스 및 Undo / Redo Log 다중화(Multiplexing) 스토리지 관리

###(./02_PLSQL)
- Procedure, Function, Package 작성 및 예외 처리(Exception Handling)
- Cursor를 활용한 대용량 데이터 처리 및 Trigger를 이용한 자동화 작업

###(./03_Backup_Recovery)
- RMAN(Recovery Manager)을 활용한 전체/증분 백업 및 복구(PITR) 구성
- User-Managed Backup (Cold/Hot Backup) 스크립트 작성
- Flashback Technology를 활용한 논리적 장애 복구

###(./04_SQL_Tuning)
- 옵티마이저(CBO/RBO) 이해 및 실행 계획(Execution Plan) 분석
- Index 전략 수립 및 Hint를 활용한 최적의 액세스 경로 유도
- AWR 리포트 추출 및 대기 이벤트(Wait Event) 분석

###(./05_Security)
- 유저 권한(Privilege) 및 Role 관리, Profile을 통한 리소스 제어
- 표준 감사(Standard Auditing) 및 FGA(Fine-Grained Auditing) 구축
- TDE(Transparent Data Encryption)를 활용한 데이터 암호화

###(./06_Data_Guard)
- Primary - Standby DB 간의 Data Guard 환경 구축 (물리적/논리적)
- Active Data Guard 구성 및 Switchover / Failover 전환 테스트
- Redo 전송 방식(SYNC/ASYNC) 및 보호 모드(Maximum Protection 등) 설정

###(./07_RAC)
- Grid Infrastructure 및 ASM(Automatic Storage Management) 환경 구축
- Oracle RAC(Real Application Clusters) 2-Node 설치 및 인스턴스 구성
- Cache Fusion의 이해 및 노드 장애 시 Failover(TAF/FAN) 테스트

<br/>

## 💡 Highlight & Competencies
- **CLI 지향:** DBCA, NETCA 등 GUI 툴을 배제하고 OS 명령어나 SQL 쿼리로 직접 아키텍처를 통제할 수 있습니다.
- **Troubleshooting:** 각 실습 과정에서 발생한 ORA- 에러나 Lock, Deadlock 상황의 원인을 파악하고 해결한 과정을 블로그에 기록했습니다.
- **고가용성(HA) 이해:** 단일 DB 관리를 넘어, 실제 엔터프라이즈 환경에서 필수적인 RAC와 Data Guard 아키텍처를 직접 구축해 보았습니다.

<br/>

## 🔗 Links
- 📝 **기술 블로그 (트러블슈팅 상세 과정):** https://nsylove97.tistory.com/
- 💼 **LinkedIn:**
- 📧 **Email:** nsylove97@gmail.com