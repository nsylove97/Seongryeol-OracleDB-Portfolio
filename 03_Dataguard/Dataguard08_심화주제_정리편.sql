/*
================================================================================
 Data Guard 08: 심화 주제 정리편
================================================================================
 블로그: https://nsylove97.tistory.com/53
 GitHub: https://github.com/nsylove97/NSY-DB-Portfolio

 실습 환경
   - OS            : Oracle Linux 7.9 (VMware Virtual Machine)
   - DB            : Oracle Database 19c (Grid Infrastructure + DB)
   - Tool          : SQL*Plus, DGMGRL, MobaXterm(SSH)
   - Grid HOME     : /u01/app/19.3.0/gridhome
   - DB HOME       : /u01/app/oracle/product/19.3.0/dbhome
   - Primary (VM1) : IP 192.168.111.50 / hostname oelsvr1     / db_unique_name orcl
   - Standby (VM3) : IP 192.168.111.60 / hostname oel-standby / db_unique_name orclstby

 목차
   1.  Lost Write 감지 실습
       1-1. DBMS_DBCOMP 개요
       1-2. DBCOMP 실행 — 특정 파일 및 전체 파일 (VM1)
       1-3. Lost Write 감지 실습 전체 흐름 (VM1)
   2.  ALTER SESSION 명령어 심화
       2-1. ALTER SESSION SYNC WITH PRIMARY (VM1, VM3)
       2-2. GTT 생성 및 ON COMMIT DELETE ROWS 동작 (VM1 → VM3)
   3.  In-Memory 기능과 Standby DB
       3-1. inmemory_size 설정 및 확인 (VM3)
       3-2. IMCS 사용 현황 확인 (VM3)
       3-3. 원상복구 (VM3)
   4.  Broker Configuration Export / Import
       4-1. Export (VM1 — DGMGRL)
       4-2. Import (VM1 — DGMGRL)
   5.  Far Sync & Real-Time Cascade 아키텍처
       5-1. 개요 및 명령어 레퍼런스
   6.  FASTSYNC 모드
       6-1. FASTSYNC 설정 (VM1 — DGMGRL)
   7.  VALIDATE DATABASE 고급 옵션
       7-1. VALIDATE DATABASE DATAFILE (VM1 — DGMGRL)
       7-2. VALIDATE DATABASE SPFILE (VM1 — DGMGRL)
   8.  역할 전환 시 Buffer Cache 유지
       8-1. STANDBY_DB_PRESERVE_STATES 설정 (VM3)
       8-2. 전환 전·후 Buffer Cache 확인 (VM3 → VM1 → VM3)
   9.  행 식별 강제 부여 기법
       9-1. Physical → Logical Standby 전환 (VM1, VM3)
       9-2. PK 없는 테이블 생성 및 문제 확인 (VM1, VM3)
       9-3. RELY DISABLE PRIMARY KEY 추가 및 적용 확인 (VM1, VM3)
   10. 관련 뷰 & 명령어 정리
================================================================================
*/


/* ============================================================================
   1. Lost Write 감지 실습
   ============================================================================ */

/* ----------------------------------------------------------------------------
   1-1. DBMS_DBCOMP 개요

   항목          설명
   -----------   ---------------------------------------------------------------
   패키지        DBMS_DBCOMP
   프로시저      DBCOMP
   동작 방식     Primary와 Standby의 데이터파일 블록을 SCN 단위로 비교
   탐지 대상     Lost Write (쓰기 누락), 블록 손상
   실행 위치     Primary에서 실행 (Standby는 READ ONLY 또는 MOUNTED 상태)
   ---------------------------------------------------------------------------- */

/* ----------------------------------------------------------------------------
   1-2. DBCOMP 실행 — 특정 파일 및 전체 파일
   ---------------------------------------------------------------------------- */

-- [VM1 — SYSDBA] 특정 데이터파일 단위로 Lost Write 비교
-- 첫 번째 인자: 데이터파일 번호 / 두 번째 인자: 출력 파일 경로
EXECUTE DBMS_DBCOMP.DBCOMP(1, '/tmp/dbcomp_file1.txt');

/*
 [결과]
   PL/SQL procedure successfully completed.
   -> 비교 완료, 결과는 지정 경로 텍스트 파일에 기록됨
*/

/*
   # [VM1 — oracle 계정, OS 터미널] 결과 파일 확인
   cat /tmp/dbcomp_file1.txt

   [정상 결과 예시]
   Comparing blocks in file# 1
   Datafile /u01/app/oracle/oradata/orcl/system01.dbf
   LWLOC=0, LWRMT=0
   → LWLOC=0, LWRMT=0 → Lost Write 없음 확인

   [이상 발견 시 예시]
   LWLOC=1, LWRMT=0
   → LWLOC에 숫자 발생 → Primary 측 Lost Write 탐지
   → 해당 데이터파일 복구 필요
*/

-- [VM1 — SYSDBA] 전체 데이터파일 일괄 비교
-- 'ALL' 지정 시 전체 데이터파일 대상
EXECUTE DBMS_DBCOMP.DBCOMP('ALL', '/tmp/dbcomp_all.txt');

/*
 [결과]
   PL/SQL procedure successfully completed.
   -> 전체 데이터파일 비교 완료
   -> 파일 수에 따라 소요 시간이 길어질 수 있음
   -> Lost Write가 탐지된 데이터파일은 Standby 또는 백업 기준으로 복구 필요
*/

/* ----------------------------------------------------------------------------
   1-3. Lost Write 감지 실습 전체 흐름
   ---------------------------------------------------------------------------- */

-- [VM1 — SYSDBA] 1단계: 테스트 테이블스페이스 및 테이블 생성
-- 일반 OS 경로에 테이블스페이스 생성 (ASM이 아닌 /tmp 경로 사용 — 파일 직접 조작 가능)
CREATE TABLESPACE lw_ts DATAFILE '/tmp/lw_ts01.dbf' SIZE 10M;

/*
 [결과]
   Tablespace created.
*/

