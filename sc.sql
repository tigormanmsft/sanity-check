/*********************************************************************************
 * File:	sc.sql
 * Type:	Oracle SQL*Plus script
 * Date:	11-Sep 2014
 * Author:	Microsoft Customer Architecture & Engineering (CAE)
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 *
 * Copyright (c) 2020 by Microsoft. All rights reserved.
 * 
 * Description:
 *
 *	Oracle SQL*Plus script to perform a non-intrusive I/O test, which affects
 *	other sessions in database as little as possible, eliminating use of
 *	the Buffer Cache without using ALTER SYSTEM FLUSH BUFFER_CACHE.
 * 
 *	Steps:
 * 
 *	1. Accept user input for datafile directory path and size (in MB)
 *	2. Create tablespace (named MSFT#SC_TS) using specified path and size
 *	3. Create table (named MSFT#SC_DATA) within tablespace
 *		a. table attribute PCTFREE 99 results in only one row/block
 *	4. Populate table with enough rows to almost fill tablespace
 *		a. use global temporary table and APPEND hint to bypass Oracle Buffer Cache
 *		b. since gathering stats uses Buffer Cache, truncate and reload to clear
 *	5. Perform a non-parallel full table scan on the table
 *		a. bypass Oracle Buffer Cache using "direct path reads"
 *	6. Perform parallel-4, -8, -12, and -16 full table scans on the table
 *		a. bypass Oracle Buffer Cache using "direct path reads"
 *	7. Create index
 *		a. bypass Oracle Buffer Cache using "direct path reads"
 *	8. Perform non-parallel index scans on every block in the table
 *		a. cannot bypass Oracle Buffer Cache, so this is the last test in script
 *
 * Notes:
 *
 *	The script will take AWR snapshots (flush_level=>ALL) at the beginning
 *	and at the conclusion of the test.
 *
 *	Commands to enable event 10046 (a.k.a. extended SQL tracing) embedded
 *	in the beginning and end of the script.  Uncomment to enable tracing.
 *
 * Modifications:
 *	RTaylor	29-Aug 2014	v0.1 concept and specs
 *	TGorman	11-Sep 2014	v1.0 first test version
 *	VSrihari 26-Sep 2014	v1.1 scattered vs direct read controls, more init params
 *	TGorman 14-Nov 2014	v1.2 added ability to report DOP during parallel queries
 *	TGorman 03-Dec 2014	v1.3 modified GTT to make smaller, fewer reads amongst writes
 *	TGorman 29-Apr 2015	v1.4 recoded ACCEPT to handle longer datafile names
 *	TGorman	02-Dec 2015	v1.5 added calls to CREATE_SNAPSHOT procedure from
 *				     DBMS_WORKLOAD_REPOSITORY package
 *	TGorman	25-Apr 2016	v1.6 added code to generate AWR report from AWR
 *				     snapshots taken during this report
 *	TGorman	18-Oct 2016	v1.7 added index rebuild to ensure no buffering
 *	TGorman 16-Jan 2019	v1.8 multi-tenant database support
 *	TGorman	07-Nov 2019	v1.9 support for TDE, and capturing "CPU used by
 *				     this session" statistic
 *	TGorman	11-Aug 2020	v2.0 created as github project
 ********************************************************************************/
set echo off feedback off timing off pagesize 0 linesize 500 trimout on trimspool on pause off serveroutput on verify off
variable v_version number
exec :v_version := 2.0;
whenever oserror exit failure
whenever sqlerror exit failure
col pmax4 new_value V_PMAX4 noprint
col pmax8 new_value V_PMAX8 noprint
col pmax12 new_value V_PMAX12 noprint
col pmax16 new_value V_PMAX16 noprint
col instance_name new_value V_INSTANCE noprint
col instance_number new_value V_INSTANCE_NBR noprint
col dbid new_value V_DBID noprint
col tstamp new_value V_TSTAMP noprint
col pathname new_value V_PATHNAME noprint
col new_pathname new_value V_NEW_PATHNAME noprint
col pname format a25
col pvalue format a15
variable begin_sn number
variable end_sn number
variable v_ts_blksz number
variable v_ts_blks number
variable v_tbl_rows number
variable v_tbl_blks number
variable v_encryption varchar2(100)
variable v_enc_display varchar2(100)

/*
 * TGorman - added 16Jan19 for multi-tenant database support...
 */
accept V_PDB prompt "If this is a multitenant database, please specify PDB name (otherwise just press ENTER): "
declare
	v_12c_or_higher varchar2(5) := 'FALSE';
begin
	if '&&V_PDB' is not null then
		select 'TRUE' into v_12c_or_higher from v$instance where version >= '12';
		if nvl(v_12c_or_higher, 'FALSE') <> 'TRUE' then
			raise_application_error(-20000, 'Database version is less than 12');
		end if;
		execute immediate 'alter session set container = &&V_PDB';
	end if;
end;
/

