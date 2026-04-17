/*
================================================================================
 Data Guard 03: Physical Standby 구축 — RMAN DUPLICATE & Redo Apply 확인
================================================================================
 블로그: https://nsylove97.tistory.com/48
 GitHub: https://github.com/nsylove97/NSY-DB-Portfolio

 실습 환경
   - OS            : Oracle Linux 7.9 (VMware Virtual Machine)
   - DB            : Oracle Database 19c (Grid Infrastructure + DB)
   - Tool          : SQL*Plus, MobaXterm(SSH)
   - Grid HOME     : /u01/app/19.3.0/gridhome
   - DB HOME       : /u01/app/oracle/product/19.3.0/dbhome
   - Primary (VM1) : IP 192.168.111.50 / hostname oelsvr1     / db_unique_name orcl
   - Standby (VM3) : IP 192.168.111.60 / hostname oel-standby / db_unique_name orclstby

 목차
   1. Primary 사전 준비
      1-1. FORCE LOGGING 활성화
      1-2. Standby Redo Log(SRL) 생성
   2. Primary spfile DG 파라미터 설정
      2-1. db_unique_name 확인
      2-2. LOG_ARCHIVE_CONFIG / LOG_ARCHIVE_DEST_n 설정
      2-3. FAL_SERVER / FAL_CLIENT / STANDBY_FILE_MANAGEMENT 설정
      2-4. 설정 확인
   3. RMAN DUPLICATE — Primary → Standby 실시간 복제
      3-1. Standby NOMOUNT 상태 확인
      3-2. tnsnames.ora — ORCLSTBY_STATIC 항목 추가
      3-3. RMAN DUPLICATE 실행
      3-4. 복제 결과 확인
   4. Redo Apply 시작 및 확인
      4-1. MRP 기동
      4-2. MRP 프로세스 확인
      4-3. 동기화 상태 확인
   5. 동기화 검증 — Primary INSERT → Standby 반영 확인
      5-1. Primary 테스트 테이블 생성 및 데이터 입력
      5-2. Standby에서 반영 확인
      5-3. Redo Apply 재기동
   6. 관련 뷰 정리
      6-1. v$database
      6-2. v$managed_standby
      6-3. v$dataguard_stats
      6-4. v$archive_dest
      6-5. v$standby_log
================================================================================
*/


/* ============================================================================
   1. Primary 사전 준비
   ============================================================================ */

/* --------------------------------------------------------------------------
   1-1. FORCE LOGGING 활성화
   --------------------------------------------------------------------------
   ※ Data Guard는 Redo 기반으로 동기화
   ※ NOLOGGING 데이터는 Redo가 없어 Standby가 따라갈 수 없음
   ※ FORCE LOGGING: NOLOGGING 무시하고 모든 변경을 반드시 Redo로 기록
   -------------------------------------------------------------------------- */

-- [VM1 — oracle 계정, SYSDBA 접속]
CONN / AS SYSDBA

-- 현재 상태 확인
SELECT force_logging FROM v$database;

/*
 [결과]
   FORCE_LOGGING
   -------------
   NO
   → 활성화 필요
*/

-- FORCE LOGGING 활성화
ALTER DATABASE FORCE LOGGING;

/*
 [결과]
   Database altered.
*/

-- 활성화 확인
SELECT force_logging FROM v$database;

/*
 [결과]
   FORCE_LOGGING
   -------------
   YES
   → FORCE LOGGING 활성화 확인
*/


/* --------------------------------------------------------------------------
   1-2. Standby Redo Log(SRL) 생성
   --------------------------------------------------------------------------
   ※ SRL: Standby가 Primary로부터 전송받은 Redo를 임시로 기록하는 로그 파일
   ※ SRL이 있어야 Real-Time Apply 가능, 동기화 지연 최소화

   SRL 구성 기준
     그룹 수  : Online Redo Log 그룹 수 + 1 = 3 + 1 = 4개
     크기     : Online Redo Log와 동일 = 200MB
     저장위치 : +REDO (Online Redo Log와 I/O 분리)
   -------------------------------------------------------------------------- */

