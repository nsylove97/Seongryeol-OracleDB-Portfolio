/*
================================================================================
 ASM 실습 04: 파일 관리 & 템플릿 & 고급 기능
================================================================================
 블로그: https://nsylove97.tistory.com/44
 GitHub: https://github.com/nsylove97/NSY-DB-Portfolio

 실습 환경
   - OS            : Oracle Linux 7.9 (VMware Virtual Machine)
   - DB            : Oracle Database 19c (Grid Infrastructure + DB)
   - Tool          : SQL*Plus, MobaXterm(SSH)
   - Grid HOME     : /u01/app/19.3.0/gridhome
   - DB HOME       : /u01/app/oracle/product/19.3.0/dbhome

 목차
   1. ASM 파일 이름 형식
      1-1. Fully Qualified Name 구조 확인
   2. Alias 생성 실습
      2-1. 데이터파일 경로 확인
      2-2. Alias 생성 및 확인
      2-3. Alias 삭제
   3. Template 실습
      3-1. 기본 Template 조회
      3-2. 사용자 정의 Template 생성
      3-3. Template 수정
      3-4. Template 삭제
   4. 단일 파일 생성 실습
      4-1. 기본 Template으로 테이블스페이스 생성
      4-2. 커스텀 Template 지정하여 테이블스페이스 생성
      4-3. 실습 후 정리
   5. DBMS_FILE_TRANSFER.COPY_FILE — OS → ASM 파일 복사
      5-1. Directory 객체 생성
      5-2. 파일 복사 실습 (RMAN으로 원본 생성 → DBMS_FILE_TRANSFER로 ASM 복사)
      5-3. 복사 결과 확인
   6. ASMCMD cp 실습
      6-1. ASM → ASM 복사
      6-2. OS → ASM 복사
      6-3. ASM → OS 복사
   7. ASM Fast Mirror Resync
      7-1. DISK_REPAIR_TIME 확인
      7-2. DISK_REPAIR_TIME 변경
   8. Preferred Read Failure Groups (PRFG) — 개념
   9. ASM IDP — 개념
  10. RMAN을 활용한 ASM 데이터파일 백업
      10-1. 전체 DB 백업
      10-2. 특정 테이블스페이스 백업
      10-3. 백업 목록 확인
  11. 관련 뷰 정리
      11-1. v$asm_template
      11-2. v$asm_alias
      11-3. v$asm_file
================================================================================
*/


/* ============================================================================
   1. ASM 파일 이름 형식
   ============================================================================
   ASM 파일 이름은 세 가지 형식으로 표현됨

   형식                  예시                                      설명
   ------------------    ----------------------------------------  ----------------------------
   Fully Qualified Name  +DATA/ORCL/DATAFILE/system.257.xxx        ASM이 자동 부여하는 완전한 경로
                                                                    그룹 + DB_UNIQUE_NAME + 타입 + 번호.버전
   Alias Name            +DATA/ORCL/DATAFILE/system01.dbf          사람이 읽기 쉬운 별명
                                                                    파일을 복제하지 않고 참조만 제공
   Incomplete Name       +DATA                                      그룹명만 지정
                                                                    OMF 환경에서 사용, 나머지 자동 결정

   Fully Qualified Name 구조
     +<디스크그룹>/<DB_UNIQUE_NAME>/<파일타입>/<파일명>.<파일번호>.<버전>
     예시: +DATA/ORCL/DATAFILE/system.257.1228856123

   ※ 경로에 오는 것은 db_name이 아닌 db_unique_name
      Data Guard 환경에서 Primary와 Standby의 db_name은 같지만 db_unique_name은 달라야 함
      ASM이 둘을 구분하기 위해 db_unique_name을 경로에 사용
   ============================================================================ */

/* --------------------------------------------------------------------------
   1-1. Fully Qualified Name 구조 확인
   -------------------------------------------------------------------------- */

-- [oracle 계정] SYSDBA로 접속
CONN / AS SYSDBA

-- 현재 DB의 db_unique_name 확인
SELECT name, db_unique_name FROM v$database;

/*
 [결과]
   NAME  DB_UNIQUE_NAME
   ----  --------------
   ORCL  orcl
   → db_unique_name = orcl → ASM 경로에 ORCL로 표시됨
*/


/* ============================================================================
   2. Alias 생성 실습
   ============================================================================
   - Alias는 길고 복잡한 Fully Qualified Name에 사람이 읽기 쉬운 별명을 붙이는 기능
   - 파일을 복제하거나 이동하지 않고 참조 경로만 추가
   ============================================================================ */

/* --------------------------------------------------------------------------
   2-1. 데이터파일 경로 확인
   -------------------------------------------------------------------------- */

CONN / AS SYSDBA

