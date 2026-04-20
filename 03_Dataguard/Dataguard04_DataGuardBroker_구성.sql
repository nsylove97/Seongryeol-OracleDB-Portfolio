/*
================================================================================
 Data Guard 04: Data Guard Broker 구성 — DGMGRL & Configuration 관리
================================================================================
 블로그: https://nsylove97.tistory.com/49
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
   1. Data Guard Broker 개요
   2. Broker 활성화 전 사전 준비
      2-1. SPFILE 사용 여부 확인
      2-2. LOG_ARCHIVE_DEST_2 비우기 (VM1, VM3)
   3. DG_BROKER_START 활성화
      3-1. DG_BROKER_START=TRUE 설정 (VM1, VM3)
      3-2. DMON 프로세스 기동 확인
   4. DGMGRL — Configuration 생성 및 활성화
      4-1. DGMGRL 접속
      4-2. Configuration 생성
      4-3. Standby DB 추가
      4-4. Configuration 활성화
      4-5. Broker Configuration File 생성 확인
   5. 구성 상태 확인
      5-1. SHOW CONFIGURATION
      5-2. SHOW DATABASE
      5-3. SHOW DATABASE VERBOSE
   6. Protection Mode 확인
      6-1. DGMGRL에서 확인
      6-2. SQL*Plus에서 확인
      6-3. Protection Mode 변경 방법 (참고)
   7. VALIDATE DATABASE — 구성 검증
      7-1. VALIDATE DATABASE
      7-2. VALIDATE STATIC CONNECT IDENTIFIER
      7-3. StaticConnectIdentifier 수정 (.localdomain 불일치 해결)
      7-4. VALIDATE NETWORK CONFIGURATION
   8. 관련 뷰 & 파일 정리
      8-1. v$dataguard_config
      8-2. v$dg_broker_config
      8-3. Broker Log 파일 위치
================================================================================
*/


/* ============================================================================
   1. Data Guard Broker 개요
   ============================================================================
   - Data Guard Broker: 데이터 가드 설정·운영·모니터링을 자동화해주는 중앙 관리 도구
   - SQL 명령어로 직접 관리하는 것보다 훨씬 단순하고 오류 가능성이 낮음
   - CLI 도구: DGMGRL / GUI 도구: Oracle Enterprise Manager Cloud Control

   Broker 핵심 구성 요소
   +-----------------------+--------------------------------------------------------+
   | 구성 요소             | 설명                                                   |
   +-----------------------+--------------------------------------------------------+
   | DMON                  | 서버 측 백그라운드 프로세스                            |
   |                       | Primary·Standby 상태 모니터링,                         |
   |                       | Switchover/Failover 제어, 파라미터 자동 조정           |
   +-----------------------+--------------------------------------------------------+
   | Configuration File    | Broker가 사용하는 설정 저장 파일                       |
   |                       | dr1<db_unique_name>.dat / dr2<db_unique_name>.dat 형태 |
   |                       | $ORACLE_HOME/dbs에 저장                                |
   +-----------------------+--------------------------------------------------------+
   | Broker Log            | DMON 동작 기록                                         |
   |                       | Alert Log와 같은 디렉터리에 drc<SID>.log로 생성        |
   +-----------------------+--------------------------------------------------------+

   Broker 사용을 위한 전제 조건
     1. SPFILE 사용 필수        <- Broker가 파라미터를 직접 수정하기 때문
     2. DG_BROKER_START=TRUE    <- DMON 프로세스 기동
     3. Oracle Net 설정 완료    <- tnsnames.ora / listener.ora Static Entry
     4. LOG_ARCHIVE_DEST_n 정리 <- Broker가 Redo 전송을 직접 관리하므로 기존 설정과 충돌 방지
   ============================================================================ */


/* ============================================================================
   2. Broker 활성화 전 사전 준비
   ============================================================================ */

/* --------------------------------------------------------------------------
   2-1. SPFILE 사용 여부 확인
   --------------------------------------------------------------------------
   ※ Broker는 반드시 SPFILE을 사용해야 함
   ※ PFILE로 기동 중이면 Broker가 파라미터를 수정할 수 없음
   -------------------------------------------------------------------------- */