-- 현재 Online Redo Log 구성 확인
SELECT group#, members, bytes/1024/1024 AS mb
FROM   v$log
ORDER  BY group#;

/*
 [결과]
   GROUP#  MEMBERS  MB
   ------  -------  ---
        1        2  200
        2        2  200
        3        2  200
   → 그룹 3개, 멤버 2개(다중화), 200MB
*/

-- SRL 4개 생성 (그룹 번호는 기존 Online Redo Log와 겹치지 않게)
ALTER DATABASE ADD STANDBY LOGFILE THREAD 1
    GROUP 4 '+REDO' SIZE 200M;

ALTER DATABASE ADD STANDBY LOGFILE THREAD 1
    GROUP 5 '+REDO' SIZE 200M;

ALTER DATABASE ADD STANDBY LOGFILE THREAD 1
    GROUP 6 '+REDO' SIZE 200M;

ALTER DATABASE ADD STANDBY LOGFILE THREAD 1
    GROUP 7 '+REDO' SIZE 200M;

/*
 [결과]
   Database altered. (4회)
*/

-- SRL 생성 확인
SELECT group#, thread#, sequence#, bytes/1024/1024 AS mb, status
FROM   v$standby_log
ORDER  BY group#;

/*
 [결과]
   GROUP#  THREAD#  SEQUENCE#  MB   STATUS
   ------  -------  ---------  ---  ----------
        4        1          0  200  UNASSIGNED
        5        1          0  200  UNASSIGNED
        6        1          0  200  UNASSIGNED
        7        1          0  200  UNASSIGNED
   → 4개 SRL 생성 확인, UNASSIGNED는 아직 미사용 상태로 정상
*/


/* ============================================================================
   2. Primary spfile DG 파라미터 설정
   ============================================================================
   - Primary spfile에 Data Guard 동작에 필요한 파라미터 추가
   - Standby 쪽에서 받고 Primary 쪽에서 보내는 역할을 모두 고려해서 설정
   ============================================================================ */

/* --------------------------------------------------------------------------
   2-1. db_unique_name 확인
   -------------------------------------------------------------------------- */

CONN / AS SYSDBA

SHOW PARAMETER db_unique_name

/*
 [결과]
   NAME            TYPE    VALUE
   --------------- ------- -----
   db_unique_name  string  orcl
*/


/* --------------------------------------------------------------------------
   2-2. LOG_ARCHIVE_CONFIG / LOG_ARCHIVE_DEST_n 설정
   -------------------------------------------------------------------------- */

-- LOG_ARCHIVE_CONFIG — DG 구성원 명단 등록
-- 여기에 등록된 db_unique_name만 Redo를 주고받을 수 있음
ALTER SYSTEM SET LOG_ARCHIVE_CONFIG='DG_CONFIG=(orcl,orclstby)' SCOPE=BOTH;

-- LOG_ARCHIVE_DEST_1 — 로컬 아카이브 목적지
ALTER SYSTEM SET LOG_ARCHIVE_DEST_1=
    'LOCATION=USE_DB_RECOVERY_FILE_DEST
     VALID_FOR=(ALL_LOGFILES,ALL_ROLES)
     DB_UNIQUE_NAME=orcl'
SCOPE=BOTH;

-- LOG_ARCHIVE_DEST_2 — Standby로 Redo 전송
-- ASYNC: 비동기 전송 (Maximum Performance 모드)
-- VALID_FOR=(ONLINE_LOGFILES,PRIMARY_ROLE): Primary일 때 Online Redo만 전송
ALTER SYSTEM SET LOG_ARCHIVE_DEST_2=
    'SERVICE=orclstby ASYNC
     VALID_FOR=(ONLINE_LOGFILES,PRIMARY_ROLE)
     DB_UNIQUE_NAME=orclstby'
SCOPE=BOTH;