CREATE TABLE lw_test (id NUMBER, val VARCHAR2(20)) TABLESPACE lw_ts;

/*
 [결과]
   Table created.
*/

INSERT INTO lw_test VALUES (1, 'VERSION 1');
COMMIT;

/*
 [결과]
   1 row created.
   Commit complete.
*/

-- 메모리의 데이터를 디스크(데이터파일)로 완전히 내려씀
ALTER SYSTEM CHECKPOINT;
ALTER SYSTEM FLUSH BUFFER_CACHE;

/*
 [결과]
   System altered. (각 명령마다)
*/

-- [VM1 — SYSDBA] 2단계: 데이터파일 번호 및 블록 번호 확인
-- 이후 dd 명령어로 해당 블록만 덮어쓰기 위해 사전 확인
SELECT DBMS_ROWID.ROWID_RELATIVE_FNO(rowid) AS fno,
       DBMS_ROWID.ROWID_BLOCK_NUMBER(rowid) AS blkno
FROM   lw_test
WHERE  id = 1;

/*
 [결과 예시]
   FNO   BLKNO
   ----  ------
      8    135
   -> fno=8 (데이터파일 번호), blkno=135 (블록 번호)
   -> 환경에 따라 값이 다를 수 있음 — 이후 dd 명령어에서 사용
*/

/*
   # [VM1 — oracle 계정, OS 터미널] 3단계: 과거 상태의 데이터파일 백업
   cp /tmp/lw_ts01.dbf /tmp/lw_ts01_bkp.dbf

   [결과]
   → 백업 완료 (이 시점의 파일에는 'VERSION 1' 데이터가 기록됨)
*/

-- [VM1 — SYSDBA] 4단계: 데이터 업데이트 및 Standby 동기화
UPDATE lw_test SET val = 'VERSION 2' WHERE id = 1;
COMMIT;

/*
 [결과]
   1 row updated.
   Commit complete.
*/

ALTER SYSTEM CHECKPOINT;
ALTER SYSTEM FLUSH BUFFER_CACHE;

/*
 [결과]
   System altered. (각 명령마다)
*/

-- Redo 전송을 강제하여 Standby에 확실히 적용되도록 함
ALTER SYSTEM SWITCH LOGFILE;

/*
 [결과]
   System altered.
*/

-- [VM1 — SYSDBA] 5단계: Lost Write 시뮬레이션 준비 — 테이블스페이스 Offline
-- 데이터파일 락을 풀기 위해 테이블스페이스 Offline 전환
ALTER TABLESPACE lw_ts OFFLINE;

/*
 [결과]
   Tablespace altered.
*/

/*
   # [VM1 — oracle 계정, OS 터미널] 5단계: Lost Write 시뮬레이션 실행
   # 백업본에서 해당 블록(blkno=135) 하나만 현재 파일로 덮어쓰기 (Lost Write 연출)
   # → 블록이 'VERSION 2'에서 'VERSION 1' 시점으로 롤백됨 (디스크만, DB는 모름)
   # blkno 값은 2단계에서 확인한 값으로 대체
   dd if=/tmp/lw_ts01_bkp.dbf of=/tmp/lw_ts01.dbf bs=8192 count=1 seek=135 skip=135 conv=notrunc
*/

-- [VM1 — SYSDBA] 테이블스페이스 다시 Online
ALTER TABLESPACE lw_ts ONLINE;

/*
 [결과]
   Tablespace altered.
*/

-- Lost Write 확인 — 'VERSION 2'가 아닌 'VERSION 1'이 조회되면 Lost Write 발생 상태
SELECT * FROM lw_test;

/*
 [결과]
   ID  VAL
   --  ---------
    1  VERSION 1
   -> 'VERSION 1' 조회 → Lost Write 발생 확인 (DB는 VERSION 2라고 알고 있지만 디스크에는 VERSION 1 기록)
*/

-- [VM1 — SYSDBA] 6단계: DBMS_DBCOMP.DBCOMP를 통한 탐지
-- fno 값은 2단계에서 확인한 데이터파일 번호로 대체 (예: '8')
EXECUTE DBMS_DBCOMP.DBCOMP('8', '/tmp/dbcomp_res.txt');

/*
 [결과]
   PL/SQL procedure successfully completed.
*/

/*
   # [VM1 — oracle 계정, OS 터미널] 결과 파일 확인
   cat /tmp/dbcomp_res.txt

   [이상 발견 결과 예시]
   LWLOC=1, LWRMT=0
   → LWLOC=1 → Primary 측 블록에서 Lost Write 탐지
   → Lost Write 없는 정상 상태라면 LWLOC=0, LWRMT=0
*/

-- [VM1 — SYSDBA] 7단계: 실습 후 정리
-- 데이터파일 강제 Offline (시스템 테이블스페이스 아닌 경우 OFFLINE DROP 사용)
ALTER DATABASE DATAFILE 8 OFFLINE DROP;

/*
 [결과]
   Database altered.
   -> 파일 번호는 2단계 fno 값으로 대체
*/

DROP TABLESPACE lw_ts INCLUDING CONTENTS AND DATAFILES;

/*
 [결과]
   Tablespace dropped.
*/


/* ============================================================================
   2. ALTER SESSION 명령어 심화
   ============================================================================ */

/* ----------------------------------------------------------------------------
   2-1. ALTER SESSION SYNC WITH PRIMARY
   ---------------------------------------------------------------------------- */

/*
   SYNC WITH PRIMARY 개요

   항목             설명
   ---------------  -----------------------------------------------------------
   역할             ADG 세션이 쿼리를 실행하기 전 Primary 최신 SCN까지
                    Apply가 완료될 때까지 대기하도록 강제하는 명령어
   대기 조건        Apply Lag이 있을 경우 MRP가 따라잡을 때까지 세션 블로킹
   STANDBY_MAX_DATA_DELAY와 차이
                    STANDBY_MAX_DATA_DELAY → 세션 전체 Lag 상한 설정
                    SYNC WITH PRIMARY       → 명령 실행 시점 일회성 강제 동기화
   활용             읽기 정합성이 반드시 보장되어야 하는 조회 직전에 단발성 사용
*/

