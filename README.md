# sanity-check
Small limited I/O benchmark to generate consistent I/O workload from Oracle database using PL/SQL

This Oracle PL/SQL script performs a "sanity check" of the I/O subsystem underlying an Oracle database.  The script will consistently generate the same workload each time it is executed with the same input parameters, which makes it useful for comparisons between different databases, or comparisons between changes to the same database.

The script is intended to be executed from the Oracle SQL\*Plus utility while connected to a database account with DBA permissions, because it will create a tablespace as a "work area" in which to perform reads and writes.

The script will interactively prompt for...

  1. Size (in MiB) of the temporary "scratch" tablespace
       - No default value, must be between 100 MiB and 32767 MiB (i.e. Oracle SMALLFILE tablespace)
  2. PDB Name
       - If the database is single-tenant, then just press ENTER to skip
       - If the database is multi-tenant and the test to be performed within the container database (CDB), then just press ENTER
  3. Pathname in which the temporary "scratch" tablespace should be created
       - This can be a filesystem path or the name of an ASM diskgroup
       - To accept what is displayed, just press ENTER
  4. Number of datafiles in temporary "scratch" tablespace
       - Default number of datafiles is "1"
       - To accept the default (recommended), just press ENTER
  5. Encryption cipher for the temporary "scratch" tablespace
       - Default value is NONE
       - Possible non-default values are AES128, AES192, or AES256

From here, all output will be spooled to a file in the present working directory named "sc_${ORACLE_SID}_\<TimeStamp\>.lst".

Also, an Automatic Workload Repository (AWR) snapshot will be created as the starting point for generating an AWR report at the end of the script.

Also, the script contains several commented-out ALTER SESSION SET commands to enable extended SQL tracing or other special-purpose Oracle events such as forcing behavior.  Please read comments in the script for more info about these advanced options.

The script will display the values input, and then display names and values of initialization parameters which affect Oracle I/O performance.

The script will then create the temporary "scratch" tablespace as specified, and then create a single table within that tablespace.  This table will have the attribute PCTFREE 99, intended to ensure that each database block has only one row within.  The purpose of this is to force the table to become as large as possible with as little effort as possible, and also to ensure that each ROW FETCH operation results in one "physical I/O".

The script will next run five (5) anonymous PL/SQL blocks...
  1. Load the table with generated data, gather statistics on the table, truncate the table, and reload the table with generated data
  2. Query the table with a serial (noparallel) FULL table-scan
  3. Query the table with parallel FULL table-scans of degrees 4, 8, 12, and 16 (if permitted by PARALLEL_MAX_SERVERS setting)
  4. Create a primary key unique index on the table
  5. Perform single-row queries of all the rows in the table using the index.  Attempt to defeat readahead and caching by using the pattern of querying the first row, then the last row, then the second row, then the second-to-last row, then the third row, then the third-to-last row, then... (and so on)...

When all of these test have been completed, drop the temporary "scratch" tablespace, and generate a second AWR snapshot and an HTML-based AWR report, then exit

At the conclusion of the script, there should be two files generated to the present working directory...
  1. "sc_${ORACLE_SID}_\<TimeStamp\>.lst"
      text file containing output from the SQL and PL/SQL operations run within Oracle SQL\*Plus
  2. "sc_awr_${ORACLE_SID}_\<TimeStamp\>.html"
      standard Oracle AWR report in HTML format covering the time period of the script execution
