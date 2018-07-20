#!/bin/bash

# Check for command line arguments
  program=$(basename $0)
  if [ $# -ne 2 ]; then
     printf "\n\nUsage: ${program} <SID> <RMAN Backup type (full|incr0|incr1|arch|maint)>\n\n"
     exit 1
  else
     ORA_SID=$1
     rman_type=$2

     if [ "$rman_type" = "full" ]; then
        backup_level="FULL"
        backup_desc="Full Backup"
     elif [ "$rman_type" = "arch" ]; then
        backup_desc="Archivelog Backup"
     elif [ "$rman_type" = "incr0" ]; then
        incr_level=${rman_type: -1:1}
        backup_level="LEVEL0"
        backup_desc="Incremental 0 (Full) Backup"
     elif [ "$rman_type" = "incr1" ]; then
        incr_level=${rman_type: -1:1}
        backup_level="LEVEL1"
        backup_desc="Incremental 1 Backup"
     elif [ "$rman_type" = "maint" ]; then
        backup_desc="Maintenance"
     else
        printf "\n\nUsage: ${program} <SID> <RMAN Backup type (full|incr0|incr1|arch|maint)>\n\n"
        exit 1
     fi
  fi


# Setup Oracle environment
  DBA_HOME=${HOME}/DBA
  if [ -e ${DBA_HOME}/cfg/${ORA_SID}.cfg ]; then
     . ${DBA_HOME}/cfg/${ORA_SID}.cfg
  else
     printf "\n\nUnable to source env file ${DBA_HOME}/cfg/${ORA_SID}.cfg\n\n"
     STATUS="Aborted with Errors"
     email_status
     exit 1
  fi 


# Set local rman backup variables
  CRONJOB_LOG=${DBA_HOME}/log/backup_rman_${rman_type}_${ORACLE_SID}.log
  RMAN_BACKUP_TAG="${ORACLE_SID}_${backup_level}_${RMAN_BACKUP_DATE}_${RMAN_BACKUP_TIME}"
  RMAN_BACKUP_LOG_FILE=${RMAN_BACKUP_LOG_DIR}/${ORACLE_SID}_backup_${rman_type}_${RMAN_BACKUP_DATE}_${RMAN_BACKUP_TIME}.log
  RMAN_BACKUP_DB_FORMAT="${RMAN_BACKUP_DIR}/%d_${rman_type}_db_%T_%u_%s_%p"
  RMAN_BACKUP_ARC_FORMAT="${RMAN_ARCH_BACKUP_DIR}/%d_${rman_type}_al_%T_%u_%s_%p"


# Check if backup_rman.sh is currently running and create a lock file or return lock status
  lock_script()
  {
     lockfile=${DBA_HOME}/tmp/backup_rman_${ORACLE_SID}.lck

     if ( set -o noclobber; echo "$$" > "$lockfile") 2> /dev/null ; then
        trap 'rm -f "$lockfile"; exit $?' INT TERM EXIT
     else
        printf "Another instance of RMAN backup is already running!\n"
        exit
     fi
  }


# Perform full RMAN backup
  rman_full_backup()
  {
    rman target / log=${RMAN_BACKUP_LOG_FILE} << EOF

    CONFIGURE RETENTION POLICY TO RECOVERY WINDOW OF ${RMAN_BACKUP_RETENTION} DAYS;
    CONFIGURE CONTROLFILE AUTOBACKUP ON;
    CONFIGURE CONTROLFILE AUTOBACKUP FORMAT FOR DEVICE TYPE DISK TO '${RMAN_BACKUP_CONTROLFILE_FORMAT}';
    CONFIGURE DEVICE TYPE DISK PARALLELISM ${RMAN_DISK_PARALLELISM};
    CONFIGURE DEFAULT DEVICE TYPE TO DISK;

    run {
          BACKUP AS COMPRESSED BACKUPSET DEVICE TYPE DISK DATABASE TAG '${RMAN_BACKUP_TAG}' FORMAT '${RMAN_BACKUP_DB_FORMAT}'
             PLUS ARCHIVELOG DELETE INPUT TAG '${RMAN_ARCH_TAG}' FORMAT '${RMAN_BACKUP_ARC_FORMAT}';
        }

    exit;
EOF

    if [ $? -ne 0 ]; then
       printf "\nThe rman full backup may have errors or warning messages.\n\n"
       rman_status="With Errors"
       return 1
    else
       rman_status="Successfully"
       return 0
    fi
  }


# Perform incremental RMAN backup
  rman_incr_backup()
  {
    rman target / log=${RMAN_BACKUP_LOG_FILE} << EOF

    CONFIGURE RETENTION POLICY TO RECOVERY WINDOW OF ${RMAN_BACKUP_RETENTION} DAYS;
    CONFIGURE CONTROLFILE AUTOBACKUP ON;
    CONFIGURE CONTROLFILE AUTOBACKUP FORMAT FOR DEVICE TYPE DISK TO '${RMAN_BACKUP_CONTROLFILE_FORMAT}';
    CONFIGURE DEVICE TYPE DISK PARALLELISM ${RMAN_DISK_PARALLELISM};
    CONFIGURE DEFAULT DEVICE TYPE TO DISK;

    run {
          BACKUP AS COMPRESSED BACKUPSET INCREMENTAL LEVEL ${incr_level} DEVICE TYPE DISK DATABASE
             TAG '${RMAN_BACKUP_TAG}' FORMAT '${RMAN_BACKUP_DB_FORMAT}';

          BACKUP AS COMPRESSED BACKUPSET DEVICE TYPE DISK ARCHIVELOG ALL NOT BACKED UP DELETE INPUT
             TAG '${RMAN_ARCH_TAG}' FORMAT '${RMAN_BACKUP_ARC_FORMAT}';
        }

    exit;
EOF

    if [ $? -ne 0 ]; then
       printf "\nThe rman incremental backup may have errors or warning messages.\n\n"
       rman_status="With Errors"
       return 1
    else
       rman_status="Successfully"
       return 0
    fi
  }


# Perform archivelog RMAN backup
  rman_arch_backup()
  {
    rman target / log=${RMAN_BACKUP_LOG_FILE} << EOF

    CONFIGURE RETENTION POLICY TO RECOVERY WINDOW OF ${RMAN_BACKUP_RETENTION} DAYS;
    CONFIGURE CONTROLFILE AUTOBACKUP ON;
    CONFIGURE CONTROLFILE AUTOBACKUP FORMAT FOR DEVICE TYPE DISK TO '${RMAN_BACKUP_CONTROLFILE_FORMAT}';
    CONFIGURE DEVICE TYPE DISK PARALLELISM ${RMAN_DISK_PARALLELISM};
    CONFIGURE DEFAULT DEVICE TYPE TO DISK;

    run {
          BACKUP AS COMPRESSED BACKUPSET DEVICE TYPE DISK ARCHIVELOG ALL NOT BACKED UP DELETE INPUT
             TAG '${RMAN_ARCH_TAG}' FORMAT '${RMAN_BACKUP_ARC_FORMAT}';
        }

    exit;
EOF

    if [ $? -ne 0 ]; then
       printf "\nThe RMAN Archivelog backup may have errors or warning messages.\n\n"
       rman_status="With Errors"
       return 1
    else
       rman_status="Successfully"
       return 0
    fi
  }


# Perform RMAN maintenance
  rman_maintenance()
  {
     rman target / log=${RMAN_BACKUP_LOG_FILE} << EOF

     CROSSCHECK COPY;
     CROSSCHECK BACKUPSET;
     CROSSCHECK ARCHIVELOG ALL;

     DELETE NOPROMPT EXPIRED COPY;
     DELETE NOPROMPT EXPIRED BACKUPSET;
     DELETE NOPROMPT EXPIRED ARCHIVELOG ALL;

     DELETE NOPROMPT OBSOLETE RECOVERY WINDOW OF ${RMAN_BACKUP_RETENTION} DAYS DEVICE TYPE DISK;

     exit;
EOF

     if [ $? -ne 0 ]; then
        printf "\nThe RMAN Maintenance session may have errors or warning messages. ($(date))\n\n"
        rman_status="With Errors"
        return 1
     else
        rman_status="Successfully"
        return 0
     fi
  }


#
# Main
#

  # Create lock file if none otherwise return lock status
  lock_script

  # RMAN Full backup
  if [ "${rman_type}" = "full" ]; then
     printf "\nStarting ${ORACLE_SID} RMAN ${backup_desc} ($(date))\n\n"
     rman_full_backup
     printf "\n\nThe ${ORACLE_SID} RMAN ${backup_desc} has completed ${rman_status} ($(date))\n\n"
  fi

  # RMAN Incremental backup
  if [ "${rman_type}" = "incr0" -o "${rman_type}" = "incr1" ]; then
     printf "\nStarting ${ORACLE_SID} RMAN ${backup_desc} ($(date))\n\n"
     rman_incr_backup
     printf "\n\nThe ${ORACLE_SID} RMAN ${backup_desc} has completed ${rman_status} ($(date))\n\n"
  fi

  # RMAN Archivelog backup
  if [ "${rman_type}" = "arch" ]; then
     printf "\nStarting ${ORACLE_SID} RMAN ${backup_desc} ($(date))\n\n"
     rman_arch_backup
     printf "\n\nThe ${ORACLE_SID} RMAN ${backup_desc} has completed ${rman_status} ($(date))\n\n"
  fi

  # RMAN Maintenance
  if [ "${rman_type}" = "maint" ]; then
     printf "\nStarting ${ORACLE_SID} RMAN ${backup_desc} ($(date))\n\n"
     rman_maintenance
     printf "\n\nThe ${ORACLE_SID} RMAN ${backup_desc} has completed ${rman_status} ($(date))\n\n"
  fi

  # Email status and log
  mutt -s "${CLIENT} - $(hostname -s ) - ${ORACLE_SID} - RMAN ${backup_desc} Completed ${rman_status}" \
       -i ${CRONJOB_LOG} \
       -a ${RMAN_BACKUP_LOG_FILE} \
       -- ${email_notification} < /dev/null

  if [ "${rman_status}" = "With Errors" ]; then
     mutt -s "${CLIENT} - $(hostname -s) - ${ORACLE_SID} - RMAN ${backup_desc} Completed ${rman_status}" \
          -i ${CRONJOB_LOG} \
          -a ${RMAN_BACKUP_LOG_FILE} \
          -- ${email_support_ticket} < /dev/null
  fi