-- [VM1, VM3 양쪽에서 확인]
SHOW PARAMETER spfile

/*
 [VM1 결과]
   NAME    TYPE    VALUE
   ------- ------- ----------------------------------------
   spfile  string  +DATA/ORCL/PARAMETERFILE/spfile.266.xxx
   -> ASM에 spfile 존재 확인

 [VM3 결과]
   NAME    TYPE    VALUE
   ------- ------- ----------------------------------------
   spfile  string  /u01/app/oracle/product/19.3.0/dbhome/dbs/spfileorclstby.ora
   -> OS 파일 시스템에 spfile 존재 확인
   ※ RMAN DUPLICATE 시 pfile로 기동했기 때문에 spfile이 OS에 생성됨
   ※ 운영상 문제 없으므로 그대로 진행
*/


/* --------------------------------------------------------------------------
   2-2. LOG_ARCHIVE_DEST_2 비우기 (VM1, VM3)
   --------------------------------------------------------------------------
   ※ Broker 활성화하면 Broker가 Redo 전송 설정을 직접 관리
   ※ 3편에서 설정한 LOG_ARCHIVE_DEST_2가 남아 있으면 Broker 설정과 충돌
   ※ VM1·VM3 양쪽 모두 반드시 비워야 함
   -------------------------------------------------------------------------- */

-- [VM1 — oracle 계정, SYSDBA 접속]
CONN / AS SYSDBA

-- 현재 설정 확인
SHOW PARAMETER log_archive_dest_2

/*
 [결과]
   NAME                  TYPE    VALUE
   --------------------- ------- -----------------------------------------------
   log_archive_dest_2    string  SERVICE=orclstby ASYNC VALID_FOR=...
   -> 3편에서 설정한 값 남아 있음 — 비워야 함
*/

-- LOG_ARCHIVE_DEST_2 비우기
ALTER SYSTEM SET LOG_ARCHIVE_DEST_2='' SCOPE=BOTH;

/*
 [결과]
   System altered.
*/

-- 확인
SHOW PARAMETER log_archive_dest_2

/*
 [결과]
   NAME                  TYPE    VALUE
   --------------------- ------- -----
   log_archive_dest_2    string
   -> 비워짐 확인
*/

-- [VM3 — oracle 계정, SYSDBA 접속]
-- Standby pfile에도 LOG_ARCHIVE_DEST_2가 설정되어 있으므로 동일하게 비우기
CONN / AS SYSDBA

ALTER SYSTEM SET LOG_ARCHIVE_DEST_2='' SCOPE=BOTH;

/*
 [결과]
   System altered.
*/


/* ============================================================================
   3. DG_BROKER_START 활성화
   ============================================================================
   - VM1·VM3 양쪽 모두에서 DG_BROKER_START=TRUE로 설정
   - 설정과 동시에 DMON 프로세스가 기동됨
   ============================================================================ */

/* --------------------------------------------------------------------------
   3-1. DG_BROKER_START=TRUE 설정 (VM1, VM3)
   -------------------------------------------------------------------------- */

-- [VM1 & VM3 — oracle 계정, SYSDBA 접속]
CONN / AS SYSDBA

ALTER SYSTEM SET DG_BROKER_START=TRUE SCOPE=BOTH;

/*
 [결과]
   System altered.
*/


/* --------------------------------------------------------------------------
   3-2. DMON 프로세스 기동 확인
   -------------------------------------------------------------------------- */

-- SQL*Plus에서 확인 (VM1, VM3 양쪽에서)
SELECT name, description
FROM   v$bgprocess
WHERE  name = 'DMON';

/*
 [결과]
   NAME  DESCRIPTION
   ----  ----------------------------------
   DMON  Data Guard Broker Monitor Process
   -> DMON 프로세스 확인
*/

-- OS에서도 확인 가능
-- ps -ef | grep dmon

/*
 [결과]
   oracle  ...  ora_dmon_orcl      <- VM1
   oracle  ...  ora_dmon_orclstby  <- VM3
   -> 양쪽 DMON 프로세스 기동 확인
*/