-- 현재 +DATA 그룹의 데이터파일 경로 확인
SELECT file#, name
FROM   v$datafile
WHERE  name LIKE '+DATA%'
ORDER  BY file#
FETCH FIRST 5 ROWS ONLY;

/*
 [결과]
   FILE#  NAME
   -----  ---------------------------------------------------
   1      +DATA/ORCL/DATAFILE/system.257.1228841471
   2      +DATA/ORCL/DATAFILE/sysaux.258.1228841472
   3      +DATA/ORCL/DATAFILE/undotbs1.259.1228841473
   4      +DATA/ORCL/DATAFILE/users.260.1228841511
*/


/* --------------------------------------------------------------------------
   2-2. Alias 생성 및 확인
   -------------------------------------------------------------------------- */

CONN / AS SYSASM

-- Alias 생성 — Fully Qualified Name에 읽기 쉬운 별명 부여
-- OMF 환경 주의: FOR 절의 경로 앞에 공백이 들어가면 ORA-15052 발생
ALTER DISKGROUP DATA
    ADD ALIAS '+DATA/ORCL/DATAFILE/system01.dbf'
    FOR '+DATA/ORCL/DATAFILE/system.257.1228841471';

/*
 [결과]
   Diskgroup altered.
*/

-- Alias 생성 결과 확인 — v$asm_alias
SELECT name, file_number, alias_index, system_created
FROM   v$asm_alias
WHERE  group_number = (SELECT group_number FROM v$asm_diskgroup WHERE name = 'DATA')
AND    name = 'system01.dbf';

/*
 [결과]
   NAME          FILE_NUMBER  ALIAS_INDEX  SYSTEM_CREATED
   ------------  -----------  -----------  --------------
   system01.dbf  257          272          N
   → SYSTEM_CREATED=N : 사용자가 직접 생성한 Alias 확인
*/

-- ASMCMD에서도 확인 가능 (OS 터미널 — grid 계정)
-- ASMCMD> ls +DATA/ORCL/DATAFILE/

/*
 [결과]
   SYSAUX.258.xxx
   SYSTEM.257.xxx
   system01.dbf       ← Alias — 파일이 2개가 아니라 같은 파일을 가리키는 참조
   UNDOTBS1.259.xxx
   USERS.260.xxx
   → ls에 두 개가 보여도 실제 파일은 하나, Alias는 참조만 제공
*/


/* --------------------------------------------------------------------------
   2-3. Alias 삭제
   -------------------------------------------------------------------------- */

ALTER DISKGROUP DATA
    DROP ALIAS '+DATA/ORCL/DATAFILE/system01.dbf';

/*
 [결과]
   Diskgroup altered.
*/


/* ============================================================================
   3. Template 실습
   ============================================================================
   - Template: ASM에서 파일을 생성할 때 자동으로 적용되는 파일 생성 규칙 세트
   - 파일 타입마다 기본 Template이 미리 정의되어 있으며, 사용자 추가 가능

   REDUNDANCY 속성
     MIRROR      : NORMAL Redundancy 기준 2중 미러링
     HIGH        : 3중 미러링 (CONTROLFILE 기본값)
     UNPROTECTED : 미러링 없음

   STRIPE 속성
     COARSE : 1MB AU 단위 스트라이핑 (대부분의 파일)
     FINE   : 128KB 단위 스트라이핑 (CONTROLFILE, ONLINELOG)
   ============================================================================ */

/* --------------------------------------------------------------------------
   3-1. 기본 Template 조회
   -------------------------------------------------------------------------- */

CONN / AS SYSASM

-- v$asm_template으로 현재 디스크 그룹의 Template 목록 확인
SELECT dg.name AS diskgroup, t.name, t.redundancy, t.stripe
FROM   v$asm_diskgroup dg
       JOIN v$asm_template t ON dg.group_number = t.group_number
WHERE  dg.name = 'DATA'
ORDER  BY t.name;

/*
 [결과]
   DISKGROUP  NAME              REDUNDANCY  STRIPE
   ---------  ----------------  ----------  ------
   DATA       ARCHIVELOG        MIRROR      COARSE
   DATA       ASMPARAMETERFILE  MIRROR      COARSE
   DATA       BACKUPSET         MIRROR      COARSE
   DATA       CONTROLFILE       HIGH        FINE
   DATA       DATAFILE          MIRROR      COARSE
   DATA       ONLINELOG         MIRROR      FINE
   DATA       PARAMETERFILE     MIRROR      COARSE
   DATA       TEMPFILE          MIRROR      COARSE
   ...
   → 파일 타입별로 Redundancy와 Striping이 미리 정의됨
   → CONTROLFILE만 HIGH Redundancy (3중 미러링) 적용
*/

-- ASMCMD lstmpl로도 확인 가능 (OS 터미널 — grid 계정)
-- ASMCMD> lstmpl -l DATA

