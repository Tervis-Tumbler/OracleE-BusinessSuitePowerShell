#!/bin/bash

#set -x

# Execute dbTier adpreclone.pl and then backup the Oracle Home binaries

# Setup Oracle environment
  program=$(basename $0)

  EBS_ENV_FILE="/u01/app/oracle/PRDdb/11.2.0.4/PRD_ebsdb-prd.env"
  if [ -e "${EBS_ENV_FILE}" ]; then
     . ${EBS_ENV_FILE} 
  else
     printf "\n\nUnable to source env file ${EBS_ENV_FILE}\n\n"
     STATUS="Aborted with Errors"
     email_status
     exit 1
  fi

# Setup parameters
  CLIENT="TRVS"
  ADMIN_HOME=$HOME/DBA
  ORACLE_BASE=/u01/app/oracle/${ORACLE_SID}db
  EBS_TIER=dbtier
  DB_DIR="11.2.0.4"
  backup_dir=/patches/${ORACLE_SID}_BIN
  backup_file=${ORACLE_SID}_${EBS_TIER}_$(date '+%Y%m%d')
  backup_status_file=${ORACLE_SID}_${EBS_TIER}_backup.chk
  backup_log_dir=$ADMIN_HOME/log
  backup_log_retention=14
  backup_retention=7
  backup_exclude_files="--exclude=11.2.0.4/bin/nmhs --exclude=11.2.0.4/bin/nmb --exclude=11.2.0.4/bin/nmo"
  EMAIL_RECIPIENTS="notification@trevera.com"
  STATUS="Completed Successfully"
  . ${ADMIN_HOME}/cfg/.wallet
  

# Check apps password
  function check_password()
  {
     sqlplus -s /nolog > /dev/null 2>&1 <<EOF
     whenever sqlerror exit failure
     connect apps/${APPS_PASS} 
     exit success
EOF

     if [ $? -ne 0 ]; then
        printf "\nUnable to validate the APPS credentials.\n"
        printf "Either the database is down or the APPS credentials supplied are wrong. ($(date))\n"
        STATUS="Aborted with Errors"
        email_status
        exit 1
     else
        printf "The APPS credentials are valid. ($(date))\n"
     fi

     return 0
  }


# Execute adpreclone.pl
  function execute_preclone()
  {
     { echo "${APPS_PASS}"; } | perl $ORACLE_HOME/appsutil/scripts/$CONTEXT_NAME/adpreclone.pl dbTier

     if [ $? -ne 0 ]; then
        printf "\nError executing script adpreclone.pl ($(date))\n\n"
        STATUS="Aborted with Errors"
        email_status
        exit 1
     fi

     return 0
  }


# Backup OH directory in dbTier
  function backup_dbtier()
  {
     # Remove status file if exist
     if [ -e "${backup_dir}/${backup_status_file}" ]; then
        rm ${backup_dir}/${backup_status_file}
        if [ $? -ne 0 ]; then
           printf "\nError removing status file ${backup_dir}/${backup_status_file} ($(date))\n\n"
        fi
     fi

     cd ${ORACLE_BASE}
     if [ $? -ne 0 ]; then
        printf "\nUnable to change directory to ${ORACLE_BASE}. ($(date))\n\n"
        STATUS="Aborted with Errors"
        email_status
        exit 1
     fi

     gtar_text=$( { gtar ${backup_exclude_files} -czf ${backup_dir}/${backup_file}.tgz ${DB_DIR}; } 2>&1) 
     if [ $? -eq 0 ]; then
        gtar_success=true
     else
        gtar_error=$(echo ${gtar_text} | awk -v FS=":" '{print $(NF)}' | sed -e 's/^[[:space:]]*//')
        if [ "${gtar_error}" = "file changed as we read it" ]; then
           gtar_success=true
        else
           gtar_success=false
        fi
     fi

     if ! ${gtar_success}; then
        printf "\nError executing gtar while backing up ${ORACLE_BASE}/${DB_DIR} ($(date))\n"
        printf "\nError message: ${gtar_text}\n\n"
        STATUS="Aborted with Errors"
        email_status
        exit 1
     fi

     # Creating status file
     >${backup_dir}/${backup_status_file}
     if [ $? -ne 0 ]; then
        printf "\nError creating status file ${backup_dir}/${backup_status_file} ($(date))\n\n"
     fi

     return 0
  }


# Remove previous tarballs
  function remove_prev_tarballs()
  {
     find "${backup_dir}" -type f -name "${ORACLE_SID}_${EBS_TIER}_????????.tgz" -mtime +"${backup_retention}" -ls -exec rm {} \;
     if [ $? -ne 0 ]; then
        printf "\nError removing previous tarballs from ${backup_dir} ($(date))\n\n"
     fi

     return 0 
  }


# Remove previous log files
  function remove_prev_logs()
  {
     find "${backup_log_dir}" -type f -name "${program%.*}_??????????_????.log" -mtime +"${backup_log_retention}" -ls -exec rm {} \;
     if [ $? -ne 0 ]; then
        printf "\nError removing previous log files from ${backup_log_dir} ($(date))\n\n"
     fi

     return 0
  }


# Email status
  function email_status()
  {
     # Email status and log 
     printf "\nExecution of preclone and backup of ${ORACLE_SID} dbTier binaries ${STATUS} ($(date))\n\n"
     mutt -s "${CLIENT} - $(hostname -s) - ${ORACLE_SID} - Preclone and Binary backup of dbTier ${STATUS}" \
          -i ${backup_log_dir}/${program%.*}.log \
          -- ${EMAIL_RECIPIENTS} < /dev/null

     # Rotate current log
     cp -p ${backup_log_dir}/${program%.*}.log ${backup_log_dir}/${program%.*}_$(date '+%Y%m%d_%H%M').log

     return 0
  }


#
# Main
#
  # Begin backup
  printf "\nBeginning dbTier backup process ($(date))\n\n"

  # Check if apps password is valid
  printf "\nValidating apps password ($(date))\n\n"
  check_password

  # Executing adprelone
  printf "\nExecuting adpreclone ($(date))\n\n"
  execute_preclone

  # Executing gtar
  printf "\nBacking up ${ORACLE_BASE}/${DB_DIR} directory ($(date))\n\n"
  backup_dbtier

  # Cleanup and remove previous tarballs
  printf "\nRemoving previous tarballs from ${backup_dir} ($(date))\n\n"
  remove_prev_tarballs

  # Cleanup and remove previous log files
  printf "\nRemoving previous log files from ${backup_log_dir} ($(date))\n\n"
  remove_prev_logs

  # Completed backup
  printf "\nCompleted dbTier backup process ($(date))\n\n"
  email_status