select	least(4, greatest((select count(*) from v$px_session where sid <> qcsid),
			   (select value from v$parameter where name = 'parallel_max_servers'))) pmax4,
	least(8, greatest((select count(*) from v$px_session where sid <> qcsid),
			   (select value from v$parameter where name = 'parallel_max_servers'))) pmax8,
	least(12, greatest((select count(*) from v$px_session where sid <> qcsid),
			   (select value from v$parameter where name = 'parallel_max_servers'))) pmax12,
	least(16, greatest((select count(*) from v$px_session where sid <> qcsid),
			   (select value from v$parameter where name = 'parallel_max_servers'))) pmax16,
	instance_name,
	instance_number,
	to_char(sysdate, 'YYYYMMDD_HH24MISS') tstamp
from	v$instance;
select	dbid from v$database;
select decode(substr(file_name,1,1),'/',substr(file_name, 1, instr(file_name,'/',-1)-1),
       substr(file_name,1,instr(file_name,'/',1)-1)) pathname
from  dba_data_files where file_id = (select min(file_id) from dba_data_files);

spool sc_&&V_INSTANCE._&&V_TSTAMP
prompt Please enter the full pathname in which the test tablespace should be created.
prompt Suggested: &&V_PATHNAME
accept V_DCFD prompt "Press ENTER to accept suggestion, or enter pathname: "
accept V_DFNUM prompt "Please enter the number of datafiles to create in the test tablespace (default: 1): "
accept V_MB prompt "Please enter the size of the test tablespace to be created (MBytes): "
begin
	if &&V_MB < 100 then
		raise_application_error(-20000, 'Please specify 100 MB or more');
	end if;
end;
/
accept V_ENC prompt "Please enter AES128, AES192, AES256, or NONE for tablespace encryption (default: NONE): "
begin
	if '&&V_ENC' not in ('AES128','AES192','AES256','NONE','') then
		raise_application_error(-20000, 'Please specify AES128, AES192, AES256, or NONE');
	end if;
	if nvl('&&V_ENC','NONE') = 'NONE' then
		:v_encryption := '';
		:v_enc_display := '  NONE';
	else
		:v_encryption := ' encryption using ''&&V_ENC'' default storage (encrypt)';
		:v_enc_display := trim('&&V_ENC');
	end if;
end;
/

REM 
REM Set the Oracle initialization parameter DB_CREATE_FILE_DEST...
REM 
select decode('&&V_DCFD',null,'&&V_PATHNAME','&&V_DCFD') new_pathname from dual;
alter session set db_create_file_dest = '&&V_NEW_PATHNAME';

REM 
REM Comment out to disable extended SQL tracing (i.e. event 10046 level 12)...
REM 
REM alter session set tracefile_identifier = sc;
REM alter session set max_dump_file_size = unlimited;
REM alter session set statistics_level = all;
REM alter session set events '10046 trace name context forever, level 12';

REM 
REM Take an AWR snapshot to begin the test...
REM 
prompt 
prompt Preparation: creating AWR snapshot at beginning of test...
exec :begin_sn := dbms_workload_repository.create_snapshot(flush_level=>'ALL')
select '...AWR snapshot #'||trim(to_char(:begin_sn))||' created...' txt from dual;

REM
REM Events to force 'db file scattered read' or 'direct path read'
REM 
REM Forces scattered read on 11.2
REM alter session set events '10949 trace name context forever, level 1';
REM
REM Forces direct path read on 10.2
REM alter session set "_serial_direct_read" = true;
REM 

REM 
REM Drop the tablespace we're going to use, in case it still exists due to a prior failed run...
REM 
begin
	execute immediate 'drop tablespace msft#sc_ts including contents and datafiles';
	execute immediate 'truncate table msft#sc_gtt';
	execute immediate 'drop table msft#sc_gtt';
exception
	when others then null;
end;
/

REM 
REM Create the tablespace and table in which we're going to test...
REM 
declare
	v_dfnum	integer;
	v_mb	integer;
begin
	v_dfnum := nvl(trim('&&V_DFNUM'),1);
	v_mb := round(&&V_MB,0) / v_dfnum;
	if v_mb >= 50 then
		execute immediate 'create smallfile tablespace msft#sc_ts datafile size '||v_mb||'M nologging extent management local uniform size 1m'||:v_encryption;
		if v_dfnum > 1 then
			for i in 2..v_dfnum loop
				execute immediate 'alter tablespace msft#sc_ts add datafile size '||v_mb||'M';
			end loop;
		end if;
	else
		raise_application_error(-20000, 'Chosen size &&V_MB.M using &&V_DFNUM datafiles does not allow datafiles >= 50M');
	end if;
end;
/
create table msft#sc_data (col1 number, col2 varchar2(400)) nologging tablespace msft#sc_ts pctfree 99;
create global temporary table msft#sc_gtt (col1 number) on commit preserve rows;