/*
 [결과]
   Group_Name  Name            Stripe   Redundancy  System
   ----------  --------------  -------  ----------  ------
   DATA        ARCHIVELOG      COARSE   MIRROR      Y
   DATA        CONTROLFILE     FINE     HIGH        Y
   DATA        DATAFILE        COARSE   MIRROR      Y
   DATA        ONLINELOG       FINE     MIRROR      Y
   ...
   → System=Y : 시스템 기본 Template
*/


/* --------------------------------------------------------------------------
   3-2. 사용자 정의 Template 생성
   -------------------------------------------------------------------------- */

-- +DATA 그룹에 커스텀 Template 추가 (MIRROR Redundancy + FINE Striping)
ALTER DISKGROUP DATA
    ADD TEMPLATE my_custom_tmpl
    ATTRIBUTES (MIRROR FINE);

/*
 [결과]
   Diskgroup altered.
*/

-- 생성 확인
SELECT dg.name AS diskgroup, t.name, t.redundancy, t.stripe, t.system
FROM   v$asm_diskgroup dg
       JOIN v$asm_template t ON dg.group_number = t.group_number
WHERE  dg.name = 'DATA'
AND    t.name = 'MY_CUSTOM_TMPL';

/*
 [결과]
   DISKGROUP  NAME            REDUNDANCY  STRIPE  SYSTEM
   ---------  --------------  ----------  ------  ------
   DATA       MY_CUSTOM_TMPL  MIRROR      FINE    N
   → SYSTEM=N : 사용자가 직접 생성한 Template 확인
*/


/* --------------------------------------------------------------------------
   3-3. Template 수정
   -------------------------------------------------------------------------- */

-- Template 속성 변경 (FINE → COARSE)
ALTER DISKGROUP DATA
    MODIFY TEMPLATE my_custom_tmpl
    ATTRIBUTES (MIRROR COARSE);

/*
 [결과]
   Diskgroup altered.
*/

-- 수정 확인
SELECT dg.name AS diskgroup, t.name, t.redundancy, t.stripe
FROM   v$asm_diskgroup dg
       JOIN v$asm_template t ON dg.group_number = t.group_number
WHERE  dg.name = 'DATA'
AND    t.name = 'MY_CUSTOM_TMPL';

/*
 [결과]
   DISKGROUP  NAME            REDUNDANCY  STRIPE
   ---------  --------------  ----------  ------
   DATA       MY_CUSTOM_TMPL  MIRROR      COARSE
   → FINE → COARSE로 변경 확인
*/


/* --------------------------------------------------------------------------
   3-4. Template 삭제
   -------------------------------------------------------------------------- */

ALTER DISKGROUP DATA DROP TEMPLATE my_custom_tmpl;

/*
 [결과]
   Diskgroup altered.
*/

-- 삭제 확인
SELECT dg.name AS diskgroup, t.name
FROM   v$asm_diskgroup dg
       JOIN v$asm_template t ON dg.group_number = t.group_number
WHERE  dg.name = 'DATA'
AND    t.name = 'MY_CUSTOM_TMPL';

/*
 [결과]
   no rows selected
   → my_custom_tmpl 삭제 완료

 ※ Redundancy 제약
    EXTERNAL Redundancy 디스크 그룹에서는 MIRROR 속성 부여 불가
    NORMAL/HIGH Redundancy 그룹에서는 UNPROTECTED 속성 부여 가능
*/


/* ============================================================================
   4. 단일 파일 생성 실습
   ============================================================================
   - ASM 디스크 그룹에 파일을 직접 생성할 때 Template을 지정하거나 기본값 사용
   ============================================================================ */

/* --------------------------------------------------------------------------
   4-1. 기본 Template으로 테이블스페이스 생성
   -------------------------------------------------------------------------- */

CONN / AS SYSDBA

-- OMF 적용 상태 — 경로만 지정하면 파일 타입에 맞는 Template이 자동 적용
CREATE TABLESPACE tbs_test
    DATAFILE '+DATA' SIZE 10M AUTOEXTEND OFF;

/*
 [결과]
   Tablespace created.
   → DATAFILE Template(MIRROR/COARSE)이 자동 적용됨
*/

-- 파일 번호 확인 (이후 v$asm_file 조회에 사용)
SELECT file_id, file_name, tablespace_name
FROM   dba_data_files
WHERE  tablespace_name = 'TBS_TEST';

/*
 [결과]
   FILE_ID  FILE_NAME                                    TABLESPACE_NAME
   -------  -------------------------------------------  ---------------
   8        +DATA/ORCL/DATAFILE/tbs_test.267.1230135847  TBS_TEST
   → file_number = 267 (OMF가 자동 부여한 파일명에서 확인)
*/