-- [VM3 — SYSDBA] Apply Lag 의도적 발생 (MRP 중지)
ALTER DATABASE RECOVER MANAGED STANDBY DATABASE CANCEL;

/*
 [결과]
   Database altered.
*/

-- [VM1 — SYSDBA] Primary에 DML 추가 (Standby에 미적용 상태 생성)
INSERT INTO hr.departments (department_id, department_name)
VALUES (990, 'Lag Test Dept');
COMMIT;

/*
 [결과]
   1 row created.
   Commit complete.
*/

ALTER SYSTEM ARCHIVE LOG CURRENT;

/*
 [결과]
   System altered.
*/

-- [VM3 — SYSDBA] Apply Lag 확인 (MRP 중지 상태)
SELECT name, value
FROM   v$dataguard_stats
WHERE  name = 'apply lag';

/*
 [결과 예시]
   NAME       VALUE
   ---------  ------------
   apply lag  +00 00:00:NN
   -> Lag 발생 확인
*/

-- [VM3 — Standby, 일반 세션] SYNC WITH PRIMARY 실행
-- Apply Lag이 있는 경우 MRP가 따라잡을 때까지 이 명령에서 블로킹됨
ALTER SESSION SYNC WITH PRIMARY;

/*
 [결과 — Lag이 없거나 해소 직후]
   Session altered.
   -> Primary 최신 커밋 시점까지 Apply 완료 후 세션 해제
   -> Lag이 있는 경우 MRP 재기동 전까지 블로킹됨
*/

-- [VM3 — SYSDBA, 별도 세션] MRP 재기동으로 위 SYNC 대기 해소
ALTER DATABASE RECOVER MANAGED STANDBY DATABASE
  USING CURRENT LOGFILE DISCONNECT FROM SESSION;

/*
 [결과]
   Database altered.
   -> MRP 재기동 후 SYNC 세션의 대기가 풀리며 Session altered. 반환됨
*/

/* ----------------------------------------------------------------------------
   2-2. GTT 생성 및 ON COMMIT DELETE ROWS 동작
   ---------------------------------------------------------------------------- */

/*
   GTT / PTT와 Standby 비교

   구분                     GTT (Global Temporary Table)         PTT (Private Temporary Table)
   -----------------------  -----------------------------------  --------------------------------
   생성 위치                Primary에서 DDL로 생성, 정의 복제됨  세션 내 생성, 복제 안 됨
   Standby에서 데이터       세션별 독립, Redo 미생성, 동기화 없음 세션별 독립, Redo 미생성, 동기화 없음
   ADG 읽기 세션 활용       읽기 분산 세션 중간 결과 저장 가능    ADG 세션에서 직접 생성·사용 가능

   ON COMMIT 옵션 비교

   옵션                     삭제 시점         주요 용도
   -----------------------  ----------------  ------------------------------------
   ON COMMIT DELETE ROWS    커밋 시점          트랜잭션 단위 임시 집계
   ON COMMIT PRESERVE ROWS  세션 종료 시점     세션 전체에서 재사용하는 임시 데이터
*/

-- [VM1 — Primary] GTT 생성 (정의는 Standby에도 복제됨)
CREATE GLOBAL TEMPORARY TABLE gtt_session_test (
  id    NUMBER,
  memo  VARCHAR2(100)
) ON COMMIT DELETE ROWS;

/*
 [결과]
   Table created.
   -> 정의는 Redo를 통해 Standby에도 복제됨
   -> 세션 데이터는 복제되지 않음
*/

-- [VM3 — Standby ADG 세션] GTT 데이터 삽입 후 커밋
-- ADG 상태(READ ONLY WITH APPLY)에서 GTT는 Standby 자체에서 독립적으로 삽입 가능
INSERT INTO gtt_session_test VALUES (1, 'test');
COMMIT;

/*
 [결과]
   1 row created.
   Commit complete.
*/

-- 커밋 직후 조회
SELECT * FROM gtt_session_test;

/*
 [결과]
   no rows selected
   -> ON COMMIT DELETE ROWS: 커밋 시점에 해당 세션의 데이터 즉시 삭제
   -> ON COMMIT PRESERVE ROWS와 달리 트랜잭션 종료 시 데이터 사라짐
*/


/* ============================================================================
   3. In-Memory 기능과 Standby DB
   ============================================================================ */

/*
   In-Memory Column Store(IMCS) 개요

   항목              설명
   ----------------  ---------------------------------------------------------
   IMCS              SGA 내 별도 영역에 데이터를 컬럼 단위로 저장하는 캐시
   저장 방식         기존 Buffer Cache: 행(Row) 단위 / IMCS: 컬럼(Column) 단위
   주요 효과         집계·분석 쿼리에서 불필요한 컬럼 I/O를 줄여 응답 속도 향상
   inmemory_size     IMCS에 할당할 SGA 메모리 크기 (기본 0, 비활성)
   Standby 독립성    Primary와 독립적으로 설정 가능, 다른 값 적용 가능
   주의              SGA 내 별도 영역으로 할당 → sga_target과 합산하여 메모리 계획 필요
*/

/* ----------------------------------------------------------------------------
   3-1. inmemory_size 설정 및 확인
   ---------------------------------------------------------------------------- */

-- [VM3 — SYSDBA] 현재 inmemory_size 확인
SHOW PARAMETER inmemory_size;

/*
 [결과]
   NAME           TYPE    VALUE
   -------------- ------- -----
   inmemory_size  big int 0
   -> 기본값 0 (IMCS 비활성)
*/

-- [VM3 — SYSDBA] IMCS 활성화 (SPFILE 반영, 재기동 필요)
ALTER SYSTEM SET inmemory_size = 200M SCOPE=SPFILE;

/*
 [결과]
   System altered.
*/

-- [VM3 — SYSDBA] Standby DB 재기동 (IMCS 활성화 반영)
SHUTDOWN IMMEDIATE;

/*
 [결과]
   Oracle instance shut down.
*/

STARTUP MOUNT;