exec select block_size into :v_ts_blksz from dba_tablespaces where tablespace_name = 'MSFT#SC_TS';
exec select sum(blocks), round((sum(blocks)-(8*(1048576/:v_ts_blksz)))*0.99,0) into :v_ts_blks, :v_tbl_rows from dba_data_files where tablespace_name = 'MSFT#SC_TS';
exec dbms_output.put_line(rpad('Script version : ',66,' ')||to_char(:v_version,'90.00'));
exec dbms_output.put_line(rpad('Attr: tablespace - blocks : ',60,' ')||to_char(:v_ts_blks,'999,999,990'));
exec dbms_output.put_line(rpad('Attr: tablespace - MB : ',57,' ')||to_char((:v_ts_blks*:v_ts_blksz)/1048576,'999,999,990.00'));
exec dbms_output.put_line(rpad('Attr: tablespace - encryption : ',66,' ')||:v_enc_display);
exec dbms_output.put_line(rpad('Attr: table - rows : ',60,' ')||to_char(:v_tbl_rows,'999,999,990'));
select	rpad('Parm: '||name||' :',60,' ')||lpad(trim(value),12,' ')||decode(isdefault,'TRUE',' (default)','') txt
from	v$parameter
where	name in ('sga_target','sga_max_size','memory_target','memory_max_target', 'parallel_max_servers','filesystemio_options',
		'db_file_multiblock_read_count','db_block_size','db_cache_size','pga_aggregate_target')
or	name like 'db\_%\_cache_size' escape '\'
order by 1;

set serveroutput on size 1000000
prompt
prompt Block #1 - Populating the table...
declare
	type t_tab	is table of msft#sc_gtt%rowtype;
	a_tab		t_tab := t_tab();
	v_hsecs		number;
	v_secs		number;
	v_secs2		number;
	v_rows		number;
	v_num_rows	number;
	v_blks		number;
	v_arl		number;
	v_blksz		number;
	v_phywrt	number;
	v_phywrt_c	number;
	v_phywrt_d	number;
	v_cpu		number;
begin
	--
	v_blksz := :v_ts_blksz;
	v_rows := :v_tbl_rows;
	--
	for i in 1 .. v_rows loop
		a_tab.extend;
		a_tab(i).col1 := i;
	end loop;
	--
	forall i in a_tab.first .. a_tab.last
		insert into msft#sc_gtt values a_tab(i);
	--
	select s.value into v_cpu from v$mystat s, v$statname n
	where s.statistic# = n.statistic# and n.name = 'CPU used by this session';
	select s.value into v_phywrt from v$mystat s, v$statname n
	where s.statistic# = n.statistic# and n.name = 'physical writes';
	select s.value into v_phywrt_c from v$mystat s, v$statname n
	where s.statistic# = n.statistic# and n.name = 'physical writes from cache';
	select s.value into v_phywrt_d from v$mystat s, v$statname n
	where s.statistic# = n.statistic# and n.name = 'physical writes direct';
	--
	v_hsecs := dbms_utility.get_time;
	insert /*+ append */ into msft#sc_data select col1, rpad('x',400,'x') from msft#sc_gtt;
	commit;
	v_secs := (dbms_utility.get_time - v_hsecs)/100;
	dbms_output.put_line(rpad('Stat: table - load elapsed (s) : ',57,' ')||to_char(v_secs,'999,999,990.00'));
	--
	select s.value - v_cpu into v_cpu from v$mystat s, v$statname n
	where s.statistic# = n.statistic# and n.name = 'CPU used by this session';
	select s.value - v_phywrt into v_phywrt from v$mystat s, v$statname n
	where s.statistic# = n.statistic# and n.name = 'physical writes';
	select s.value - v_phywrt_c into v_phywrt_c from v$mystat s, v$statname n
	where s.statistic# = n.statistic# and n.name = 'physical writes from cache';
	select s.value - v_phywrt_d into v_phywrt_d from v$mystat s, v$statname n
	where s.statistic# = n.statistic# and n.name = 'physical writes direct';
	--
	v_hsecs := dbms_utility.get_time;
	dbms_stats.gather_table_stats(user,'MSFT#SC_DATA');
	v_secs2 := (dbms_utility.get_time - v_hsecs)/100;
	dbms_output.put_line(rpad('Stat: table - stats elapsed (s) : ',57,' ')||to_char(v_secs2,'999,999,990.00'));
	--
	select num_rows, blocks, avg_row_len into v_num_rows, v_blks, v_arl from user_tables where table_name = 'MSFT#SC_DATA';
	:v_tbl_blks := v_blks;
	dbms_output.put_line(rpad('Attr: table - num_rows : ',60,' ')||to_char(v_num_rows,'999,999,990'));
	dbms_output.put_line(rpad('Attr: table - avg row length (b) : ',60,' ')||to_char(v_arl,'999,999,990'));
	dbms_output.put_line(rpad('Attr: table - used blocks : ',60,' ')||to_char(v_blks,'999,999,990'));
	dbms_output.put_line(rpad('Attr: table - used MB : ',57,' ')||to_char((v_blks*v_blksz)/1048576,'999,999,990.00'));
	dbms_output.put_line(rpad('Stat: load - CPU (s) : ',57,' ')||to_char(v_cpu/100,'999,999,990.00'));
	if v_secs <> 0 then
		dbms_output.put_line(rpad('Stat: load - MB/s : ',56,' ')||to_char(((v_blks*v_blksz)/1048576)/v_secs,'999,999,990.000'));
	end if;
	dbms_output.put_line(rpad('Stat: load - physical writes : ',60,' ')||to_char(v_phywrt,'999,999,990'));
	dbms_output.put_line(rpad('Stat: load - physical writes (MB) : ',57,' ')||to_char((v_phywrt*v_blksz)/1048576,'999,999,990.00'));
	if v_secs <> 0 then
		dbms_output.put_line(rpad('Stat: load - physical writes (MB/s) : ',56,' ')||to_char(((v_phywrt*v_blksz)/1048576)/v_secs,'999,999,990.000'));
	end if;
	dbms_output.put_line(rpad('Stat: load - physical writes from cache : ',60,' ')||to_char(v_phywrt_c,'999,999,990'));
	dbms_output.put_line(rpad('Stat: load - physical writes direct : ',60,' ')||to_char(v_phywrt_d,'999,999,990'));
	--
	execute immediate 'truncate table msft#sc_data';
	insert /*+ append */ into msft#sc_data select col1, rpad('x',400,'x') from msft#sc_gtt;
	commit;
	--