-- Template 속성 확인 (file_name에서 확인한 file_number로 조회)
SELECT file_number, type, redundancy, striped
FROM   v$asm_file
WHERE  group_number = (SELECT group_number FROM v$asm_diskgroup WHERE name = 'DATA')
AND    file_number = 267;

/*
 [결과]
   FILE_NUMBER  TYPE      REDUNDANCY  STRIPED
   -----------  --------  ----------  -------
   267          DATAFILE  MIRROR      COARSE
   → DATAFILE 기본 Template(MIRROR/COARSE) 적용 확인
*/


/* --------------------------------------------------------------------------
   4-2. 커스텀 Template 지정하여 테이블스페이스 생성
   -------------------------------------------------------------------------- */

-- 사전 준비: 커스텀 Template 생성
CONN / AS SYSASM
ALTER DISKGROUP DATA ADD TEMPLATE my_data_tmpl ATTRIBUTES (MIRROR FINE);

/*
 [결과]
   Diskgroup altered.
*/

-- Template을 명시적으로 지정하여 데이터파일 생성
CONN / AS SYSDBA
CREATE TABLESPACE tbs_tmpl
    DATAFILE '+DATA(my_data_tmpl)' SIZE 10M AUTOEXTEND OFF;

/*
 [결과]
   Tablespace created.
   → my_data_tmpl(MIRROR/FINE) 속성으로 데이터파일 생성됨
*/

-- 파일 번호 확인
SELECT file_id, file_name, tablespace_name
FROM   dba_data_files
WHERE  tablespace_name = 'TBS_TMPL';

/*
 [결과]
   FILE_ID  FILE_NAME                                    TABLESPACE_NAME
   -------  -------------------------------------------  ---------------
   9        +DATA/ORCL/DATAFILE/tbs_tmpl.270.1230135900  TBS_TMPL
   → file_number = 270
*/

-- 가장 최근에 생성된 파일의 Template 속성 확인
SELECT file_number, type, redundancy, striped
FROM   v$asm_file
WHERE  group_number = (SELECT group_number FROM v$asm_diskgroup WHERE name = 'DATA')
AND    file_number = 270;

/*
 [결과]
   FILE_NUMBER  TYPE      REDUNDANCY  STRIPED
   -----------  --------  ----------  -------
   270          DATAFILE  MIRROR      FINE
   → my_data_tmpl(MIRROR/FINE) 속성 적용 확인
*/


/* --------------------------------------------------------------------------
   4-3. 실습 후 정리
   -------------------------------------------------------------------------- */

CONN / AS SYSDBA

DROP TABLESPACE tbs_test INCLUDING CONTENTS AND DATAFILES;
DROP TABLESPACE tbs_tmpl INCLUDING CONTENTS AND DATAFILES;

/*
 [결과]
   Tablespace dropped.
   Tablespace dropped.
*/

CONN / AS SYSASM
ALTER DISKGROUP DATA DROP TEMPLATE my_data_tmpl;

/*
 [결과]
   Diskgroup altered.
*/


/* ============================================================================
   5. DBMS_FILE_TRANSFER.COPY_FILE — OS → ASM 파일 복사
   ============================================================================
   - OS 파일 시스템과 ASM 디스크 그룹 사이에서 파일을 복사·전송하는 PL/SQL 패키지
   - COPY_FILE : 로컬 파일 시스템 ↔ ASM 간 파일 복사
   - GET_FILE  : 원격 DB에서 로컬로 파일 가져오기
   - PUT_FILE  : 로컬 파일을 원격 DB로 보내기
   ============================================================================ */

/* --------------------------------------------------------------------------
   5-1. Directory 객체 생성
   -------------------------------------------------------------------------- */

CONN / AS SYSDBA

-- OS 경로를 DB가 인식할 수 있도록 Directory 객체 생성
-- 원본: OS 파일 시스템 경로
CREATE OR REPLACE DIRECTORY os_dir AS '/home/oracle';

-- 목적지: ASM 디스크 그룹 경로
CREATE OR REPLACE DIRECTORY asm_dir AS '+DATA/ORCL/DATAFILE';

/*
 [결과]
   Directory created.
   Directory created.
*/

-- 생성된 Directory 확인
SELECT directory_name, directory_path
FROM   dba_directories
WHERE  directory_name IN ('OS_DIR', 'ASM_DIR');

/*
 [결과]
   DIRECTORY_NAME  DIRECTORY_PATH
   --------------  --------------------------
   ASM_DIR         +DATA/ORCL/DATAFILE
   OS_DIR          /home/oracle
*/


/* --------------------------------------------------------------------------
   5-2. 파일 복사 실습 — RMAN으로 원본 생성 후 DBMS_FILE_TRANSFER로 ASM 복사
   --------------------------------------------------------------------------
   ※ OS 상에 tbs_backup.dbf가 없으면 ORA-19505 발생
   ※ RMAN으로 ASM → OS 먼저 복사하여 원본 파일을 생성한 뒤 진행
   -------------------------------------------------------------------------- */