/* ============================================================================
   4. DGMGRL — Configuration 생성 및 활성화
   ============================================================================
   - DGMGRL: Data Guard Broker를 관리하는 전용 CLI 도구
   - VM1(Primary)에서 실행
   ============================================================================ */

/* --------------------------------------------------------------------------
   4-1. DGMGRL 접속
   -------------------------------------------------------------------------- */

-- [VM1 — oracle 계정, OS 터미널에서 실행]
-- dgmgrl sys/비밀번호@orcl

/*
 [결과]
   DGMGRL for Linux: Release 19.0.0.0.0
   Copyright (c) 1982, 2019, Oracle and/or its affiliates. All rights reserved.
   Welcome to DGMGRL, type "help" for information.
   Connected to "orcl"
   Connected as SYSDBA.
   DGMGRL>
*/


/* --------------------------------------------------------------------------
   4-2. Configuration 생성
   --------------------------------------------------------------------------
   - Primary DB를 포함한 Configuration 생성
   -------------------------------------------------------------------------- */

-- DGMGRL 프롬프트에서 실행
/*
   DGMGRL> CREATE CONFIGURATION dg_orcl AS
             PRIMARY DATABASE IS orcl
             CONNECT IDENTIFIER IS orcl;

   [결과]
   Configuration "dg_orcl" created with primary database "orcl"
*/


/* --------------------------------------------------------------------------
   4-3. Standby DB 추가
   --------------------------------------------------------------------------
   ※ CONNECT IDENTIFIER IS orclstby_static
      : 3편에서 tnsnames.ora에 추가한 Static Entry 서비스 사용
   ※ MAINTAINED AS PHYSICAL : Physical Standby로 등록
   -------------------------------------------------------------------------- */

/*
   DGMGRL> ADD DATABASE orclstby AS
             CONNECT IDENTIFIER IS orclstby_static
             MAINTAINED AS PHYSICAL;

   [결과]
   Database "orclstby" added
*/


/* --------------------------------------------------------------------------
   4-4. Configuration 활성화
   -------------------------------------------------------------------------- */

/*
   DGMGRL> ENABLE CONFIGURATION;

   [결과]
   Enabled.
*/


/* --------------------------------------------------------------------------
   4-5. Broker Configuration File 생성 확인
   --------------------------------------------------------------------------
   ※ Broker Configuration File은 $ORACLE_HOME/dbs에 이중화(2개)로 저장됨
   -------------------------------------------------------------------------- */

-- [VM1 — oracle 계정, OS 터미널에서 실행]
-- ls -l $ORACLE_HOME/dbs/dr*

/*
 [결과]
   -rw-r----- 1 oracle oinstall ... dr1orcl.dat
   -rw-r----- 1 oracle oinstall ... dr2orcl.dat
   -> Broker Configuration File 2개 생성 (이중화) 확인
*/

-- [VM3 — oracle 계정, OS 터미널에서 실행]
-- ls -l $ORACLE_HOME/dbs/dr*

/*
 [결과]
   -rw-r----- 1 oracle oinstall ... dr1orclstby.dat
   -rw-r----- 1 oracle oinstall ... dr2orclstby.dat
*/


/* ============================================================================
   5. 구성 상태 확인
   ============================================================================ */

/* --------------------------------------------------------------------------
   5-1. SHOW CONFIGURATION
   -------------------------------------------------------------------------- */

/*
   DGMGRL> SHOW CONFIGURATION;

   [결과]
   Configuration - dg_orcl

     Protection Mode: MaxPerformance
     Members:
     orcl     - Primary database
     orclstby - Physical standby database

   Fast-Start Failover:  Disabled

   Configuration Status:
   SUCCESS   (status updated xx seconds ago)
   -> SUCCESS 확인 — Broker 구성 정상
*/


/* --------------------------------------------------------------------------
   5-2. SHOW DATABASE
   -------------------------------------------------------------------------- */

