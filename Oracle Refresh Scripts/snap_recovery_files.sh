#!/bin/bash
# Script to get the archive logs required for recovery of snapped database and setup recovery files 

# Setup PROD Oracle environment
  . /u01/app/oracle/PRDdb/11.2.0.4/PRD_ebsdb-prd.env


# Check for command line arguments
  program=$(basename $0)
  if [ $# -gt 1 ]; then
     printf "\nUsage: ${program} [optional: <SNAP_DATE> (format: YYYYMMDD)]\n\n"
     exit 1
  else
     if [ $# -eq 1 ]; then
        snap_date=$1
     else
        snap_date=$(date '+%Y%m%d')
     fi
  fi 


# Set variables
  archivelogs_dir=/archivelogs/${ORACLE_SID}
  binaries_dir=/patches/${ORACLE_SID}_BIN
  snap_clone_dir=/patches/cloning/snap/${snap_date}
  begin_log=$(awk 'NF {$1=$1;print}' ${snap_clone_dir}/begin_log_scn.txt)
  end_log=$(awk 'NF {$1=$1;print}' ${snap_clone_dir}/end_log_scn.txt)


# Execute SQL commands to obtain recovery data
  get_recovery_data()
  {
     printf 'Set AutoRecovery ON;\n\n' > ${snap_clone_dir}/recover_db.sql

     sqlplus -s "/ as sysdba" <<!EOF
       whenever sqlerror exit 1;
 
       set termout off
       set verify off
       set feed off
       set pages 0

       spool ${snap_clone_dir}/archivelogs_list.txt
       select name 
       from v\$archived_log
       where first_change# between ${begin_log} And ${end_log}
       order by name;

       spool ${snap_clone_dir}/recover_db.sql APPEND
       select 'Recover database until change ' || first_change# ||
              ' using backup controlfile;' 
       from v\$archived_log
       where first_change# = ${end_log};

       alter database backup controlfile to trace as '${snap_clone_dir}/PRD_controlfile.txt';
     exit;
!EOF

     return 0
  }


# Copy archivelogs
  copy_archivelogs()
  {
     mkdir ${snap_clone_dir}/archivelogs
     chmod 770 ${snap_clone_dir}/archivelogs

     while read archivelog; do
        cp --preserve=mode,timestamps ${archvielogs_dir}/${archivelog} ${snap_clone_dir}/archivelogs/
     done < ${snap_clone_dir}/archivelogs_list.txt

     if [ $? -ne 0 ]; then
        printf "\nError copying archivelogs from PROD (`date`)\n\n"
     fi

     return 0
  }


# Construct the SQL script to create controlfiles
  construct_controlfile_script()
  {
     printf 'set verify off\n\n' > ${snap_clone_dir}/create_controlfile.sql
     printf 'define ORA_SID="&1"\n\n' >> ${snap_clone_dir}/create_controlfile.sql

     awk '/^CREATE/{print;flag=1;next} /^;/{print;flag=0;exit}flag' ${snap_clone_dir}/PRD_controlfile.txt >> \
         ${snap_clone_dir}/create_controlfile.sql

     sed -i -e 's/REUSE/SET/; s/NORESETLOGS/RESETLOGS/; s/PRD/\&ORA_SID/; s/ARCHIVELOG/NOARCHIVELOG/;' \
               ${snap_clone_dir}/create_controlfile.sql

     return 0
  }


# Construct the SQL script to add temp
  construct_add_temp_script()
  {
     printf 'set verify off\n\n' > ${snap_clone_dir}/add_temp.sql
     printf 'define ORA_SID="&1"\n\n' >> ${snap_clone_dir}/add_temp.sql

     awk '/Other tempfiles/{flag=1;next} /End of tempfile/{flag=0;exit}flag' ${snap_clone_dir}/PRD_controlfile.txt >> \
         ${snap_clone_dir}/add_temp.sql

     sed -i 's/PRD/\&ORA_SID/' ${snap_clone_dir}/add_temp.sql

     return 0
  }


# Copy dbTier and appsTier binaries to snap directory 
  copy_binaries()
  {
     mkdir ${snap_clone_dir}/binaries
     chmod 770 ${snap_clone_dir}/binaries

     cp --preserve=mode,timestamps ${binaries_dir}/${ORACLE_SID}_dbtier_${snap_date}.tgz ${snap_clone_dir}/binaries/
     cp --preserve=mode,timestamps ${binaries_dir}/${ORACLE_SID}_appstier_${snap_date}.tgz ${snap_clone_dir}/binaries/

     if [ $? -ne 0 ]; then
        printf "\nError copying archivelogs from PROD (`date`)\n\n"
     fi

     return 0
  }


#
# Main
#

# Check if snap directory exist
  if [ -d "${snap_clone_dir}" ]; then
     get_recovery_data
     copy_archivelogs
     construct_controlfile_script
     construct_add_temp_script
     copy_binaries
  else
     printf "\nThe snap directory ${snap_clone_dir} is missing cannot write files.\n"
  fi