-- STEP 1: RMAN으로 ASM → OS 복사 (OS 터미널 — oracle 계정)
-- rman target /

/*
   RMAN> COPY DATAFILE '+DATA/ORCL/DATAFILE/users.260.1228841511'
           TO '/home/oracle/tbs_backup.dbf';

 [결과]
   Starting backup at 09-APR-26
   channel ORA_DISK_1: starting datafile copy
   input datafile file number=00004 name=+DATA/ORCL/DATAFILE/users.260.1228841511
   output file name=/home/oracle/tbs_backup.dbf
   channel ORA_DISK_1: datafile copy complete
   Finished backup at 09-APR-26
   → /home/oracle/tbs_backup.dbf 생성 완료
*/

-- STEP 2: OS 파일 시스템의 파일을 ASM으로 복사
BEGIN
    DBMS_FILE_TRANSFER.COPY_FILE(
        source_directory_object      => 'OS_DIR',
        source_file_name             => 'tbs_backup.dbf',
        destination_directory_object => 'ASM_DIR',
        destination_file_name        => 'tbs_backup_asm.dbf'
    );
END;
/

/*
 [결과]
   PL/SQL procedure successfully completed.
   → /home/oracle/tbs_backup.dbf → +DATA/ORCL/DATAFILE/tbs_backup_asm.dbf 복사 완료
*/


/* --------------------------------------------------------------------------
   5-3. 복사 결과 확인
   -------------------------------------------------------------------------- */

-- v$asm_alias로 복사된 파일 확인
SELECT name FROM v$asm_alias
WHERE  group_number = (SELECT group_number FROM v$asm_diskgroup WHERE name = 'DATA')
AND    name = 'tbs_backup_asm.dbf';

/*
 [결과]
   NAME
   ------------------
   tbs_backup_asm.dbf
   → ASM에 파일 복사 완료 확인
*/


/* ============================================================================
   6. ASMCMD cp 실습
   ============================================================================
   - ASMCMD cp는 ASM 내부 파일 복사뿐 아니라 OS 파일 시스템 ↔ ASM 간 복사도 지원
   - OMF 환경 주의: 목적지에 OMF 형식 이름(.xxx.xxx)을 그대로 쓰면
     ASMCMD-8016 / ORA-15046 오류 발생
     → 반드시 일반 파일명(.dbf)이나 존재하는 디렉토리 경로 지정
   ============================================================================ */

/* --------------------------------------------------------------------------
   6-1. ASM → ASM 복사
   --------------------------------------------------------------------------
   ※ 목적지 경로(+FRA/ORCL/DATAFILE/)가 존재하지 않으면 ORA-15173 발생
   ※ +FRA 안에 실제 존재하는 경로(ls +FRA/ORCL/ 로 확인)에 복사해야 함
   -------------------------------------------------------------------------- */

-- ASMCMD> cp +DATA/ORCL/DATAFILE/users.260.1228841511 +FRA/ORCL/users_bak.dbf

/*
 [결과]
   copying +DATA/ORCL/DATAFILE/users.260.1228841511 -> +FRA/ORCL/users_bak.dbf

 -- 복사 확인
 ASMCMD> ls +FRA/ORCL/

 [결과]
   ARCHIVELOG/
   AUTOBACKUP/
   users_bak.dbf
*/


/* --------------------------------------------------------------------------
   6-2. OS → ASM 복사
   --------------------------------------------------------------------------
   ※ grid 계정이 OS 파일에 접근할 수 있도록 사전 권한 설정 필요
   -------------------------------------------------------------------------- */

-- 사전 준비: OS 권한 설정 (root 계정에서 실행)
-- cp /home/oracle/tbs_backup.dbf /tmp/
-- chown grid:asmadmin /tmp/tbs_backup.dbf
-- chmod 660 /tmp/tbs_backup.dbf

-- ASMCMD> cp /tmp/tbs_backup.dbf +DATA/tbs_backup.dbf

/*
 [결과]
   copying /tmp/tbs_backup.dbf -> +DATA/tbs_backup.dbf
*/

-- 복사 확인
-- ASMCMD> ls +DATA/

/*
 [결과]
   ...
   tbs_backup.dbf
   → +DATA 루트에 복사 완료 확인
*/


/* --------------------------------------------------------------------------
   6-3. ASM → OS 복사
   -------------------------------------------------------------------------- */

-- ASMCMD> cp +DATA/ORCL/DATAFILE/users.260.1228841511 /tmp/users_export.dbf

/*
 [결과]
   copying +DATA/ORCL/DATAFILE/users.260.1228841511 -> /tmp/users_export.dbf
*/