/*
   -- Primary 상세 확인
   DGMGRL> SHOW DATABASE orcl;

   [결과]
   Database - orcl

     Role:               PRIMARY
     Intended State:     TRANSPORT-ON
     Instance(s):
       orcl

   Database Status:
   SUCCESS

   -- Standby 상세 확인
   DGMGRL> SHOW DATABASE orclstby;

   [결과]
   Database - orclstby

     Role:               PHYSICAL STANDBY
     Intended State:     APPLY-ON
     Transport Lag:      0 seconds (computed xx seconds ago)
     Apply Lag:          0 seconds (computed xx seconds ago)
     Average Apply Rate: x KByte/s
     Real Time Query:    OFF
     Instance(s):
       orclstby

   Database Status:
   SUCCESS
   -> Transport Lag / Apply Lag 모두 0초 확인
*/


/* --------------------------------------------------------------------------
   5-3. SHOW DATABASE VERBOSE
   --------------------------------------------------------------------------
   - 더 상세한 정보 확인
   -------------------------------------------------------------------------- */

/*
   DGMGRL> SHOW DATABASE VERBOSE orclstby;

   [결과 일부]
   Database - orclstby

     Role:               PHYSICAL STANDBY
     Intended State:     APPLY-ON
     Transport Lag:      0 seconds
     Apply Lag:          0 seconds
     ...
     Properties:
       DGConnectIdentifier             = 'orclstby_static'
       LogXptMode                      = 'ASYNC'
       ...
       StandbyFileManagement           = 'AUTO'
       ...
*/


/* ============================================================================
   6. Protection Mode 확인
   ============================================================================
   - Broker 활성화 후 기본 Protection Mode는 Maximum Performance
   ============================================================================ */

/* --------------------------------------------------------------------------
   6-1. DGMGRL에서 확인
   -------------------------------------------------------------------------- */

/*
   DGMGRL> SHOW CONFIGURATION;

   [결과 일부]
     Protection Mode: MaxPerformance
   -> 기본값 MaxPerformance 확인
*/


/* --------------------------------------------------------------------------
   6-2. SQL*Plus에서 확인
   -------------------------------------------------------------------------- */

SELECT protection_mode, protection_level
FROM   v$database;

/*
 [결과]
   PROTECTION_MODE       PROTECTION_LEVEL
   --------------------  --------------------
   MAXIMUM PERFORMANCE   MAXIMUM PERFORMANCE
*/


/* --------------------------------------------------------------------------
   6-3. Protection Mode 변경 방법 (참고)
   --------------------------------------------------------------------------
   ※ LogXptMode를 먼저 변경한 뒤 Protection Mode를 변경해야 함
   -------------------------------------------------------------------------- */

/*
   -- Maximum Availability로 변경하는 경우

   -- 1단계: 양쪽 DB의 LogXptMode 변경 (ASYNC -> SYNC)
   DGMGRL> EDIT DATABASE orcl     SET PROPERTY LogXptMode=SYNC;
   DGMGRL> EDIT DATABASE orclstby SET PROPERTY LogXptMode=SYNC;

   -- 2단계: Protection Mode 변경
   DGMGRL> EDIT CONFIGURATION SET PROTECTION MODE AS MaxAvailability;

   -- 확인
   DGMGRL> SHOW CONFIGURATION;

   [결과 일부]
     Protection Mode: MaxAvailability
*/


/* ============================================================================
   7. VALIDATE DATABASE — 구성 검증
   ============================================================================
   - Broker가 제공하는 검증 명령어로 구성의 이상 여부 점검
   ============================================================================ */

/* --------------------------------------------------------------------------
   7-1. VALIDATE DATABASE
   --------------------------------------------------------------------------
   - Standby DB 전반적인 상태 검증
   -------------------------------------------------------------------------- */

/*
   DGMGRL> VALIDATE DATABASE orclstby;

   [결과]
     Database Role:     Physical standby database
     Primary Database:  orcl

     Ready for Switchover:  Yes
     Ready for Failover:    Yes (Primary Running)

     Flashback Database Status:
       orcl    :  Off
       orclstby:  Off

     Managed by Clusterware:
       orcl    :  YES
       orclstby:  NO

   -> Ready for Switchover/Failover: Yes 확인
   -> Flashback Off — FSFO 구성 시 활성화 필요
*/