-- LOG_ARCHIVE_DEST_STATE_1, 2 — 목적지 활성화
ALTER SYSTEM SET LOG_ARCHIVE_DEST_STATE_1=ENABLE SCOPE=BOTH;
ALTER SYSTEM SET LOG_ARCHIVE_DEST_STATE_2=ENABLE SCOPE=BOTH;

/*
 [결과]
   System altered. (각 명령마다)
*/


/* --------------------------------------------------------------------------
   2-3. FAL_SERVER / FAL_CLIENT / STANDBY_FILE_MANAGEMENT 설정
   -------------------------------------------------------------------------- */

-- FAL_SERVER — Gap 발생 시 Redo를 재요청할 서버
-- Primary 입장에서는 Standby가 FAL_SERVER
ALTER SYSTEM SET FAL_SERVER=orclstby SCOPE=BOTH;

-- FAL_CLIENT — FAL 요청 시 자신을 식별하는 이름
ALTER SYSTEM SET FAL_CLIENT=orcl SCOPE=BOTH;

-- STANDBY_FILE_MANAGEMENT — Primary 파일 변경 시 Standby 자동 반영
ALTER SYSTEM SET STANDBY_FILE_MANAGEMENT=AUTO SCOPE=BOTH;

/*
 [결과]
   System altered. (각 명령마다)
*/


/* --------------------------------------------------------------------------
   2-4. 설정 확인
   -------------------------------------------------------------------------- */

SELECT name, value
FROM   v$parameter
WHERE  name IN (
    'log_archive_config',
    'log_archive_dest_1',
    'log_archive_dest_2',
    'log_archive_dest_state_1',
    'log_archive_dest_state_2',
    'fal_server',
    'fal_client',
    'standby_file_management'
)
ORDER  BY name;

/*
 [결과]
   NAME                       VALUE
   -------------------------- --------------------------------------------------
   fal_client                 orcl
   fal_server                 orclstby
   log_archive_config         DG_CONFIG=(orcl,orclstby)
   log_archive_dest_1         LOCATION=USE_DB_RECOVERY_FILE_DEST VALID_FOR=...
   log_archive_dest_2         SERVICE=orclstby ASYNC VALID_FOR=...
   log_archive_dest_state_1   ENABLE
   log_archive_dest_state_2   ENABLE
   standby_file_management    AUTO
   → 파라미터 설정 확인
*/


/* ============================================================================
   3. RMAN DUPLICATE — Primary → Standby 실시간 복제
   ============================================================================
   - RMAN DUPLICATE FROM ACTIVE DATABASE:
     Primary DB를 백업 없이 네트워크를 통해 Standby로 직접 복제
   - 복제 전 VM3가 NOMOUNT 상태인지 반드시 확인
   ============================================================================ */

/* --------------------------------------------------------------------------
   3-1. Standby NOMOUNT 상태 확인
   -------------------------------------------------------------------------- */

-- [VM3 — oracle 계정, SYSDBA 접속]
CONN / AS SYSDBA

SELECT status FROM v$instance;

/*
 [결과]
   STATUS
   -------
   STARTED
   → STARTED = NOMOUNT 상태 확인
*/

-- [VM1 — oracle 계정] VM3 리스너 접속 테스트
-- tnsping orclstby

/*
 [결과]
   OK (xx msec)
   → Standby 리스너 응답 확인
*/


/* --------------------------------------------------------------------------
   3-2. tnsnames.ora — ORCLSTBY_STATIC 항목 추가
   --------------------------------------------------------------------------
   ※ NOMOUNT 상태에서는 동적 등록 서비스(orclstby)로 접속 불가 (ORA-12528)
   ※ Static Entry 서비스로 접속해야 함
   ※ UR=A (Unrestricted): RESTRICTED/NOMOUNT 상태에서도 접속 허용
   -------------------------------------------------------------------------- */

-- [VM1 — oracle 계정]
-- vi $ORACLE_HOME/network/admin/tnsnames.ora