-- 복사 확인 (OS 터미널)
-- ls -l /tmp/users_export.dbf

/*
 [결과]
   -rw-r--r-- 1 grid oinstall 10485760 Apr 09 17:30 /tmp/users_export.dbf
   → /tmp에 파일 복사 완료 확인
*/


/* ============================================================================
   7. ASM Fast Mirror Resync
   ============================================================================
   - 일시적인 디스크 장애 후 전체 리밸런스 없이 변경된 부분만 빠르게 재동기화
   - DISK_REPAIR_TIME 안에 디스크가 복구되면 Fast Resync 적용
   - 시간 초과 시 ASM이 해당 디스크를 FORMER 처리 후 전체 리밸런스 수행

   동작 흐름
     1. 미러링 상태      : 데이터가 여러 디스크에 미러링
     2. 디스크 장애      : ASM이 OFFLINE 처리, 미러 디스크로 서비스 계속
     3. 변경 추적        : 장애 중 변경된 Extent를 ASM이 내부적으로 기록
     4. 디스크 복구      : DISK_REPAIR_TIME 안에 복구 → 변경분만 재동기화
     5. 전체 리밸런스 생략: 변경분만 복사하므로 일반 리밸런스보다 훨씬 빠름
   ============================================================================ */

/* --------------------------------------------------------------------------
   7-1. DISK_REPAIR_TIME 확인
   -------------------------------------------------------------------------- */

CONN / AS SYSASM

SELECT dg.name, attr.name, attr.value
FROM   v$asm_diskgroup dg
       JOIN v$asm_attribute attr ON dg.group_number = attr.group_number
WHERE  attr.name = 'disk_repair_time'
ORDER  BY dg.name;

/*
 [결과]
   NAME   NAME               VALUE
   -----  -----------------  -----
   DATA   disk_repair_time   12.0H
   FRA    disk_repair_time   12.0H
   OCR    disk_repair_time   12.0H
   REDO   disk_repair_time   12.0H
   → 이전 실습(ASM 실습 03)에서 12H로 변경된 상태
*/


/* --------------------------------------------------------------------------
   7-2. DISK_REPAIR_TIME 변경
   -------------------------------------------------------------------------- */

-- DISK_REPAIR_TIME을 8시간으로 변경
ALTER DISKGROUP DATA SET ATTRIBUTE 'disk_repair_time' = '8H';

/*
 [결과]
   Diskgroup altered.
*/

-- 변경 후 확인
SELECT dg.name, attr.name, attr.value
FROM   v$asm_diskgroup dg
       JOIN v$asm_attribute attr ON dg.group_number = attr.group_number
WHERE  dg.name = 'DATA'
AND    attr.name = 'disk_repair_time';

/*
 [결과]
   NAME   NAME               VALUE
   -----  -----------------  -----
   DATA   disk_repair_time   8.0H
   → 8시간으로 변경 완료
*/


/* ============================================================================
   8. Preferred Read Failure Groups (PRFG) — 개념
   ============================================================================
   - 미러링된 데이터 중에서 가장 가까운(로컬) 디스크 그룹을 우선적으로 읽도록 설정
   - 주로 Extended RAC(사이트 간 분산 RAC) 환경에서 네트워크 I/O를 줄이는 데 활용
   - 단일 노드 환경에서는 효과 없음

   배치 원칙 — 사이트별 Failure Group 구성
     2 사이트 + NORMAL : Site A FG 1개 / Site B FG 1개 → 각 사이트 복사본 1개
     2 사이트 + HIGH   : Site A FG 2개 / Site B FG 2개 → 복사본 3개 중 사이트별 최소 1개 보장
     3 사이트 + HIGH   : Site A/B/C 각 FG 1개 → 한 사이트 전체 장애 시에도 서비스 유지
   ============================================================================ */

-- PREFERRED_READ 파라미터로 로컬 Failure Group 지정 (RAC 환경, 각 노드별 설정)
-- ALTER SYSTEM SET ASM_PREFERRED_READ_FAILURE_GROUPS = 'DATA.DATA_0000' SCOPE=BOTH;

/*
 [결과]
   System altered.
   → DATA 디스크 그룹의 DATA_0000 Failure Group을 우선 읽기 대상으로 지정
   → RAC 환경에서 노드마다 가까운 Failure Group을 각각 지정해야 효과 있음
*/