end;
/

set timing on

prompt 
prompt Block #2: noparallel FULL table scan...
declare
	v_logrd		number;
	v_phyrd		number;
	v_phyrd_c	number;
	v_phyrd_cpf	number;
	v_phyrd_d	number;
	v_blksz		number;
	v_cnt		number;
	v_hsecs		number;
	v_secs		number;
	v_cpu		number;
begin
	--
	v_blksz := :v_ts_blksz;
	--
	select s.value into v_cpu from v$mystat s, v$statname n
	where s.statistic# = n.statistic# and n.name = 'CPU used by this session';
	select s.value into v_phyrd_d from v$mystat s, v$statname n
	where s.statistic# = n.statistic# and n.name = 'physical reads direct';
	select s.value into v_phyrd_c from v$mystat s, v$statname n
	where s.statistic# = n.statistic# and n.name = 'physical reads cache';
	select s.value into v_phyrd_cpf from v$mystat s, v$statname n
	where s.statistic# = n.statistic# and n.name = 'physical reads cache prefetch';
	select s.value into v_phyrd from v$mystat s, v$statname n
	where s.statistic# = n.statistic# and n.name = 'physical reads';
	select s.value into v_logrd from v$mystat s, v$statname n
	where s.statistic# = n.statistic# and n.name = 'session logical reads';
	--
	v_hsecs := dbms_utility.get_time;
	select /*+ noparallel(x) full(x) */ count(*) into v_cnt from msft#sc_data x;
	v_secs := (dbms_utility.get_time - v_hsecs)/100;
	dbms_output.put_line(rpad('Stat: query - elapsed (s) : ',57,' ')||to_char(v_secs,'999,999,990.00'));
	--
	select s.value - v_cpu into v_cpu from v$mystat s, v$statname n
	where s.statistic# = n.statistic# and n.name = 'CPU used by this session';
	select s.value - v_logrd into v_logrd from v$mystat s, v$statname n
	where s.statistic# = n.statistic# and n.name = 'session logical reads';
	select s.value - v_phyrd_d into v_phyrd_d from v$mystat s, v$statname n
	where s.statistic# = n.statistic# and n.name = 'physical reads direct';
	select s.value - v_phyrd_c into v_phyrd_c from v$mystat s, v$statname n
	where s.statistic# = n.statistic# and n.name = 'physical reads cache';
	select s.value - v_phyrd_cpf into v_phyrd_cpf from v$mystat s, v$statname n
	where s.statistic# = n.statistic# and n.name = 'physical reads cache prefetch';
	select s.value - v_phyrd into v_phyrd from v$mystat s, v$statname n
	where s.statistic# = n.statistic# and n.name = 'physical reads';
	--
	dbms_output.put_line(rpad('Stat: query - row count : ',60,' ')||to_char(v_cnt,'999,999,990'));
	dbms_output.put_line(rpad('Stat: query - CPU (s) : ',57,' ')||to_char(v_cpu/100,'999,999,990.00'));
	dbms_output.put_line(rpad('Stat: query - logical reads : ',60,' ')||to_char(v_logrd,'999,999,990'));
	dbms_output.put_line(rpad('Stat: query - logical reads (MB) : ',57,' ')||to_char((v_logrd*v_blksz)/1048576,'999,999,990.00'));
	if v_secs <> 0 then
	        dbms_output.put_line(rpad('Stat: query - logical reads (MB/s) : ',56,' ')||to_char(((v_logrd*v_blksz)/1048576)/v_secs,'999,999,990.000'));
	end if;
	dbms_output.put_line(rpad('Stat: query - physical reads : ',60,' ')||to_char(v_phyrd,'999,999,990'));
	dbms_output.put_line(rpad('Stat: query - physical reads (MB) : ',57,' ')||to_char((v_phyrd*v_blksz)/1048576,'999,999,990.00'));
	if v_secs <> 0 then
	        dbms_output.put_line(rpad('Stat: query - physical reads (MB/s) : ',56,' ')||to_char(((v_phyrd*v_blksz)/1048576)/v_secs,'999,999,990.000'));
	end if;
	dbms_output.put_line(rpad('Stat: query - physical reads direct : ',60,' ')||to_char(v_phyrd_d,'999,999,990'));
	dbms_output.put_line(rpad('Stat: query - physical reads direct (MB) : ',57,' ')||to_char((v_phyrd_d*v_blksz)/1048576,'999,999,990.00'));
	dbms_output.put_line(rpad('Stat: query - physical reads cache : ',60,' ')||to_char(v_phyrd_c,'999,999,990'));
	dbms_output.put_line(rpad('Stat: query - physical reads cache (MB) : ',57,' ')||to_char((v_phyrd_c*v_blksz)/1048576,'999,999,990.00'));
	dbms_output.put_line(rpad('Stat: query - physical reads cache prefetch : ',60,' ')||to_char(v_phyrd_cpf,'999,999,990'));
	dbms_output.put_line(rpad('Stat: query - physical reads cache prefetch (MB) : ',57,' ')||to_char((v_phyrd_cpf*v_blksz)/1048576,'999,999,990.00'));
	--