/* --------------------------------------------------------------------------
   7-2. VALIDATE STATIC CONNECT IDENTIFIER
   --------------------------------------------------------------------------
   ※ DB가 내려가 있어도 Broker가 접속할 수 있는지 확인
   -------------------------------------------------------------------------- */

/*
   DGMGRL> VALIDATE STATIC CONNECT IDENTIFIER FOR ALL;

   [결과]
     Validating static connect identifier for database "orcl" ...
       The static connect identifier allows for a connection to database "orcl".
     Validating static connect identifier for database "orclstby" ...
       The static connect identifier allows for a connection to database "orclstby".
   -> 양쪽 모두 Static Entry 접속 가능 확인
*/


/* --------------------------------------------------------------------------
   7-3. StaticConnectIdentifier 수정 (.localdomain 불일치 해결)
   --------------------------------------------------------------------------
   ※ Broker가 사용하는 SERVICE_NAME이 'orcl_DGMGRL'인데
      listener.ora의 GLOBAL_DBNAME은 'orcl_DGMGRL.localdomain'으로 등록된 경우
      도메인 불일치로 ORA-12514 오류 발생
   ※ listener.ora는 그대로 두고
   ※ Broker의 StaticConnectIdentifier 속성에 .localdomain을 포함한 형태로 수정
   -------------------------------------------------------------------------- */

/*
   DGMGRL> EDIT DATABASE orcl
           SET PROPERTY StaticConnectIdentifier=
           '(DESCRIPTION=(ADDRESS=(PROTOCOL=TCP)(HOST=oelsvr1.localdomain)(PORT=1521))(CONNECT_DATA=(SERVICE_NAME=orcl_DGMGRL.localdomain)(INSTANCE_NAME=orcl)(SERVER=DEDICATED)(STATIC_SERVICE=TRUE)))';

   DGMGRL> EDIT DATABASE orclstby
           SET PROPERTY StaticConnectIdentifier=
           '(DESCRIPTION=(ADDRESS=(PROTOCOL=TCP)(HOST=oel-standby.localdomain)(PORT=1521))(CONNECT_DATA=(SERVICE_NAME=orclstby_DGMGRL.localdomain)(INSTANCE_NAME=orclstby)(SERVER=DEDICATED)(STATIC_SERVICE=TRUE)))';

   -- 재확인
   DGMGRL> VALIDATE STATIC CONNECT IDENTIFIER FOR ALL;

   [결과]
     Validating static connect identifier for database "orcl" ...
       The static connect identifier allows for a connection to database "orcl".
     Validating static connect identifier for database "orclstby" ...
       The static connect identifier allows for a connection to database "orclstby".
   -> 양쪽 모두 Static Entry 접속 가능 확인
*/


/* --------------------------------------------------------------------------
   7-4. VALIDATE NETWORK CONFIGURATION
   --------------------------------------------------------------------------
   - Primary <-> Standby 네트워크 연결 상태 검증
   -------------------------------------------------------------------------- */

/*
   DGMGRL> VALIDATE NETWORK CONFIGURATION FOR ALL;

   [결과]
     Validating network configuration for database "orcl" ...
     Validating network configuration for database "orclstby" ...
     Network configuration is valid.
   -> 네트워크 구성 정상 확인
*/


/* ============================================================================
   8. 관련 뷰 & 파일 정리
   ============================================================================ */

/* --------------------------------------------------------------------------
   8-1. v$dataguard_config — DG 구성원 목록
   -------------------------------------------------------------------------- */

-- VM1 또는 VM3에서 실행
SELECT db_unique_name, parent_dbun, dest_role
FROM   v$dataguard_config;

/*
 [결과]
   DB_UNIQUE_NAME  PARENT_DBUN  DEST_ROLE
   --------------  -----------  ----------------
   orcl            NONE         PRIMARY DATABASE
   orclstby        orcl         PHYSICAL STANDBY
   -> Broker가 인식하는 DG 구성원 확인
*/


/* --------------------------------------------------------------------------
   8-2. v$dg_broker_config — Broker 구성원 및 접속 식별자 확인
   -------------------------------------------------------------------------- */

-- VM1에서 실행
SELECT database, connect_identifier, dataguard_role, enabled, status
FROM   v$dg_broker_config;

