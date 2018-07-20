#!/bin/bash

# Check for command line arguments
  program=$(basename $0)
  if [ $# -ne 1 ]; then
     printf "\n\nUsage: ${program} <RMAN Backup type (full|incr0|incr1|arch)>\n\n"
     exit 1
  else
     if [ "$1" = "full" ]; then
        backup_level="FULL"
        backup_desc="Full"
     elif [ "$1" = "arch" ]; then
        backup_desc="Archivelog"
     elif [ "$1" = "incr0" ]; then
        incr_level=${1: -1:1}
        backup_level="LEVEL0"
        backup_desc="Incremental 0 (Full)"
     elif [ "$1" = "incr1" ]; then
        incr_level=${1: -1:1}
        backup_level="LEVEL1"
        backup_desc="Incremental 1"
     else
        printf "\n\nUsage: ${program} <RMAN Backup type (full|incr0|incr1|arch)>\n\n"
        exit 1
     fi
     rman_type=$1
  fi


# Set Oracle environment for cron job
  . /u01/app/oracle/PRDdb/11.2.0.4/PRD_ebsdb-prd.env

# Set local rman backup variables
  CLIENT="TRVS"
  WEEKDAY=$(date +%w)
  CRONJOB_LOG=/u01/app/oracle/DBA/log/backup_rman_${1}.log
  RMAN_BACKUP_DATE=$(date +%Y%m%d)
  RMAN_BACKUP_TIME=$(date +%H%M)
  RMAN_DISK_PARALLELISM=12
  RMAN_BACKUP_TAG="${ORACLE_SID}_${backup_level}_${RMAN_BACKUP_DATE}_${RMAN_BACKUP_TIME}"
  RMAN_BACKUP_RETENTION=21
  RMAN_ARCH_TAG="${ORACLE_SID}_ARCHIVELOGS_${RMAN_BACKUP_DATE}_${RMAN_BACKUP_TIME}"
  RMAN_ARCHIVELOG_RETENTION="12/24"
  RMAN_ARCHIVELOG_BACKEDUP_TIMES=1
  RMAN_BACKUP_DIR=/backup/primary/database/${ORACLE_SID}
  RMAN_ARCH_BACKUP_DIR=/backup/primary/archivelogs/${ORACLE_SID}
  RMAN_BACKUP_LOG_DIR=/u01/app/oracle/DBA/log
  RMAN_BACKUP_LOG_FILE=${RMAN_BACKUP_LOG_DIR}/${ORACLE_SID}_backup_${rman_type}_${RMAN_BACKUP_DATE}_${RMAN_BACKUP_TIME}.log
  RMAN_BACKUP_CONTROLFILE_FORMAT="${RMAN_BACKUP_DIR}/%d_backup_ctl_%F"
  RMAN_BACKUP_DB_FORMAT="${RMAN_BACKUP_DIR}/%d_backup_${rman_type}_db_%T_%u_%s_%p"
  RMAN_BACKUP_ARC_FORMAT="${RMAN_ARCH_BACKUP_DIR}/%d_backup_${rman_type}_al_%T_%u_%s_%p"
  RMAN_BACKUP_SNAPSHOT_CTRL_NAME=${RMAN_BACKUP_DIR}/snapcf_${ORACLE_SID}.f
  email_recipients="notification@trevera.com"
  email_suport_ticket="support.ticket@trevera.com"


# Check if backup_rman.sh is currently running and create a lock file or return lock status
  lock_script()
  {
     lockfile=$HOME/DBA/tmp/backup_rman.lock

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
          BACKUP AS COMPRESSED BACKUPSET DATABASE TAG '${RMAN_BACKUP_TAG}' FORMAT '${RMAN_BACKUP_DB_FORMAT}'
             PLUS ARCHIVELOG ALL NOT BACKED UP DELETE INPUT TAG '${RMAN_ARCH_TAG}' FORMAT '${RMAN_BACKUP_ARC_FORMAT}';
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

          BACKUP AS COMPRESSED BACKUPSET DEVICE TYPE DISK ARCHIVELOG ALL NOT BACKED UP ${RMAN_ARCHIVELOG_BACKEDUP_TIMES} TIMES
             TAG '${RMAN_ARCH_TAG}' FORMAT '${RMAN_BACKUP_ARC_FORMAT}';

          DELETE NOPROMPT ARCHIVELOG ALL COMPLETED BEFORE 'sysdate-${RMAN_ARCHIVELOG_RETENTION}'
             BACKED UP ${RMAN_ARCHIVELOG_BACKEDUP_TIMES} TIMES TO DEVICE TYPE DISK;
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
          BACKUP AS COMPRESSED BACKUPSET DEVICE TYPE DISK ARCHIVELOG ALL NOT BACKED UP ${RMAN_ARCHIVELOG_BACKEDUP_TIMES} TIMES
             TAG '${RMAN_ARCH_TAG}' FORMAT '${RMAN_BACKUP_ARC_FORMAT}';

          DELETE NOPROMPT ARCHIVELOG ALL COMPLETED BEFORE 'sysdate-${RMAN_ARCHIVELOG_RETENTION}'
             BACKED UP ${RMAN_ARCHIVELOG_BACKEDUP_TIMES} TIMES TO DEVICE TYPE DISK;
        }

    exit;
EOF

    if [ $? -ne 0 ]; then
       printf "\nThe rman archivelog backup may have errors or warning messages.\n\n"
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

  lock_script

# RMAN Backups
  # RMAN Full backup
  if [ "${rman_type}" = "full" ]; then
     printf "\nStarting ${ORACLE_SID} RMAN ${backup_desc} Backup ($(date))\n\n"
     rman_full_backup
     printf "\n\nThe ${ORACLE_SID} RMAN ${backup_desc} Backup has completed ${rman_status} ($(date))\n\n"
  fi

  # RMAN Incremental backup
  if [ "${rman_type}" = "incr0" -o "${rman_type}" = "incr1" ]; then
     printf "\nStarting ${ORACLE_SID} RMAN ${backup_desc} Backup ($(date))\n\n"
     rman_incr_backup
     printf "\n\nThe ${ORACLE_SID} RMAN ${backup_desc} Backup has completed ${rman_status} ($(date))\n\n"
  fi

  # RMAN Archivelog backup
  if [ "${rman_type}" = "arch" ]; then
     printf "\nStarting ${ORACLE_SID} RMAN ${backup_desc} Backup ($(date))\n\n"
     rman_arch_backup
     printf "\n\nThe ${ORACLE_SID} RMAN ${backup_desc} Backup has completed ${rman_status} ($(date))\n\n"
  fi

# Email log
  mutt -s "${CLIENT} - $(hostname -s) - ${ORACLE_SID} - RMAN ${backup_desc} Backup Completed ${rman_status}" \
       -i ${CRONJOB_LOG} \
       -a ${RMAN_BACKUP_LOG_FILE} \
       -- ${email_recipients} < /dev/null

  if [ "${rman_status}" = "With Errors" ]; then
     mutt -s "${CLIENT} - $(hostname -s) - ${ORACLE_SID} - RMAN ${backup_desc} Backup Completed ${rman_status}" \
          -i ${CRONJOB_LOG} \
          -a ${RMAN_BACKUP_LOG_FILE} \
          -- ${email_support_ticket} < /dev/null
  fi