end;
/

prompt 
prompt Block #3: parallel FULL table scans...
declare
	v_cnt		number;
	v_hsecs		number;
	v_secs		number;
	v_cursor	integer;
	v_rows		integer;
	v_pxcnt		number;
begin
	--
	if &&V_PMAX4 >= 4 then
		--
		v_cursor := dbms_sql.open_cursor;
		dbms_sql.parse(v_cursor, 'select /*+ parallel(x,&&V_PMAX4) full(x) */ count(*) from msft#sc_data x', dbms_sql.native);
		dbms_sql.define_column(v_cursor, 1, v_cnt);
		v_hsecs := dbms_utility.get_time;
		v_rows := dbms_sql.execute(v_cursor);
		select count(*) into v_pxcnt from gv$px_session where qcinst_id = userenv('INSTANCE') and qcsid = userenv('SID') and sid <> qcsid;
		if dbms_sql.fetch_rows(v_cursor) > 0 then
			dbms_sql.column_value(v_cursor, 1, v_cnt);
		else
			raise_application_error(-20000,'parallel&&V_PMAX4 fetch_rows failed');
		end if;
		v_secs := (dbms_utility.get_time - v_hsecs)/100;
		dbms_sql.close_cursor(v_cursor);
		--
		dbms_output.put_line(rpad('Stat: parallel'||trim('&&V_PMAX4')||' - DOP : ',60,' ')||to_char((v_pxcnt),'999,999,990'));
		dbms_output.put_line(rpad('Stat: parallel'||trim('&&V_PMAX4')||' - row count : ',60,' ')||to_char(v_cnt,'999,999,990'));
		dbms_output.put_line(rpad('Stat: parallel'||trim('&&V_PMAX4')||' - elapsed (s) : ',57,' ')||to_char(v_secs,'999,999,990.00'));
		dbms_output.put_line(rpad('Stat: parallel'||trim('&&V_PMAX4')||' - MB : ',57,' ')||to_char((:v_tbl_blks*:v_ts_blksz)/1048576,'999,999,990.00'));
		if v_secs <> 0 then
			dbms_output.put_line(rpad('Stat: parallel'||trim('&&V_PMAX4')||' - MB/s : ',56,' ')||to_char(((:v_tbl_blks*:v_ts_blksz)/1048576)/v_secs,'999,999,990.000'));
		end if;
	end if;
	--
	if &&V_PMAX8 >= 8 then
		--
		v_cursor := dbms_sql.open_cursor;
		dbms_sql.parse(v_cursor, 'select /*+ parallel(x,&&V_PMAX8) full(x) */ count(*) from msft#sc_data x', dbms_sql.native);
		dbms_sql.define_column(v_cursor, 1, v_cnt);
		v_hsecs := dbms_utility.get_time;
		v_rows := dbms_sql.execute(v_cursor);
		select count(*) into v_pxcnt from gv$px_session where qcinst_id = userenv('INSTANCE') and qcsid = userenv('SID') and sid <> qcsid;
		if dbms_sql.fetch_rows(v_cursor) > 0 then
			dbms_sql.column_value(v_cursor, 1, v_cnt);
		else
			raise_application_error(-20000,'parallel&&V_PMAX8 fetch_rows failed');
		end if;
		v_secs := (dbms_utility.get_time - v_hsecs)/100;
		dbms_sql.close_cursor(v_cursor);
		--
		dbms_output.put_line(rpad('Stat: parallel'||trim('&&V_PMAX8')||' - DOP ',60,' ')||to_char((v_pxcnt),'999,999,990'));
		dbms_output.put_line(rpad('Stat: parallel'||trim('&&V_PMAX8')||' - row count : ',60,' ')||to_char(v_cnt,'999,999,990'));
		dbms_output.put_line(rpad('Stat: parallel'||trim('&&V_PMAX8')||' - elapsed (s) : ',57,' ')||to_char(v_secs,'999,999,990.00'));
		dbms_output.put_line(rpad('Stat: parallel'||trim('&&V_PMAX8')||' - MB : ',57,' ')||to_char((:v_tbl_blks*:v_ts_blksz)/1048576,'999,999,990.00'));
		if v_secs <> 0 then
			dbms_output.put_line(rpad('Stat: parallel'||trim('&&V_PMAX8')||' - MB/s : ',56,' ')||to_char(((:v_tbl_blks*:v_ts_blksz)/1048576)/v_secs,'999,999,990.000'));
		end if;
	end if;
	--
	if &&V_PMAX12 >= 12 then
		--
		v_cursor := dbms_sql.open_cursor;
		dbms_sql.parse(v_cursor, 'select /*+ parallel(x,&&V_PMAX12) full(x) */ count(*) from msft#sc_data x', dbms_sql.native);
		dbms_sql.define_column(v_cursor, 1, v_cnt);
		v_hsecs := dbms_utility.get_time;
		v_rows := dbms_sql.execute(v_cursor);
		select count(*) into v_pxcnt from gv$px_session where qcinst_id = userenv('INSTANCE') and qcsid = userenv('SID') and sid <> qcsid;
		if dbms_sql.fetch_rows(v_cursor) > 0 then
			dbms_sql.column_value(v_cursor, 1, v_cnt);
		else
			raise_application_error(-20000,'parallel&&V_PMAX12 fetch_rows failed');
		end if;
		v_secs := (dbms_utility.get_time - v_hsecs)/100;
		dbms_sql.close_cursor(v_cursor);
		--
		dbms_output.put_line(rpad('Stat: parallel'||trim('&&V_PMAX12')||' - DOP ',60,' ')||to_char((v_pxcnt),'999,999,990'));
		dbms_output.put_line(rpad('Stat: parallel'||trim('&&V_PMAX12')||' - row count : ',60,' ')||to_char(v_cnt,'999,999,990'));
		dbms_output.put_line(rpad('Stat: parallel'||trim('&&V_PMAX12')||' - elapsed (s) : ',57,' ')||to_char(v_secs,'999,999,990.00'));
		dbms_output.put_line(rpad('Stat: parallel'||trim('&&V_PMAX12')||' - MB : ',57,' ')||to_char((:v_tbl_blks*:v_ts_blksz)/1048576,'999,999,990.00'));
		if v_secs <> 0 then
			dbms_output.put_line(rpad('Stat: parallel'||trim('&&V_PMAX12')||' - MB/s : ',56,' ')||to_char(((:v_tbl_blks*:v_ts_blksz)/1048576)/v_secs,'999,999,990.000'));
		end if;
	end if;
	--
	if &&V_PMAX16 >= 16 then
		--
		v_cursor := dbms_sql.open_cursor;
		dbms_sql.parse(v_cursor, 'select /*+ parallel(x,&&V_PMAX16) full(x) */ count(*) from msft#sc_data x', dbms_sql.native);
		dbms_sql.define_column(v_cursor, 1, v_cnt);
		v_hsecs := dbms_utility.get_time;
		v_rows := dbms_sql.execute(v_cursor);
		select count(*) into v_pxcnt from gv$px_session where qcinst_id = userenv('INSTANCE') and qcsid = userenv('SID') and sid <> qcsid;
		if dbms_sql.fetch_rows(v_cursor) > 0 then
			dbms_sql.column_value(v_cursor, 1, v_cnt);
		else
			raise_application_error(-20000,'parallel&&V_PMAX16 fetch_rows failed');
		end if;
		v_secs := (dbms_utility.get_time - v_hsecs)/100;
		dbms_sql.close_cursor(v_cursor);
		--
		dbms_output.put_line(rpad('Stat: parallel'||trim('&&V_PMAX16')||' - DOP ',60,' ')||to_char((v_pxcnt),'999,999,990'));
		dbms_output.put_line(rpad('Stat: parallel'||trim('&&V_PMAX16')||' - row count : ',60,' ')||to_char(v_cnt,'999,999,990'));
		dbms_output.put_line(rpad('Stat: parallel'||trim('&&V_PMAX16')||' - elapsed (s) : ',57,' ')||to_char(v_secs,'999,999,990.00'));
		dbms_output.put_line(rpad('Stat: parallel'||trim('&&V_PMAX16')||' - MB : ',57,' ')||to_char((:v_tbl_blks*:v_ts_blksz)/1048576,'999,999,990.00'));
		if v_secs <> 0 then
			dbms_output.put_line(rpad('Stat: parallel'||trim('&&V_PMAX16')||' - MB/s : ',56,' ')||to_char(((:v_tbl_blks*:v_ts_blksz)/1048576)/v_secs,'999,999,990.000'));
		end if;
	end if;
	--