/*
 [추가할 항목]

   ORCLSTBY_STATIC =
     (DESCRIPTION =
       (ADDRESS = (PROTOCOL = TCP)(HOST = oel-standby.localdomain)(PORT = 1521))
       (CONNECT_DATA =
         (SERVER = DEDICATED)
         (SERVICE_NAME = orclstby_DGMGRL.localdomain)
         (UR = A)
       )
     )

 ※ SERVICE_NAME은 listener.ora의 GLOBAL_DBNAME과 동일하게 설정
*/

-- tnsping으로 접속 확인
-- tnsping orclstby_static

/*
 [결과]
   OK (xx msec)
   → Static Entry 서비스 응답 확인
*/


/* --------------------------------------------------------------------------
   3-3. RMAN DUPLICATE 실행
   --------------------------------------------------------------------------
   ※ RMAN은 VM1(Primary)에서 실행
   ※ TARGET: Primary / AUXILIARY: Standby
   -------------------------------------------------------------------------- */

-- [VM1 — oracle 계정, OS 터미널에서 실행]
-- rman target sys/비밀번호@orcl auxiliary sys/비밀번호@orclstby_static

-- RMAN 프롬프트에서 실행
/*
   RMAN> DUPLICATE TARGET DATABASE
             FOR STANDBY
             FROM ACTIVE DATABASE
             DORECOVER
             NOFILENAMECHECK;

   옵션 설명
     FOR STANDBY        : Physical Standby로 복제
     FROM ACTIVE DATABASE: 백업 없이 Primary에서 직접 복제 (네트워크 전송)
     DORECOVER          : 복제 후 Redo Apply까지 자동 수행해서 최신 상태로 맞춤
     NOFILENAMECHECK    : Primary와 파일 경로가 동일해도 오류 없이 진행 (ASM 환경에서 필요)
*/

/*
 [결과]
   Starting Duplicate Db at ...
   using target database control file instead of recovery catalog
   allocated channel: ORA_AUX_DISK_1
   ...
   channel ORA_AUX_DISK_1: starting datafile copy
   input datafile file number=00001 name=+DATA/ORCL/DATAFILE/system.xxx
   input datafile file number=00002 name=+DATA/ORCL/DATAFILE/sysaux.xxx
   input datafile file number=00003 name=+DATA/ORCL/DATAFILE/undotbs1.xxx
   input datafile file number=00004 name=+DATA/ORCL/DATAFILE/users.xxx
   ...
   Finished Duplicate Db at ...
   → 복제 완료
*/


/* --------------------------------------------------------------------------
   3-4. 복제 결과 확인
   -------------------------------------------------------------------------- */

-- [VM3 — oracle 계정, SYSDBA 접속]
CONN / AS SYSDBA

-- DB 역할 및 상태 확인
SELECT name, db_unique_name, database_role, open_mode
FROM   v$database;

/*
 [결과]
   NAME  DB_UNIQUE_NAME  DATABASE_ROLE    OPEN_MODE
   ----  --------------  ---------------  --------------------
   ORCL  orclstby        PHYSICAL STANDBY MOUNTED
   → PHYSICAL STANDBY 역할, MOUNTED 상태 확인
*/

-- 데이터파일 경로 확인 — ASM 경로에 orclstby가 포함되어 있는지 확인
SELECT file#, name
FROM   v$datafile
ORDER  BY file#;

/*
 [결과]
   FILE#  NAME
   -----  -----------------------------------------------
       1  +DATA/ORCLSTBY/DATAFILE/system.xxx
       2  +DATA/ORCLSTBY/DATAFILE/sysaux.xxx
       3  +DATA/ORCLSTBY/DATAFILE/undotbs1.xxx
       4  +DATA/ORCLSTBY/DATAFILE/users.xxx
   → db_unique_name(orclstby)이 ASM 경로에 자동 반영됨 확인
*/


/* ============================================================================
   4. Redo Apply 시작 및 확인
   ============================================================================
   - DUPLICATE 완료 후 Standby는 MOUNTED 상태로 대기 중
   - MRP(Media Recovery Process)를 기동해서 Primary의 Redo를 실시간으로 적용
   ============================================================================ */