/* ============================================================================
   9. ASM IDP (Intelligent Data Placement) — 개념
   ============================================================================
   - 파일의 사용 빈도(Hot/Cold)에 따라 디스크 내 빠른 영역(외곽)과
     느린 영역(내부)에 데이터를 자동 배치하는 기능
   - 이미 저장된 데이터는 IDP 설정 변경 즉시 이동하지 않고 리밸런스 시점에 일괄 재배치
   - HDD 환경에서 유효, SSD/NVMe 환경에서는 효과 미미

   Hot Region : 자주 접근되는 데이터 → 디스크의 빠른 영역(외곽 트랙) 배치
   Cold Region: 거의 사용하지 않는 데이터 → 디스크의 느린 영역(내부 트랙) 배치

   관련 뷰
     V$ASM_FILE          : 파일 단위 I/O 통계 — IDP 판단의 기본 자료
     V$ASM_DISK          : 디스크 단위 통계 — Hot/Cold 역할 확인
     V$ASM_DISK_STAT     : 디스크 통계 집계 뷰 — 운영·진단용
     V$FILEMETRIC        : 파일 단위 I/O 변화 추적
     V$FILEMETRIC_HISTORY: Hot/Cold 이동 효과 이력 확인
   ============================================================================ */


/* ============================================================================
  10. RMAN을 활용한 ASM 데이터파일 백업
   ============================================================================
   - ASM에 저장된 데이터파일도 RMAN으로 직접 백업 가능
   - ASM 경로를 그대로 지정하면 RMAN이 ASM을 통해 읽음
   - 별도 설정 없이 동작
   ============================================================================ */

/* --------------------------------------------------------------------------
   10-1. 전체 DB 백업
   --------------------------------------------------------------------------
   ※ OS 터미널에서 실행 (oracle 계정)
   -------------------------------------------------------------------------- */

-- rman target /

/*
   RMAN> BACKUP DATABASE PLUS ARCHIVELOG;

 [결과]
   Starting backup at 09-APR-26
   ...
   channel ORA_DISK_1: starting full datafile backup set
   channel ORA_DISK_1: input datafile file number=00001 name=+DATA/ORCL/DATAFILE/system.257.xxx
   channel ORA_DISK_1: input datafile file number=00002 name=+DATA/ORCL/DATAFILE/sysaux.258.xxx
   channel ORA_DISK_1: input datafile file number=00003 name=+DATA/ORCL/DATAFILE/undotbs1.259.xxx
   channel ORA_DISK_1: input datafile file number=00004 name=+DATA/ORCL/DATAFILE/users.260.xxx
   channel ORA_DISK_1: backup set complete
   Finished backup at 09-APR-26
   → ASM 경로의 데이터파일을 그대로 읽어 +FRA(백업 목적지)에 저장
*/


/* --------------------------------------------------------------------------
   10-2. 특정 테이블스페이스 백업
   -------------------------------------------------------------------------- */

/*
   RMAN> BACKUP TABLESPACE users;

 [결과]
   Starting backup at 09-APR-26
   channel ORA_DISK_1: starting full datafile backup set
   channel ORA_DISK_1: input datafile file number=00004 name=+DATA/ORCL/DATAFILE/users.260.xxx
   channel ORA_DISK_1: backup set complete
   Finished backup at 09-APR-26
*/


/* --------------------------------------------------------------------------
   10-3. 백업 목록 확인
   -------------------------------------------------------------------------- */

/*
   RMAN> LIST BACKUP SUMMARY;

 [결과]
   List of Backups
   ===============
   Key     TY LV S Device Type Completion Time     #Pieces #Copies Compressed Tag
   ------- -- -- - ----------- ------------------- ------- ------- ---------- ---
   1       B  F  A DISK        09-APR-26           1       1       NO         TAG...
   2       B  F  A DISK        09-APR-26           1       1       NO         TAG...
   → ASM 경로의 데이터파일 백업 정상 완료 확인
*/


/* ============================================================================
  11. 관련 뷰 정리
   ============================================================================ */

/* --------------------------------------------------------------------------
   11-1. v$asm_template
   -------------------------------------------------------------------------- */

CONN / AS SYSASM

-- 디스크 그룹별 Template 목록 및 속성 확인 (기본 → 사용자 정의 순)
SELECT dg.name AS diskgroup, t.name, t.redundancy, t.stripe, t.system
FROM   v$asm_diskgroup dg
       JOIN v$asm_template t ON dg.group_number = t.group_number
WHERE  dg.name = 'DATA'
ORDER  BY t.system DESC, t.name;

/*
 [결과]
   DISKGROUP  NAME              REDUNDANCY  STRIPE  SYSTEM
   ---------  ----------------  ----------  ------  ------
   DATA       ARCHIVELOG        MIRROR      COARSE  Y
   DATA       ASMPARAMETERFILE  MIRROR      COARSE  Y
   DATA       BACKUPSET         MIRROR      COARSE  Y
   DATA       CONTROLFILE       HIGH        FINE    Y
   DATA       DATAFILE          MIRROR      COARSE  Y
   DATA       ONLINELOG         MIRROR      FINE    Y
   DATA       PARAMETERFILE     MIRROR      COARSE  Y
   DATA       TEMPFILE          MIRROR      COARSE  Y
   ...
   → SYSTEM=Y: 기본 Template / SYSTEM=N: 사용자 정의 Template
*/