end;
/

prompt
prompt Block #4 - Add an index...
declare
	type t_tab	is table of msft#sc_data%rowtype;
	v_hsecs		number;
	v_secs		number;
	v_rows		number;
	v_num_rows	number;
	v_blks		number;
	v_arl		number;
	v_blksz		number;
	v_lf_rows	number;
	v_br_rows	number;
	v_lf_blks	number;
	v_br_blks	number;
	v_btree_space	number;
	v_used_space	number;
begin
	--
	v_blksz := :v_ts_blksz;
	v_rows := :v_tbl_rows;
	--
	execute immediate 'create unique index msft#sc_data_pk on msft#sc_data(col1) nologging tablespace msft#sc_ts';
	--
	execute immediate 'analyze index msft#sc_data_pk validate structure';
	--
	select blocks, lf_rows, br_rows, lf_blks, br_blks, btree_space, used_space
	into   v_blks, v_lf_rows, v_br_rows, v_lf_blks, v_br_blks, v_btree_space, v_used_space
	from index_stats where name = 'MSFT#SC_DATA_PK';
	dbms_output.put_line(rpad('Attr: index - used blocks : ',60,' ')||to_char(v_blks,'999,999,990'));
	dbms_output.put_line(rpad('Attr: index - used leaf rows : ',60,' ')||to_char(v_lf_rows,'999,999,990'));
	dbms_output.put_line(rpad('Attr: index - used branch rows : ',60,' ')||to_char(v_br_rows,'999,999,990'));
	dbms_output.put_line(rpad('Attr: index - used leaf blocks : ',60,' ')||to_char(v_lf_blks,'999,999,990'));
	dbms_output.put_line(rpad('Attr: index - used branch blocks : ',60,' ')||to_char(v_br_blks,'999,999,990'));
	dbms_output.put_line(rpad('Attr: index - B*Tree MB : ',57,' ')||to_char(v_btree_space/1048576,'999,999,990.00'));
	dbms_output.put_line(rpad('Attr: index - used MB : ',57,' ')||to_char(v_used_space/1048576,'999,999,990.00'));
	--
	execute immediate 'alter index msft#sc_data_pk unusable';
	execute immediate 'truncate table msft#sc_data';
	insert /*+ append */ into msft#sc_data select col1, rpad('x',400,'x') from msft#sc_gtt;
	commit;
	execute immediate 'alter index msft#sc_data_pk rebuild parallel 2';
	--
