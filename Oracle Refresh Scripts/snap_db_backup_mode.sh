#!/bin/bash
# Script to place a database into backup mode

# Setup PRD Oracle environment
  . /u01/app/oracle/PRDdb/11.2.0.4/PRD_ebsdb-prd.env
  

# Check for command line arguments
  program=$(basename $0)
  if [ $# -eq 0 ]; then
     printf "\nUsage: ${program} {begin|end}\n\n"
     exit 1
  else
     backup_mode=$1
     if [ "${backup_mode}" != "begin" -a "${backup_mode}" != "end" ]; then
        printf "\nUsage: ${program} {begin|end}\n\n"
        exit 1
     fi
  fi


# Set variables
  snap_date=$(date '+%Y%m%d')
  snap_clone_dir=/patches/cloning/snap/${snap_date}
  log_scn_file=${snap_clone_dir}/${backup_mode}_log_scn.txt


# Place database in/out of backup mode
  if [ "${backup_mode}" = "begin" ]; then

     # Check if current snap exist
     if [ -d "${snap_clone_dir}" ]; then
        existing_snap_dir_time=$(date -d "@$(stat -c '%Y' ${snap_clone_dir})" '+%H%M')
        mv ${snap_clone_dir} ${snap_clone_dir}_${existing_snap_dir_time}
     else
        mkdir ${snap_clone_dir}
        chmod 770 ${snap_clone_dir}
     fi

     # Begin database backup mode
       sqlplus -s "/ as sysdba" << !EOF
       whenever sqlerror exit 1;
       set pages 0
       set numwidth 15

       spool ${log_scn_file}
       select max(first_change#) from v\$archived_log;
       spool off

       alter database begin backup;
       exit;
!EOF

  elif [ "${backup_mode}" = "end" ]; then

     # Check if snap directory exist
     if [ ! -d "${snap_clone_dir}" ]; then
        printf "\nThe snap directory ${snap_clone_dir} is missing. Will end backup mode but cannot update files.\n"
     fi

     # End database backup mode
       sqlplus -s "/ as sysdba" << !EOF
       whenever sqlerror exit 1;

       alter database end backup;
       alter system archive log current;
       alter system archive log current;

       set pages 0
       set numwidth 15
       spool ${log_scn_file}
       select max(first_change#) from v\$archived_log;
       spool off
       exit;
!EOF

     # Execute script in background to create the database recovery files 
     nohup $HOME/DBA/scripts/snap_recovery_files.sh & 
  fi

  exit 0