/* --------------------------------------------------------------------------
   4-1. MRP 기동
   --------------------------------------------------------------------------
   ※ USING CURRENT LOGFILE: SRL에 기록되는 즉시 적용 (Real-Time Apply)
   ※ DISCONNECT FROM SESSION: 백그라운드로 실행, 세션 종료해도 MRP 계속 동작
   -------------------------------------------------------------------------- */

-- [VM3 — oracle 계정, SYSDBA 접속]
CONN / AS SYSDBA

ALTER DATABASE RECOVER MANAGED STANDBY DATABASE
    USING CURRENT LOGFILE DISCONNECT FROM SESSION;

/*
 [결과]
   Database altered.
   → MRP 백그라운드 기동 완료
*/


/* --------------------------------------------------------------------------
   4-2. MRP 프로세스 확인
   -------------------------------------------------------------------------- */

SELECT process, status, thread#, sequence#
FROM   v$managed_standby
WHERE  process LIKE 'MRP%' OR process LIKE 'RFS%';

/*
 [결과]
   PROCESS  STATUS        THREAD#  SEQUENCE#
   -------  ------------  -------  ---------
   RFS      IDLE                1         xx   ← Redo 수신 프로세스
   MRP0     APPLYING_LOG        1         xx   ← Redo 적용 프로세스
   → MRP0 APPLYING_LOG 확인 — Real-Time Apply 정상 동작
*/


/* --------------------------------------------------------------------------
   4-3. 동기화 상태 확인
   -------------------------------------------------------------------------- */

-- transport lag / apply lag 확인 (VM3에서 실행)
SELECT name, value, time_computed
FROM   v$dataguard_stats
WHERE  name IN ('transport lag', 'apply lag');

/*
 [결과]
   NAME           VALUE       TIME_COMPUTED
   -------------  ----------  -------------------
   transport lag  +00:00:00   ...
   apply lag      +00:00:00   ...
   → 두 값 모두 0초 — Primary와 완전 동기화 상태
*/

-- Primary에서 Redo 전송 목적지 상태 확인 (VM1에서 실행)
SELECT dest_id, dest_name, status, target, destination, error
FROM   v$archive_dest
WHERE  dest_id = 2;

/*
 [결과]
   DEST_ID  DEST_NAME           STATUS  TARGET   DESTINATION  ERROR
   -------  ------------------  ------  -------  -----------  -----
         2  LOG_ARCHIVE_DEST_2  VALID   STANDBY  orclstby
   → STATUS=VALID, ERROR 없음 — Redo 전송 정상
*/


/* ============================================================================
   5. 동기화 검증 — Primary INSERT → Standby 반영 확인
   ============================================================================ */

/* --------------------------------------------------------------------------
   5-1. Primary 테스트 테이블 생성 및 데이터 입력
   -------------------------------------------------------------------------- */

-- [VM1 — oracle 계정, SYSDBA 접속]
CONN / AS SYSDBA

-- 테스트용 테이블 생성
CREATE TABLE system.dg_test (
    id   NUMBER,
    msg  VARCHAR2(100),
    dt   DATE DEFAULT SYSDATE
);

-- 데이터 입력
INSERT INTO system.dg_test (id, msg) VALUES (1, 'Primary-1');
INSERT INTO system.dg_test (id, msg) VALUES (2, 'Primary-2');
COMMIT;

/*
 [결과]
   Table created.
   1 row created.
   1 row created.
   Commit complete.
*/

-- 로그 스위치로 Redo 즉시 전송
ALTER SYSTEM SWITCH LOGFILE;

/*
 [결과]
   System altered.
*/


/* --------------------------------------------------------------------------
   5-2. Standby에서 반영 확인
   --------------------------------------------------------------------------
   ※ Physical Standby는 기본적으로 MOUNTED 상태 (READ ONLY 불가)
   ※ Active Data Guard 옵션 없이 조회하려면 READ ONLY로 임시 전환 후 확인
   -------------------------------------------------------------------------- */