/*
 [결과]
   DATABASE  CONNECT_IDENTIFIER  DATAGUARD_ROLE    ENABLED  STATUS
   --------  ------------------  ----------------  -------  ------
   orcl      orcl                PRIMARY DATABASE   TRUE         0
   orclstby  orclstby_static     PHYSICAL STANDBY   TRUE         0
   -> Broker가 인식하는 DG 구성원 및 접속 식별자 확인
*/


/* --------------------------------------------------------------------------
   8-3. Broker Log 파일 위치
   --------------------------------------------------------------------------
   ※ Broker 동작 기록 로그 — Alert Log와 같은 디렉터리에 생성
   -------------------------------------------------------------------------- */

-- [VM1 — oracle 계정, OS 터미널에서 실행]
-- ls $ORACLE_BASE/diag/rdbms/orcl/orcl/trace/drcorcl.log

-- [VM3 — oracle 계정, OS 터미널에서 실행]
-- ls $ORACLE_BASE/diag/rdbms/orclstby/orclstby/trace/drcorclstby.log


/* ============================================================================
   주요 DGMGRL 명령어 정리
   ============================================================================

   명령어                                              설명
   --------------------------------------------------  --------------------------
   SHOW CONFIGURATION                                  전체 구성 상태 확인
   SHOW DATABASE <n>                                   특정 DB 상태 확인
   SHOW DATABASE VERBOSE <n>                           특정 DB 상세 속성 확인
   EDIT DATABASE <n> SET PROPERTY <key>=<value>        DB 속성 변경
   EDIT CONFIGURATION SET PROTECTION MODE AS <mode>    Protection Mode 변경
   ENABLE CONFIGURATION                                Configuration 활성화
   DISABLE CONFIGURATION                               Configuration 비활성화
   VALIDATE DATABASE <n>                               DB 구성 검증
   VALIDATE NETWORK CONFIGURATION FOR ALL              네트워크 연결 검증
   VALIDATE STATIC CONNECT IDENTIFIER FOR ALL          Static Entry 접속 검증

   ============================================================================ */


/* ============================================================================
   실습 핵심 요약
   ============================================================================

   주제                              핵심 포인트
   --------------------------------  --------------------------------------------------
   Broker 필수 조건                  SPFILE 사용 + DG_BROKER_START=TRUE + Oracle Net 설정 완료
   LOG_ARCHIVE_DEST_2 정리           Broker 활성화 전 반드시 비워야 함
                                     Broker가 Redo 전송을 직접 관리
   DMON                              Broker 핵심 백그라운드 프로세스
                                     DG_BROKER_START=TRUE 시 자동 기동
   Configuration File                dr1/dr2<db_unique_name>.dat
                                     $ORACLE_HOME/dbs에 이중화 저장
   Broker Log                        drc<SID>.log — Alert Log와 같은 디렉터리
   VM3 spfile 위치                   OS 파일 시스템
                                     RMAN DUPLICATE 시 pfile 기동으로 인해 OS에 생성됨
   CREATE CONFIGURATION              Primary DB를 포함한 Configuration 생성
   ADD DATABASE                      Standby DB 추가
                                     CONNECT IDENTIFIER에 Static Entry 서비스 사용
   ENABLE CONFIGURATION              Configuration 활성화
                                     이 시점부터 Broker가 DG 전체 관리
   SHOW CONFIGURATION                전체 구성 상태 한눈에 확인 — SUCCESS가 정상
   Transport Lag / Apply Lag         SHOW DATABASE에서 실시간 확인 가능
   기본 Protection Mode              MaxPerformance — Broker 활성화 후 기본값
   Protection Mode 변경 순서         LogXptMode 먼저 변경 -> EDIT CONFIGURATION SET PROTECTION MODE
   VALIDATE DATABASE                 Switchover/Failover 준비 여부 및 구성 이상 점검
   Flashback Off                     VALIDATE 결과에서 확인 — FSFO 구성 시 반드시 활성화 필요
   StaticConnectIdentifier 수정      listener.ora는 그대로 두고
                                     Broker 속성에 .localdomain 포함한 형태로 직접 지정

   ============================================================================ */