/* --------------------------------------------------------------------------
   11-2. v$asm_alias
   -------------------------------------------------------------------------- */

-- 사용자가 직접 생성한 Alias만 조회 (SYSTEM_CREATED=N)
SELECT name, file_number, system_created, alias_directory
FROM   v$asm_alias
WHERE  group_number = (SELECT group_number FROM v$asm_diskgroup WHERE name = 'DATA')
AND    system_created = 'N'
ORDER  BY name;

/*
 [결과]
   NAME          FILE_NUMBER  SYSTEM_CREATED  ALIAS_DIRECTORY
   ------------  -----------  --------------  ---------------
   system01.dbf  257          N               N
   → 사용자가 직접 생성한 Alias만 조회 (현재 삭제 후라면 no rows selected)
*/


/* --------------------------------------------------------------------------
   11-3. v$asm_file
   -------------------------------------------------------------------------- */

-- 파일 타입·크기·Redundancy·Striping 속성 한 번에 확인
SELECT group_number, file_number, type,
       bytes, space, redundancy, striped
FROM   v$asm_file
WHERE  group_number = (SELECT group_number FROM v$asm_diskgroup WHERE name = 'DATA')
ORDER  BY type, file_number
FETCH FIRST 10 ROWS ONLY;

/*
 [결과]
   GROUP_NUMBER  FILE_NUMBER  TYPE           BYTES       SPACE       REDUNDANCY  STRIPED
   ------------  -----------  -------------  ----------  ----------  ----------  -------
   1             256          PARAMETERFILE  2048        4194304     MIRROR      COARSE
   1             257          DATAFILE       796917760   798490624   MIRROR      COARSE
   1             258          DATAFILE       734003200   735739904   MIRROR      COARSE
   1             259          DATAFILE       524288000   525336576   MIRROR      COARSE
   1             260          DATAFILE       104857600   105906176   MIRROR      COARSE
   1             261          CONTROLFILE    18874368    19922944    HIGH        FINE
   ...
   → 파일 타입별 Redundancy/Striping 차이 확인
   → CONTROLFILE만 HIGH + FINE 적용
   → 파일 사이즈가 작은 것은 대체로 로그 파일
*/


/* ============================================================================
   실습 핵심 요약
   ============================================================================

   주제                     핵심 포인트
   ----------------------   ---------------------------------------------------
   Fully Qualified Name     +그룹/DB_UNIQUE_NAME/타입/파일명.번호.버전
                            db_name이 아닌 db_unique_name 사용
   Alias                    Fully Qualified Name에 붙이는 별명
                            파일 복제 없이 참조만 제공
                            FOR 절 경로 앞 공백 주의 (ORA-15052)
   Template                 파일 생성 규칙 세트 (Redundancy + Striping)
                            파일 타입마다 기본값 존재
   Template 생성            ALTER DISKGROUP … ADD TEMPLATE … ATTRIBUTES (MIRROR FINE)
   Template 지정 생성       DATAFILE '+DATA(템플릿명)' 형식으로 지정
   Template 속성 확인       dba_data_files로 file_name 확인 → file_number 추출
                            → v$asm_file에서 redundancy/striped 조회
   DBMS_FILE_TRANSFER       OS ↔ ASM 파일 복사
                            Directory 객체 생성 후 COPY_FILE 호출
                            원본 파일 없으면 ORA-19505 발생
                            → RMAN으로 먼저 ASM→OS 복사하여 원본 생성
   ASMCMD cp                ASM ↔ OS 간 복사 가능
                            OMF 이름 그대로 목적지 지정 시 ASMCMD-8016 발생
                            OS→ASM 복사 시 /tmp 경유 + 권한 설정(chown/chmod) 필요
                            목적지 디렉토리 미존재 시 ORA-15173 발생
   Fast Mirror Resync       일시 장애 후 변경분만 재동기화
                            DISK_REPAIR_TIME 안에 복구 시 적용
   PRFG                     RAC 환경에서 가까운 Failure Group을 우선 읽도록 지정
   IDP                      HDD 환경에서 Hot/Cold 데이터를 디스크 내
                            빠른/느린 영역에 자동 배치
   RMAN + ASM               ASM 경로 그대로 BACKUP 명령 사용
                            별도 설정 없이 동작
   v$asm_template           Template 목록·속성 조회
                            SYSTEM=Y/N으로 기본/사용자 구분
   v$asm_alias              Alias 목록 조회
                            SYSTEM_CREATED=N이 사용자 생성
   v$asm_file               파일 타입·크기·Redundancy·Striping 속성 조회
                            name 컬럼 없음 — 경로 확인은 v$datafile 사용

   ============================================================================ */