end;
/

prompt 
prompt Block #5: noparallel indexed table scans...
declare
	v_logrd		number;
	v_phyrd		number;
	v_phyrd_c	number;
	v_phyrd_cpf	number;
	v_phyrd_d	number;
	v_blksz		number;
	v_rows		number;
	v_cnt		number;
	v_dummy		number;
	v_totcnt	number := 0;
	v_hsecs		number;
	v_secs		number;
	v_cpu		number;
begin
	--
	v_rows := :v_tbl_rows;
	v_blksz := :v_ts_blksz;
	--
	select s.value into v_cpu from v$mystat s, v$statname n
	where s.statistic# = n.statistic# and n.name = 'CPU used by this session';
	select s.value into v_phyrd_d from v$mystat s, v$statname n
	where s.statistic# = n.statistic# and n.name = 'physical reads direct';
	select s.value into v_phyrd_c from v$mystat s, v$statname n
	where s.statistic# = n.statistic# and n.name = 'physical reads cache';
	select s.value into v_phyrd_cpf from v$mystat s, v$statname n
	where s.statistic# = n.statistic# and n.name = 'physical reads cache prefetch';
	select s.value into v_phyrd from v$mystat s, v$statname n
	where s.statistic# = n.statistic# and n.name = 'physical reads';
	select s.value into v_logrd from v$mystat s, v$statname n
	where s.statistic# = n.statistic# and n.name = 'session logical reads';
	--
	v_hsecs := dbms_utility.get_time;
	--
	for i in 1 .. (v_rows/2) loop
		--
		select count(*), sum(length(col2)) into v_cnt, v_dummy from msft#sc_data where col1 = i;
		v_totcnt := v_totcnt + v_cnt;
		--
		select count(*), sum(length(col2)) into v_cnt, v_dummy from msft#sc_data where col1 = ((v_rows + 1) - i);
		v_totcnt := v_totcnt + v_cnt;
		--
	end loop;
	--
	v_secs := (dbms_utility.get_time - v_hsecs)/100;
	dbms_output.put_line(rpad('Stat: query - elapsed (s) : ',57,' ')||to_char(v_secs,'999,999,990.00'));
	--
	select s.value - v_cpu into v_cpu from v$mystat s, v$statname n
	where s.statistic# = n.statistic# and n.name = 'CPU used by this session';
	select s.value - v_logrd into v_logrd from v$mystat s, v$statname n
	where s.statistic# = n.statistic# and n.name = 'session logical reads';
	select s.value - v_phyrd_d into v_phyrd_d from v$mystat s, v$statname n
	where s.statistic# = n.statistic# and n.name = 'physical reads direct';
	select s.value - v_phyrd_c into v_phyrd_c from v$mystat s, v$statname n
	where s.statistic# = n.statistic# and n.name = 'physical reads cache';
	select s.value - v_phyrd_cpf into v_phyrd_cpf from v$mystat s, v$statname n
	where s.statistic# = n.statistic# and n.name = 'physical reads cache prefetch';
	select s.value - v_phyrd into v_phyrd from v$mystat s, v$statname n
	where s.statistic# = n.statistic# and n.name = 'physical reads';
	--
	dbms_output.put_line(rpad('Stat: query - row count : ',60,' ')||to_char(v_totcnt,'999,999,990'));
	dbms_output.put_line(rpad('Stat: query - CPU (s) : ',57,' ')||to_char(v_cpu/100,'999,999,990.00'));
	dbms_output.put_line(rpad('Stat: query - logical reads : ',60,' ')||to_char(v_logrd,'999,999,990'));
	dbms_output.put_line(rpad('Stat: query - logical reads (MB) : ',57,' ')||to_char((v_logrd*v_blksz)/1048576,'999,999,990.00'));
	if v_secs <> 0 then
		dbms_output.put_line(rpad('Stat: query - logical reads (MB/s) : ',56,' ')||to_char(((v_logrd*v_blksz)/1048576)/v_secs,'999,999,990.000'));
	end if;
	dbms_output.put_line(rpad('Stat: query - physical reads : ',60,' ')||to_char(v_phyrd,'999,999,990'));
	dbms_output.put_line(rpad('Stat: query - physical reads (MB) : ',57,' ')||to_char((v_phyrd*v_blksz)/1048576,'999,999,990.00'));
	if v_secs <> 0 then
		dbms_output.put_line(rpad('Stat: query - physical reads (MB/s) : ',56,' ')||to_char(((v_phyrd*v_blksz)/1048576)/v_secs,'999,999,990.000'));
	end if;
	dbms_output.put_line(rpad('Stat: query - physical reads direct : ',60,' ')||to_char(v_phyrd_d,'999,999,990'));
	dbms_output.put_line(rpad('Stat: query - physical reads direct (MB) : ',57,' ')||to_char((v_phyrd_d*v_blksz)/1048576,'999,999,990.00'));
	dbms_output.put_line(rpad('Stat: query - physical reads cache : ',60,' ')||to_char(v_phyrd_c,'999,999,990'));
	dbms_output.put_line(rpad('Stat: query - physical reads cache (MB) : ',57,' ')||to_char((v_phyrd_c*v_blksz)/1048576,'999,999,990.00'));
	dbms_output.put_line(rpad('Stat: query - physical reads cache prefetch : ',60,' ')||to_char(v_phyrd_cpf,'999,999,990'));
	dbms_output.put_line(rpad('Stat: query - physical reads cache prefetch (MB) : ',57,' ')||to_char((v_phyrd_cpf*v_blksz)/1048576,'999,999,990.00'));