/*
 [결과]
   Oracle instance started.
   ...
   Database mounted.
*/

-- [VM3 — SYSDBA] MRP 재기동 (Real-Time Apply)
ALTER DATABASE RECOVER MANAGED STANDBY DATABASE
  USING CURRENT LOGFILE DISCONNECT FROM SESSION;

/*
 [결과]
   Database altered.
*/

-- [VM3 — SYSDBA] 재기동 후 IMCS 적용 확인
SHOW PARAMETER inmemory_size;

/*
 [결과]
   NAME           TYPE    VALUE
   -------------- ------- ------
   inmemory_size  big int 208M
   -> IMCS 활성화 확인 (설정값보다 약간 크게 반영되는 경우 있음)
*/

/* ----------------------------------------------------------------------------
   3-2. IMCS 사용 현황 확인
   ---------------------------------------------------------------------------- */

-- [VM3 — SYSDBA] IMCS 메모리 풀 할당 및 사용 현황
SELECT pool, alloc_bytes, used_bytes, populate_status
FROM   v$inmemory_area;

/*
 [결과 예시]
   POOL                  ALLOC_BYTES  USED_BYTES  POPULATE_STATUS
   --------------------  -----------  ----------  ---------------
   1MB POOL              149946368             0  DONE
   64KB POOL              50331648             0  DONE
   -> IMCS 메모리 풀 할당 확인
   -> used_bytes=0 → 아직 어떤 세그먼트도 로딩되지 않은 상태
*/

/* ----------------------------------------------------------------------------
   3-3. 원상복구
   ---------------------------------------------------------------------------- */

-- [VM3 — SYSDBA] inmemory_size 0으로 복원 (SPFILE 반영, 재기동 필요)
ALTER SYSTEM SET inmemory_size = 0 SCOPE=SPFILE;

/*
 [결과]
   System altered.
*/

SHUTDOWN IMMEDIATE;

/*
 [결과]
   Oracle instance shut down.
*/

STARTUP MOUNT;

/*
 [결과]
   Oracle instance started.
   ...
   Database mounted.
*/

-- [VM3 — SYSDBA] MRP 재기동
ALTER DATABASE RECOVER MANAGED STANDBY DATABASE
  USING CURRENT LOGFILE DISCONNECT FROM SESSION;

/*
 [결과]
   Database altered.
*/

-- [VM3 — SYSDBA] 복원 확인
SHOW PARAMETER inmemory_size;

/*
 [결과]
   NAME           TYPE    VALUE
   -------------- ------- -----
   inmemory_size  big int 0
   -> 기본값 0 복원 확인 (IMCS 비활성)
*/


/* ============================================================================
   4. Broker Configuration Export / Import
   ============================================================================ */

/*
   Broker Configuration Export / Import 개요

   용도       구성 파일 손상, 재구성, 환경 이전 시 활용
   NOVERIFY   Export / Import 시 DB 접속 없이 메타데이터만 처리 (선택)
   주의       Import 후에는 ENABLE CONFIGURATION 별도 실행 필요
              (NOVERIFY 없이 Export한 경우에도 Import 후 ENABLE 필요)
*/

/* ----------------------------------------------------------------------------
   4-1. Export
   ---------------------------------------------------------------------------- */

/*
   # [VM1 — oracle 계정, OS 터미널] DGMGRL 접속
   dgmgrl sys/비밀번호@orcl

   -- 현재 구성 확인
   SHOW CONFIGURATION;

   [결과 예시]
   Configuration - dg_orcl
     Protection Mode: MaxAvailability
     Members:
     orcl     - Primary database
     orclstby - Physical standby database
   Fast-Start Failover:  Disabled
   Configuration Status: SUCCESS

   -- Broker 구성을 텍스트 파일로 Export
   -- 파일은 $ORACLE_BASE/diag/rdbms/orcl/orcl/trace/ 경로에 생성됨
   EXPORT CONFIGURATION TO 'dg_orcl_export.txt';

   [결과]
   Succeeded.
   → dg_orcl_export.txt 파일에 Broker 구성 메타데이터 저장됨

   # [VM1 — oracle 계정] Export 파일 내용 확인
   cat $ORACLE_BASE/diag/rdbms/orcl/orcl/trace/dg_orcl_export.txt

   [결과 예시]
   CREATE CONFIGURATION 'dg_orcl' AS
     PRIMARY DATABASE IS 'orcl'
     CONNECT IDENTIFIER IS 'orcl';
   ADD DATABASE 'orclstby'
     AS CONNECT IDENTIFIER IS 'orclstby_static'
     MAINTAINED AS PHYSICAL;
   ENABLE CONFIGURATION;
   → DGMGRL 명령어 형태로 구성이 저장됨
*/

/* ----------------------------------------------------------------------------
   4-2. Import
   ---------------------------------------------------------------------------- */

/*
   # [VM1 — DGMGRL]

   -- Import 전: 보호 모드를 MaxPerformance로 낮춰야 REMOVE 가능
   -- (MaxAvailability 이상에서는 REMOVE 전에 모드 변경 필요)
   EDIT CONFIGURATION SET PROTECTION MODE AS MAXPERFORMANCE;

   -- 기존 구성 제거 (Import 전 선행)
   REMOVE CONFIGURATION;

   [결과]
   Removed.

   -- Export 파일로부터 구성 복원
   IMPORT CONFIGURATION FROM 'dg_orcl_export.txt';

   [결과]
   Succeeded. Run ENABLE CONFIGURATION to enable the imported configuration.
   → Broker 구성 복원 완료, 활성화 별도 필요

   -- 구성 활성화
   ENABLE CONFIGURATION;

   -- 복원 후 상태 확인
   SHOW CONFIGURATION;

   [결과]
   Configuration - dg_orcl
     Protection Mode: MaxAvailability
     Members:
     orcl     - Primary database
     orclstby - Physical standby database
   Fast-Start Failover:  Disabled
   Configuration Status: SUCCESS
*/


/* ============================================================================
   5. Far Sync & Real-Time Cascade 아키텍처
   ============================================================================ */