-- [VM3 — oracle 계정, SYSDBA 접속]
CONN / AS SYSDBA

-- MRP 중지 (READ ONLY로 열기 위해 Redo Apply 일시 중단)
ALTER DATABASE RECOVER MANAGED STANDBY DATABASE CANCEL;

/*
 [결과]
   Database altered.
*/

-- READ ONLY로 열기
ALTER DATABASE OPEN READ ONLY;

/*
 [결과]
   Database altered.
*/

-- Standby에서 데이터 조회
SELECT id, msg, dt FROM system.dg_test ORDER BY id;

/*
 [결과]
   ID  MSG        DT
   --  ---------  -------------------
    1  Primary-1  ...
    2  Primary-2  ...
   → Primary에서 입력한 데이터가 Standby에 반영됨 확인
*/


/* --------------------------------------------------------------------------
   5-3. Redo Apply 재기동
   --------------------------------------------------------------------------
   ※ 확인 후 Standby를 다시 MOUNTED 상태로 전환하고 MRP 재기동
   -------------------------------------------------------------------------- */

-- MOUNTED 상태로 전환
SHUTDOWN IMMEDIATE;
STARTUP MOUNT;

-- MRP 재기동
ALTER DATABASE RECOVER MANAGED STANDBY DATABASE
    USING CURRENT LOGFILE DISCONNECT FROM SESSION;

/*
 [결과]
   Database altered.
   → MRP 재기동 완료
*/


/* ============================================================================
   6. 관련 뷰 정리
   ============================================================================ */

/* --------------------------------------------------------------------------
   6-1. v$database — DB 역할 및 상태 확인
   -------------------------------------------------------------------------- */

-- VM1 (Primary)
SELECT name, db_unique_name, database_role, open_mode, force_logging
FROM   v$database;

/*
 [결과]
   NAME  DB_UNIQUE_NAME  DATABASE_ROLE  OPEN_MODE   FORCE_LOGGING
   ----  --------------  -------------  ----------  -------------
   ORCL  orcl            PRIMARY        READ WRITE  YES
*/

-- VM3 (Standby)
SELECT name, db_unique_name, database_role, open_mode, force_logging
FROM   v$database;

/*
 [결과]
   NAME  DB_UNIQUE_NAME  DATABASE_ROLE    OPEN_MODE  FORCE_LOGGING
   ----  --------------  ---------------  ---------  -------------
   ORCL  orclstby        PHYSICAL STANDBY MOUNTED    YES
*/


/* --------------------------------------------------------------------------
   6-2. v$managed_standby — MRP / RFS 프로세스 상태
   -------------------------------------------------------------------------- */

-- VM3에서 실행
SELECT process, status, client_process, thread#, sequence#, block#
FROM   v$managed_standby
ORDER  BY process;

/*
 [결과]
   PROCESS  STATUS        CLIENT_PROCESS  THREAD#  SEQUENCE#  BLOCK#
   -------  ------------  --------------  -------  ---------  ------
   MRP0     APPLYING_LOG  N/A                   1         xx      xx
   RFS      IDLE          LGWR                  1         xx       0
   → MRP0: Redo 적용 중 / RFS: Primary LGWR로부터 Redo 수신 중
*/


/* --------------------------------------------------------------------------
   6-3. v$dataguard_stats — transport lag / apply lag
   -------------------------------------------------------------------------- */

-- VM3에서 실행
SELECT name, value, datum_time, time_computed
FROM   v$dataguard_stats;

/*
 [결과]
   NAME                   VALUE       DATUM_TIME  TIME_COMPUTED
   ---------------------  ----------  ----------  -------------------
   transport lag          +00:00:00   ...         ...
   apply lag              +00:00:00   ...         ...
   apply finish time      +00:00:00   ...         ...
   estimated startup time ...         ...         ...
   → transport lag / apply lag 모두 0초 — 정상 동기화 확인
*/


/* --------------------------------------------------------------------------
   6-4. v$archive_dest — Redo 전송 목적지 상태
   -------------------------------------------------------------------------- */