end;
/

prompt
prompt Drop the tablespace to clean up...
begin
	execute immediate 'drop tablespace msft#sc_ts including contents and datafiles';
	execute immediate 'truncate table msft#sc_gtt';
	execute immediate 'drop table msft#sc_gtt';
end;
/

REM 
REM Comment out to disable extended SQL tracing (i.e. event 10046 level 12) and
REM other session-level events set for this session...
REM 
REM alter session set events '10046 trace name context off';
REM alter session set events '10949 trace name context off';
REM alter session set "_serial_direct_read" = false;

REM 
REM Take an AWR snapshot to conclude the test...
REM 
prompt 
prompt Conclusion: creating AWR report at finish of test...
exec :end_sn := dbms_workload_repository.create_snapshot(flush_level=>'ALL')
spool off

set echo off feedback off timing off pagesize 0 linesize 8000 trimout on trimspool on verify off heading off underline on
column output format a7995
select output from table(dbms_workload_repository.awr_report_html(&&V_DBID, &&V_INSTANCE_NBR, :begin_sn, :end_sn, 0))

spool sc_awr_&&V_INSTANCE._&&V_TSTAMP..html
/
spool off

set pagesize 100 linesize 130 feedback 6 timing off verify on heading on
whenever oserror continue
whenever sqlerror continue