/*
   Far Sync 개요

   구분              설명
   ----------------  ---------------------------------------------------------
   문제 상황         Primary–Standby 간 거리가 멀면 SYNC 전송 시 커밋 지연 발생
   Far Sync          Primary와 Standby 사이에 위치하는 중간 인스턴스
                     Redo 수신 후 Standby로 전달하는 역할
   역할              Primary 부하 없이 SYNC 전송 거리를 단축
                     Standby까지는 ASYNC로 전달
   Real-Time Cascade Far Sync가 수신한 Redo를 Standby로 실시간 전달하는 방식
   특징              Far Sync 인스턴스는 데이터파일 없음
                     Redo Log만 수신하고 전달하는 역할만 함

   전송 구조 (개념도)
   [Primary] --SYNC--> [Far Sync] --ASYNC--> [Standby]
             (근거리)              (원거리)
*/

/* Far Sync 인스턴스 명령어 레퍼런스 -------------------------------------------*/

/*
   -- [Far Sync 서버 — SYSDBA] Far Sync 인스턴스 생성 (데이터파일 없이 구성)
   CREATE CONTROLFILE REUSE SET DATABASE "orcl"
     LOGFILE GROUP 1 ('<경로>/farsync/redo01.log') SIZE 200M,
             GROUP 2 ('<경로>/farsync/redo02.log') SIZE 200M
     RESETLOGS
     NOARCHIVELOG
     MAXLOGFILES 32
     MAXLOGMEMBERS 2
     MAXDATAFILES 1
     MAXINSTANCES 1;
*/

/*
   -- [VM1 — DGMGRL] Far Sync 인스턴스 추가
   ADD FAR_SYNC farsync AS CONNECT IDENTIFIER IS farsync_tns;

   [결과]
   Far sync instance 'farsync' added

   -- RedoRoutes 설정: Primary → Far Sync(SYNC) → Standby(ASYNC)
   EDIT DATABASE orcl SET PROPERTY RedoRoutes = '(LOCAL : farsync SYNC)';
   EDIT FAR_SYNC farsync SET PROPERTY RedoRoutes = '(orcl : orclstby ASYNC)';

   [결과]
   Property "RedoRoutes" updated   (각 명령마다)

   -- Far Sync 활성화 및 구성 확인
   ENABLE FAR_SYNC farsync;
   SHOW CONFIGURATION;

   [결과 예시]
   Configuration - dg_orcl
     Members:
     orcl     - Primary database
     farsync  - Far sync instance
     orclstby - Physical standby database
   Configuration Status: SUCCESS
*/


/* ============================================================================
   6. FASTSYNC 모드
   ============================================================================ */

/*
   전송 모드 비교

   전송 모드              설명
   --------------------   -------------------------------------------------------
   SYNC + AFFIRM          Standby 디스크 기록 확인 후 Primary 커밋 완료
   SYNC + NOAFFIRM        FASTSYNC: Standby 수신 확인 후 커밋, 디스크 기록은 비동기
   ASYNC + NOAFFIRM       Primary 커밋과 무관하게 전송

   FASTSYNC 특성
   - SYNC + NOAFFIRM 조합으로 동작
   - SYNC의 커밋 순서 보장과 ASYNC의 성능을 절충한 중간 방식
   - Standby 디스크 기록을 기다리지 않으므로 극단적인 장애 시 최소한의 데이터 손실 가능
*/

/* ----------------------------------------------------------------------------
   6-1. FASTSYNC 설정
   ---------------------------------------------------------------------------- */

/*
   # [VM1 — DGMGRL]

   -- 현재 LogXptMode 확인
   SHOW DATABASE VERBOSE orclstby;

   -- Standby 전송 방식 FASTSYNC 적용
   EDIT DATABASE orclstby SET PROPERTY LogXptMode = 'FASTSYNC';

   [결과]
   Property "logxptmode" updated

   -- 설정 확인
   SHOW DATABASE VERBOSE orclstby;

   [결과 예시]
   ...
   LogXptMode = 'FASTSYNC'
   ...
*/


/* ============================================================================
   7. VALIDATE DATABASE 고급 옵션
   ============================================================================ */

/*
   VALIDATE DATABASE 고급 옵션 개요

   옵션              설명
   ----------------  -----------------------------------------------------------
   DATAFILE N        특정 데이터파일 단위로 Primary–Standby 블록 비교 (Lost Write 탐지)
   DATAFILE ALL      전체 데이터파일 대상 Lost Write 탐지
   SPFILE            Primary–Standby 간 SPFILE 파라미터 값 비교
   OUTPUT='파일명'   결과를 텍스트 파일로 저장

   활용: Switchover / Failover 전 가장 먼저 실행해야 하는 점검 명령
*/

/* ----------------------------------------------------------------------------
   7-1. VALIDATE DATABASE DATAFILE
   ---------------------------------------------------------------------------- */

/*
   # [VM1 — DGMGRL]

   -- 특정 데이터파일 Lost Write 탐지 (출력 파일 지정)
   VALIDATE DATABASE orclstby DATAFILE 1 OUTPUT='orclstby_dt01.txt';

   [결과 예시]
   File Name                : +DATA/orclstby/datafile/system.256.xxxxxxxx
   File Number              : 1
   Validation Results       : No errors found
   → 데이터파일 1번 블록 비교 완료, Lost Write 없음

   # [VM1 — oracle 계정] 결과 파일 확인
   cat $ORACLE_BASE/diag/rdbms/orcl/orcl/trace/orclstby_dt01.txt
*/

/* ----------------------------------------------------------------------------
   7-2. VALIDATE DATABASE SPFILE
   ---------------------------------------------------------------------------- */

/*
   # [VM1 — DGMGRL]

   -- SPFILE 파라미터 일치 여부 확인
   VALIDATE DATABASE orclstby SPFILE;

   [결과 예시]
   SPFILE Validation Results:
   Parameter             Primary Value   Standby Value   Result
   --------------------  --------------  --------------  -------
   db_unique_name        orcl            orclstby        OK
   log_archive_config    DG_CONFIG=(..   DG_CONFIG=(..   OK
   fal_server            orclstby_stati  orcl            OK
   → Result=OK     : 역할에 맞는 값 적용 확인
   → Result=MISMATCH: 값 불일치 → 파라미터 재검토 필요
*/