-- VM1에서 실행
SELECT dest_id, status, target, destination, error,
       fail_sequence, failure_count
FROM   v$archive_dest
WHERE  status != 'INACTIVE'
ORDER  BY dest_id;

/*
 [결과]
   DEST_ID  STATUS  TARGET   DESTINATION  ERROR  FAIL_SEQUENCE  FAILURE_COUNT
   -------  ------  -------  -----------  -----  -------------  -------------
         1  VALID   PRIMARY  USE_DB_...              0              0
         2  VALID   STANDBY  orclstby                0              0
   → DEST_2 STATUS=VALID, FAILURE_COUNT=0, ERROR 없음 확인
*/


/* --------------------------------------------------------------------------
   6-5. v$standby_log — SRL 상태
   -------------------------------------------------------------------------- */

-- VM3에서 실행 (MRP 동작 중)
SELECT group#, thread#, sequence#, bytes/1024/1024 AS mb, used, status, archived
FROM   v$standby_log
ORDER  BY group#;

/*
 [결과]
   GROUP#  THREAD#  SEQUENCE#  MB   USED  STATUS     ARCHIVED
   ------  -------  ---------  ---  ----  ---------  --------
        4        1         xx  200  xxx   ACTIVE     NO         ← 현재 수신 중
        5        1          0  200    0   UNASSIGNED YES
        6        1          0  200    0   UNASSIGNED YES
        7        1          0  200    0   UNASSIGNED YES
   → ACTIVE   : 현재 Primary로부터 Redo를 수신 중인 SRL
   → UNASSIGNED: 대기 상태
*/


/* ============================================================================
   실습 핵심 요약
   ============================================================================

   주제                         핵심 포인트
   -------------------------    ---------------------------------------------------
   FORCE LOGGING                NOLOGGING을 무시하고 모든 변경을 Redo로 기록
                                Data Guard 필수 설정
   SRL 그룹 수                  Online Redo Log 그룹 수 + 1 = 4개
   SRL 크기                     Online Redo Log와 동일하게 200MB
   SRL 저장 위치                +REDO 그룹 — Online Redo Log와 I/O 분리
   SRL 상태                     UNASSIGNED: 대기 / ACTIVE: 수신 중
   LOG_ARCHIVE_CONFIG           DG 구성원 명단 — 등록된 db_unique_name만 Redo 주고받음
   LOG_ARCHIVE_DEST_2           Standby로 Redo 전송 목적지 — SERVICE=orclstby
   VALID_FOR                    역할·로그 타입별 목적지 필터 — PRIMARY_ROLE일 때만 전송
   FAL_SERVER                   Gap 발생 시 Redo를 재요청할 서버
   STANDBY_FILE_MANAGEMENT=AUTO Primary 데이터파일 변경 시 Standby 자동 반영
   ORA-12528 원인               NOMOUNT 상태에서 동적 등록 서비스로 접속 시 발생
   ORCLSTBY_STATIC              Static Entry 서비스로 접속 — UR=A 옵션 필수
   RMAN DUPLICATE               FROM ACTIVE DATABASE — 백업 없이 네트워크로 직접 복제
   NOFILENAMECHECK              ASM 환경에서 Primary와 파일 경로 동일해도 오류 없이 진행
   DORECOVER                    복제 후 Redo Apply까지 자동 수행
   MRP                          Media Recovery Process — Standby에서 Redo를 적용하는 프로세스
   USING CURRENT LOGFILE        SRL에 기록되는 즉시 적용 — Real-Time Apply
   DISCONNECT FROM SESSION      MRP를 백그라운드로 실행 — 세션 종료해도 계속 동작
   transport lag                Primary Redo 생성 → Standby 수신까지 시간 차
   apply lag                    Standby 수신 → 데이터파일 적용까지 시간 차
   ASM 경로 자동 변환           DUPLICATE 후 +DATA/ORCLSTBY/... 형태로 db_unique_name 자동 반영

   ============================================================================ */