/* ============================================================================
   8. 역할 전환 시 Buffer Cache 유지
   ============================================================================ */

/*
   STANDBY_DB_PRESERVE_STATES 개요

   값        동작
   --------  ---------------------------------------------------------------
   NONE      기본값. 역할 전환 시 Buffer Cache 초기화
   SESSION   활성 세션의 Buffer Cache 유지 (세션이 없으면 NONE과 동일)
   ALL       전체 Buffer Cache 유지

   추가 버전: Oracle 18c 이상
   활용:      Switchover 직전까지 Standby에서 보고서 쿼리를 처리한 경우
              역할 전환 후에도 캐시된 블록을 재활용 → 워밍업 시간 단축
              Failover(비계획 전환)에도 적용됨
*/

/* ----------------------------------------------------------------------------
   8-1. STANDBY_DB_PRESERVE_STATES 설정
   ---------------------------------------------------------------------------- */

-- [VM3 — SYSDBA] 현재 값 확인
SHOW PARAMETER standby_db_preserve_states;

/*
 [결과]
   NAME                          TYPE    VALUE
   ----------------------------- ------- -----
   standby_db_preserve_states   string  NONE
   -> 기본값 NONE (전환 시 캐시 초기화)
*/

-- [VM3 — SYSDBA] Buffer Cache 유지 설정 (SPFILE 반영, 재기동 필요)
ALTER SYSTEM SET standby_db_preserve_states = ALL SCOPE=SPFILE;

/*
 [결과]
   System altered.
*/

-- [VM3 — SYSDBA] Standby DB 재기동 (설정 반영)
SHUTDOWN IMMEDIATE;

/*
 [결과]
   Oracle instance shut down.
*/

STARTUP MOUNT;

/*
 [결과]
   Oracle instance started.
   ...
   Database mounted.
*/

-- [VM3 — SYSDBA] 설정 확인
SHOW PARAMETER standby_db_preserve_states;

/*
 [결과]
   NAME                          TYPE    VALUE
   ----------------------------- ------- -----
   standby_db_preserve_states   string  ALL
   -> ALL 설정 확인 → Switchover / Failover 시 Buffer Cache 유지
*/

/* ----------------------------------------------------------------------------
   8-2. 전환 전·후 Buffer Cache 확인
   ---------------------------------------------------------------------------- */

-- [VM3 — SYSDBA] 전환 전: hr.employees 인덱스 블록을 Buffer Cache에 올림
ALTER DATABASE OPEN READ ONLY;

/*
 [결과]
   Database altered.
*/

SELECT COUNT(*) FROM hr.employees;

/*
 [결과]
   COUNT(*)
   --------
        107
*/

-- [VM3 — SYSDBA] 전환 전 캐시된 인덱스 블록 확인 (기준값으로 기억)
SELECT o.object_name, o.object_type, COUNT(*) AS cached_blocks
FROM   v$bh b
JOIN   dba_objects o ON b.objd = o.data_object_id
WHERE  o.owner = 'HR'
AND    o.object_name LIKE 'EMP%'
GROUP BY o.object_name, o.object_type;

/*
 [결과 예시]
   OBJECT_NAME                    OBJECT_TYPE             CACHED_BLOCKS
   ------------------------------ ----------------------- -------------
   EMP_EMAIL_UK                   INDEX                               1
   -> Switchover 전 캐시된 블록 수 확인 (이 수치를 기준값으로 기억)
*/

/*
   # [VM1 — DGMGRL] Switchover 실행
   SWITCHOVER TO orclstby;

   [결과]
   Succeeded. Switchover complete.
*/

-- [VM3 — SYSDBA] 전환 후 캐시된 인덱스 블록 재확인
-- PRIMARY로 승격된 VM3에서 확인
SELECT o.object_name, o.object_type, COUNT(*) AS cached_blocks
FROM   v$bh b
JOIN   dba_objects o ON b.objd = o.data_object_id
WHERE  o.owner = 'HR'
AND    o.object_name LIKE 'EMP%'
GROUP BY o.object_name, o.object_type;

/*
 [ALL 설정 시 이론상 결과]
   OBJECT_NAME                    OBJECT_TYPE             CACHED_BLOCKS
   ------------------------------ ----------------------- -------------
   EMP_EMAIL_UK                   INDEX                               1
   -> Switchover 전과 동일한 블록 수 → Buffer Cache 유지 확인

 [실제 동작 참고]
   -> Switchover 절차 중 내부적으로 shutdown이 발생하는 경우 캐시가 초기화될 수 있음
   -> 환경에 따라 실제 결과가 이론과 다를 수 있음

 [NONE 설정 시]
   no rows selected
   -> 전환 시 캐시 초기화됨
*/

/*
   # [VM3 — DGMGRL] 원래 구성으로 재전환
   SWITCHOVER TO orcl;

   [결과]
   Succeeded. Switchover complete.
*/


/* ============================================================================
   9. 행 식별 강제 부여 기법
   ============================================================================ */

/*
   PK 없는 테이블의 SQL Apply 문제

   상황           Logical Standby SQL Apply는 UPDATE / DELETE 대상 행 특정을 위해 PK 또는 UK 필요
   문제           PK / UK가 없는 테이블은 행 식별 불가 → SQL Apply가 DML을 건너뛰거나 오류 발생
   해결 방법 1    Primary 테이블에 PK 추가 (근본적 해결책)
   해결 방법 2    RELY DISABLE NOVALIDATE — 실제 제약 없이 SQL Apply에 행 식별 기준만 제공
*/

/* ----------------------------------------------------------------------------
   9-1. Physical → Logical Standby 전환 (복습)
   ---------------------------------------------------------------------------- */

-- [VM1 — SYSDBA] Primary에서 LogMiner 딕셔너리 빌드
EXECUTE DBMS_LOGSTDBY.BUILD;

/*
 [결과]
   PL/SQL procedure successfully completed.
*/

-- 딕셔너리 전송 유도 (로그 스위치 2회)
ALTER SYSTEM ARCHIVE LOG CURRENT;
ALTER SYSTEM ARCHIVE LOG CURRENT;

/*
 [결과]
   System altered. (각 명령마다)
*/

-- [VM3 — SYSDBA] MRP 중지 후 Physical → Logical 전환
ALTER DATABASE RECOVER MANAGED STANDBY DATABASE CANCEL;

/*
 [결과]
   Database altered.
*/

ALTER DATABASE RECOVER TO LOGICAL STANDBY orclstby;

/*
 [결과]
   Database altered.
   -> Physical → Logical Standby 전환됨

 [무한 대기 발생 시 트러블슈팅]

   1단계: Primary(VM1)에서 전송 에러 상태 확인
   SELECT dest_id, status, target, error
   FROM   v$archive_dest
   WHERE  target = 'STANDBY';

   STATUS=DEFERRED 시: Redo 전송 재시작 (DEFER → ENABLE)
   ALTER SYSTEM SET LOG_ARCHIVE_DEST_STATE_2 = 'DEFER'  SCOPE=BOTH;
   ALTER SYSTEM SET LOG_ARCHIVE_DEST_STATE_2 = 'ENABLE' SCOPE=BOTH;
   ALTER SYSTEM ARCHIVE LOG CURRENT;

   2단계: 네트워크·TNS 접속 점검 (OS 터미널)
   tnsping orclstby
   sqlplus sys/패스워드@orclstby as sysdba

   3단계: FAL 파라미터 확인
   SHOW PARAMETER FAL;
   -- FAL_SERVER: Primary를 가리키는 TNS Alias
   -- FAL_CLIENT: Standby 자신을 가리키는 TNS Alias
*/

-- [VM3 — SYSDBA] 재기동 및 SQL Apply 기동
SHUTDOWN IMMEDIATE;

/*
 [결과]
   Oracle instance shut down.
*/

STARTUP MOUNT;

/*
 [결과]
   Oracle instance started.
   ...
   Database mounted.
*/

ALTER DATABASE OPEN RESETLOGS;

/*
 [결과]
   Database altered.
   -> RESETLOGS로 새 Incarnation 시작
*/

ALTER DATABASE START LOGICAL STANDBY APPLY IMMEDIATE;

/*
 [결과]
   Database altered.
   -> SQL Apply 기동 완료
*/

/* ----------------------------------------------------------------------------
   9-2. PK 없는 테이블 생성 및 문제 확인
   ---------------------------------------------------------------------------- */

-- [VM1 — SYSDBA] PK 없는 테이블 생성 (구조와 데이터만 복사)
CREATE TABLE hr.job_history2 AS
SELECT * FROM hr.job_history;

/*
 [결과]
   Table created.
*/

-- 생성된 테이블에 PK가 없는지 확인
SELECT constraint_name, constraint_type
FROM   dba_constraints
WHERE  owner = 'HR'
AND    table_name = 'JOB_HISTORY2';

/*
 [결과]
   no rows selected
   -> 'P'(PRIMARY KEY) 또는 'U'(UNIQUE) 타입 제약 조건 없음 → PK 없는 테이블 확인
*/

-- [VM1 — SYSDBA] 테스트를 위한 타겟 데이터 삽입
INSERT INTO hr.job_history2 (employee_id, start_date, end_date, job_id, department_id)
VALUES (101, DATE '2000-01-01', DATE '2005-12-31', 'AC_ACCOUNT', 110);
COMMIT;

/*
 [결과]
   1 row created.
   Commit complete.
*/

-- [VM3 — Logical Standby, SYSDBA] PK / UK 없는 테이블 목록 확인
SELECT owner, table_name, bad_column
FROM   dba_logstdby_not_unique
ORDER BY owner, table_name;

/*
 [결과 예시]
   OWNER  TABLE_NAME     BAD_COLUMN
   -----  -------------  ----------
   HR     JOB_HISTORY2   N
   -> PK/UK 없음 → UPDATE/DELETE 시 SQL Apply 행 특정 불가
*/

/* ----------------------------------------------------------------------------
   9-3. RELY DISABLE PRIMARY KEY 추가 및 적용 확인
   ---------------------------------------------------------------------------- */

-- [VM1 — SYSDBA] RELY DISABLE PRIMARY KEY 추가
-- RELY      : SQL Apply에 행 식별 기준 정보 제공 (옵티마이저도 참조)
-- DISABLE   : 실제 제약 조건은 비활성 → INSERT 시 중복 허용
-- NOVALIDATE: 기존 데이터 검증 없이 추가
ALTER TABLE hr.job_history2
  ADD CONSTRAINT pk_job_history2 PRIMARY KEY (employee_id, start_date)
  RELY DISABLE NOVALIDATE;

/*
 [결과]
   Table altered.
*/

-- [VM1 — SYSDBA] 제약 조건 추가 확인
SELECT constraint_name, constraint_type, status, rely, validated
FROM   dba_constraints
WHERE  owner = 'HR'
AND    table_name = 'JOB_HISTORY2';

/*
 [결과]
   CONSTRAINT_NAME    C  STATUS    RELY  VALIDATED
   -----------------  -  --------  ----  ---------------
   PK_JOB_HISTORY2    P  DISABLED  RELY  NOT VALIDATED
   -> RELY=RELY, STATUS=DISABLED → 논리적 PK 정보만 제공, 실제 제약 미적용
*/

-- [VM1 — SYSDBA] 테스트 데이터 변경 (SQL Apply 행 식별 확인)
UPDATE hr.job_history2
SET    job_id = 'IT_PROG'
WHERE  employee_id = 101 AND start_date = DATE '2000-01-01';
COMMIT;

/*
 [결과]
   1 row updated.
   Commit complete.
*/

-- [VM3 — Logical Standby, SYSDBA] 변경 내역 반영 확인
SELECT job_id
FROM   hr.job_history2
WHERE  employee_id = 101 AND start_date = DATE '2000-01-01';

/*
 [결과]
   JOB_ID
   -------
   IT_PROG
   -> RELY DISABLE PK 추가 후 SQL Apply 행 식별 성공
   -> UPDATE 정상 적용 확인
*/

/*
   RELY DISABLE NOVALIDATE 주의사항

   항목          내용
   -----------   ---------------------------------------------------------------
   실제 제약      비활성 (DISABLE) → 중복 데이터 INSERT 시 오류 발생 안 함
   적용 기준      실제로 고유성이 보장되는 컬럼에만 적용해야 함
                 (실제 중복이 있으면 SQL Apply UPDATE/DELETE 오류 가능)
   근본 해결책    Primary 테이블에 PK를 정상 추가하는 것
   RELY DISABLE  즉시 PK 추가가 어려운 경우의 임시 방편으로만 사용
*/


/* ============================================================================
   10. 관련 뷰 & 명령어 정리
   ============================================================================ */

/*
   진단 뷰 정리

   뷰 / 패키지                    조회 목적
   ----------------------------   -------------------------------------------------
   DBMS_DBCOMP.DBCOMP             데이터파일 블록 단위 Lost Write 비교
   v$inmemory_area                IMCS 메모리 풀 할당 및 사용 현황
   dba_logstdby_not_unique        PK / UK 없는 테이블 목록 (SQL Apply 행 특정 불가)
   dba_constraints                RELY DISABLE 제약 조건 상태 확인

   ============================================================================ */

/* ============================================================================
   주요 명령어 정리
   ============================================================================

   명령어                                                                    설명
   ------------------------------------------------------------------------  -----------------------------------------------
   EXECUTE DBMS_DBCOMP.DBCOMP(파일번호, '출력경로')                          데이터파일 단위 Lost Write 검증
   EXECUTE DBMS_DBCOMP.DBCOMP('ALL', '출력경로')                             전체 데이터파일 Lost Write 검증
   ALTER SESSION SYNC WITH PRIMARY                                           Primary 최신 SCN 동기화 후 쿼리 실행 (ADG 세션)
   ALTER SYSTEM SET inmemory_size = N SCOPE=SPFILE                           IMCS 메모리 크기 설정 (재기동 필요)
   ALTER TABLE t INMEMORY                                                    테이블 IMCS 로딩 지정
   EXPORT CONFIGURATION TO '파일 이름'                                       Broker 구성 텍스트 파일로 Export
   IMPORT CONFIGURATION FROM '파일 이름'                                     Broker 구성 파일로부터 복원
   REMOVE CONFIGURATION                                                      기존 Broker 구성 제거
   ADD FAR_SYNC 이름 AS CONNECT IDENTIFIER IS TNS명                          Far Sync 인스턴스 추가
   EDIT DATABASE 이름 SET PROPERTY RedoRoutes = '...'                        Redo 전송 경로 설정
   ENABLE FAR_SYNC 이름                                                      Far Sync 활성화
   EDIT DATABASE 이름 SET PROPERTY LogXptMode = 'FASTSYNC'                   FASTSYNC 전송 모드 설정
   VALIDATE DATABASE 이름 DATAFILE N OUTPUT='파일명'                         특정 데이터파일 Lost Write 탐지
   VALIDATE DATABASE 이름 DATAFILE ALL                                       전체 데이터파일 Lost Write 탐지
   VALIDATE DATABASE 이름 SPFILE                                             Standby–Primary SPFILE 파라미터 비교
   ALTER SYSTEM SET standby_db_preserve_states = ALL SCOPE=SPFILE            역할 전환 시 Buffer Cache 유지 설정 (재기동 필요)
   ALTER TABLE t ADD CONSTRAINT pk PRIMARY KEY (...) RELY DISABLE NOVALIDATE SQL Apply 행 식별 기준 논리적 PK 부여

   ============================================================================ */

/* ============================================================================
   실습 핵심 요약
   ============================================================================

   주제                              핵심 포인트
   --------------------------------  --------------------------------------------------
   Lost Write 감지                   DBMS_DBCOMP.DBCOMP으로 Primary–Standby 블록 단위 비교
                                     'ALL' 인자 시 전체 파일 대상 / LWLOC=0이면 정상
   SYNC WITH PRIMARY                 ADG 세션에서 일회성 동기화 강제
                                     STANDBY_MAX_DATA_DELAY와 달리 단발성, 대기 발생 가능
   GTT ON COMMIT DELETE ROWS         커밋 시점에 세션 데이터 즉시 삭제
                                     ADG 읽기 세션에서 임시 집계 용도로 활용
   inmemory_size                     0이 아닌 값으로 설정 시 IMCS 활성화 / 재기동 필요
                                     Standby 독립 설정 가능, Primary에 영향 없음
   Broker Export / Import            구성 파일 손상·재구성 시 활용
                                     Import 후 ENABLE CONFIGURATION 별도 실행 필요
   Far Sync                          Primary 근거리에 SYNC / Standby 원거리에 ASYNC
                                     중간 인스턴스에 데이터파일 없음
   Real-Time Cascade                 Far Sync → Standby 실시간 전달 / RedoRoutes로 경로 명시
   FASTSYNC                          SYNC + NOAFFIRM / 수신 확인 후 커밋, 디스크 기록은 비동기
                                     성능·안전성 절충 방식
   VALIDATE DATAFILE                 데이터파일 단위 Lost Write 탐지 / Switchover 전 점검 필수
   VALIDATE SPFILE                   Primary–Standby 파라미터 비교 / MISMATCH 항목 사전 수정
   STANDBY_DB_PRESERVE_STATES        Oracle 18c+ / ALL 설정 시 역할 전환 후 Buffer Cache 유지
                                     워밍업 시간 단축 / Failover에도 적용
   RELY DISABLE PK                   PK 없는 테이블에 SQL Apply 행 식별 기준 부여
                                     실제 제약 미적용 / 실제 PK 추가가 근본 해결책

   ============================================================================ */
