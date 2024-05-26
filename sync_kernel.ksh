#!/bin/ksh

log(){
  echo "${@}"
}

# Debug output
debug(){
  [ -n "${DEBUG}" ] \
    && echo "${@}" 1>&2
  :
}

# Throw an error && exit
fatal(){
  echo "${@}" 1>&2
  case $- in
  *i*) return ${RC:-1};;
  *) exit ${RC:-1};
  esac
}

function read_backwards {
  typeset x v
  while read x; do
    v=$(tac -s ${1} <<< ${x} | tr '\n' ' ')
    read ${2} ${3} <<< ${v%${1}}
  done
  typeset -n nameref=${2}
  eval ${2}=${nameref%${1}}
}

debug(){
  [ -n "${DEBUG}" ] \
    && echo "${@}" 1>&2
  :
}

set_trap(){
  trap "trap - ${SIGNALS:-INT TERM}; debug \"set_trap: running: \\\"${@}\\\"\"; stty echo 2>/dev/null; [ -n \"${TRAP_DEBUG}\" ] && set -x; ${@}; exit; [ -n \"${TRAP_DEBUG}\" ] && set +x" ${SIGNALS:-INT TERM}
  [ -n "${TRAP_DEBUG}" ] \
    && trap -p
}

compare_versions(){
  dpkg --compare-versions ${1} lt ${2}
}

get_latest_version(){
  compare_versions ${1} ${2} \
    && echo ${2} \
    || echo ${1}
}

set_direction(){
  compare_versions ${1} ${2} \
    && DIRECTION=from \
    || DIRECTION=to
}

set_ssh(){
  case ${DIRECTION} in
  to)
    SSH="ssh ${SSH_OPTS} ${REMOTE}"
  esac
}

restore_backup(){
  trap - INT TERM EXIT
  log "Restoring backup:"
  for d in ${TEST_FILE:-${UPGRADE_DIRS}}; do
    log "# ${SSH:+${SSH} }sudo rsync ${DISABLE_STRICT:+-e'ssh ${NO_STRICT_OPTS}'} ${RESTORE_OPTS} ${BACKUP_DIR}/${d} /${d}"
    ${SSH} sudo rsync ${DISABLE_STRICT:+-e'ssh ${NO_STRICT_OPTS}'} ${RESTORE_OPTS} ${BACKUP_DIR}/${d}/ /${d}
    [ -n "${TEST_FILE}" ] \
      && check_test
  done
}

function get_running_kernel {
  typeset m
  m=${ARCH#armv}; case $m in 6*) m= ;; esac
  echo /boot/kernel${m%l}.img
}

get_kernel_version(){
  ${SSH:-eval} "LC_ALL=C grep -a -b -o $'\x1f\x8b\x08\x00\x00\x00\x00\x00' ${1} \
  | cut -f1 -d: \
  | head -1 \
  | xargs -ri dd if=${1} ibs=1 obs=1024 skip={} status=none 2>/dev/null \
  | zgrep -Poam1 '(?<=Linux version )\S+'"
}

prune_flavour(){
  grep -o '^[0-9.]*' <<< ${1}
}

extract_flavour(){
  grep -Po '^[0-9.]*\K.*' <<< ${1}
}

function compare_revisions {
  typeset local local_rev remote remote_rev
  read local remote kernel <<< ${@}
  ssh ${SSH_OPTS} ${local} ${FW_REV_CMD} | read local_rev
  ssh ${SSH_OPTS} ${remote} ${FW_REV_CMD} | read remote_rev
  case ${local_rev} in
  ${remote_rev})
    log "Hosts ${HOST} & ${REMOTE_HOST} running the same revision of kernel ${kernel}, exiting"
    [ -z "${FORCE}" ] \
      && return 0
  ;;
  *)
    log "Hosts ${HOST} & ${REMOTE_HOST} running different revisions of kernel ${kernel}, updating"
  esac
  return 1
}

function compare_kernels {
  typeset installed local remote
  read local remote <<< ${@}
  log -ne "Checking currently installed kernel version (it might take a while)... "
  if [ -z "${PRINT_ONLY}${NO_CHECK}${TEST}${TEST_FAILURE}" ]; then
    [ -n "${remote}" ] \
      || fatal "Remote kernel not set"
    installed=$(get_kernel_version $(get_running_kernel))
    for kernel in local remote; do
      typeset -n var=${kernel}
      prune_flavour ${var} \
      | read var
    done
    [ -z "${installed}" ] \
      && log failed \
        && exit 1 \
      || log "${installed}"
    case "${remote}" in
    ${local})
      compare_revisions ${HOST} ${REMOTE_HOST} ${local} \
        && [ -z "${FORCE}" ] \
          && exit 1
    ;;
    ${installed}*)
      [ -d /lib/modules/${installed} ] \
        && [ -z "${FORCE}" ] \
          && log "Kernel ${installed} already appears to have been synced, please reboot" \
            && exit 1 \
        || log "Kernel modules for kernel ${installed} appear to be missing, syncing up" \
    ;;
    *)
      log "Kernels differ"
    esac
  else
    log "skipped"
  fi
}

function find_excludes {
  typeset kernel=${1}
  kernel=${kernel%+}
  kernel=${kernel%-*}
  set -o noglob
  for cmd in eval "ssh ${SSH_OPTS} ${REMOTE}"; do
    ${cmd} "find /lib/modules -mindepth 1 -maxdepth 1 -path *${kernel}* -prune -o -printf '--exclude="%P" '"
  done
}

run_test(){
  if [ -n "${TEST}" ]; then
    TEST_FILE=/dev/shm/test/date
    TEST_DIR=${TEST_FILE%/*}
    TEST_SETUP="mkdir -p ${TEST_DIR}; date > ${TEST_FILE}; cat ${TEST_FILE}; ls -la ${TEST_FILE}"
    log "Local file:"
    eval "${TEST_SETUP}"
    sleep 1
    log "Remote file:"
    ssh ${SSH_OPTS} ${REMOTE} "${TEST_SETUP}"
  fi
}

check_test(){
  if [ -n "${TEST_FILE}" ]; then
    for d in '' ${BACKUP_DIR}; do
      cat ${d}${TEST_FILE}
      log "${d:-Local} file:"
      ls -la ${d}${TEST_FILE}
    done
  fi
}

set_vars(){
  case ${DIRECTION} in
  from)
    SRC=${REMOTE}:
    LATEST_KERNEL=${REMOTE_KERNEL}
  ;;
  to)
    DEST=root@${REMOTE_HOST}:
    LATEST_KERNEL=${LOCAL_KERNEL}
  ;;
  esac
}

run_sync(){
  for d in ${TEST_DIR:-${UPGRADE_DIRS}}; do
    [ -n "${EXCLUDES}" ] \
      || EXCLUDES="$(find_excludes ${LATEST_KERNEL})"
    [ -n "${DEBUG}" ] \
      && set -x \
      || log -ne "Syncing ${d}... "
    tries=0
    while [ ${tries} -lt ${MAX_TRIES} ]; do
      if [ -z "${TEST_FAILURE}" ]; then
        output="$(sudo rsync ${SYNC_OPTS} \
        ${DISABLE_STRICT:+-e"ssh ${NO_STRICT_OPTS}"} \
        ${BACKUP_DIR:+--backup --backup-dir=${BACKUP_DIR}/${d}} \
        ${BOOT_EXCLUDES} ${EXCLUDES} ${SRC}/${d}/ ${DEST}/${d}/)"
      else
        output="$(echo "Failure test output"; sleep 3; false)"
      fi
      rc=$?
      [ -n "${DEBUG}" ] \
        && set +x \
        || case $rc in
           0) [ -n "${DRY_RUN}" ] \
                && tr 'NUL' '\n' <<< "${output:-\000nothing to sync}" \
                || log done;
              break;;
           *) tries=$((++tries));
              log -ne "failed attempt ${tries}... ";;
           esac
    done
    case $rc in
    0) :;;
    *) failed=${rc}; log "all attempts failed, error output follows"; fatal "${output}";;
    esac
    [ -n "${TEST}" ] \
      && log "Press CTRL-C now to test restore when interrupted" \
        && sleep 5
  done
}

MAX_TRIES=${MAX_TRIES:-3}
UPDATE=${UPDATE-1}
UPGRADE_DIRS="/lib/modules /opt/vc /boot"
BACKUP_DIR=/dev/shm/backup
NO_STRICT_OPTS='-o StrictHostKeyChecking=no -o CheckHostIP=no -o UserKnownHostsFile=/dev/null -o LogLevel=QUIET'
DISABLE_STRICT=y
SSH_OPTS="${DISABLE_STRICT:+${NO_STRICT_OPTS}} ${SSH_OPTS}"
COMMON_OPTS="-a${DEBUG:+iv}${DRY_RUN:+in}tx --mkpath"
SYNC_OPTS="${COMMON_OPTS} ${UPDATE:+--update $(rsync --help | grep -q update-links && echo --update-links)} --exclude=\*.bak --exclude=\*.orig --exclude=\*.txt"
BOOT_EXCLUDES="--exclude=config.txt --exclude=cmdline.txt"
RESTORE_OPTS="${COMMON_OPTS}"
FW_REV_CMD="cat /boot/.firmware_revision"
HOST=${HOSTNAME:-$(uname -n)}
LOCAL=${USER}@${HOST}
LOCAL_ARCH=$(uname -m)
LOCAL_KERNEL=$(uname -r)
log "USER = ${USER}, HOST = ${HOST} => LOCAL = ${LOCAL}, LOCAL_ARCH = ${LOCAL_ARCH}, LOCAL_KERNEL = ${LOCAL_KERNEL}"

read_backwards @ REMOTE_HOST REMOTE_USER <<< ${@}
[ -z "${REMOTE_HOST}" ] \
  && fatal "Unable to determine remote host"
case ${HOST} in
${REMOTE_HOST})
  fatal "Refusing to sync to self"
;;
esac
REMOTE=${REMOTE_USER:=pi}@${REMOTE_HOST}
ssh ${SSH_OPTS} ${REMOTE} uname -mr | read REMOTE_KERNEL REMOTE_ARCH
[ -z "${REMOTE_ARCH}" ] \
  || [ -z "${REMOTE_KERNEL}" ] \
    && fatal "REMOTE_HOST empty"
log "REMOTE_USER = ${REMOTE_USER}, REMOTE_HOST = ${REMOTE_HOST} => REMOTE = ${REMOTE}, REMOTE_ARCH = ${REMOTE_ARCH}, REMOTE_KERNEL = ${REMOTE_KERNEL}"
[ -n "${DIRECTION}" ] \
  || set_direction ${LOCAL_KERNEL} ${REMOTE_KERNEL}
log "Syncing latest kernel ${DIRECTION} ${REMOTE}"
set_ssh
compare_kernels ${LOCAL_KERNEL} ${REMOTE_KERNEL}
run_test
set_vars
SIGNALS="INT TERM EXIT" set_trap restore_backup
run_sync
trap - EXIT
check_test
[ -z "${PRINT_ONLY}${TEST}" ] \
  && log -ne "Generating dependencies for kernel " \
    && latest=$(get_latest_version ${LOCAL_KERNEL} ${REMOTE_KERNEL}) \
      && kernel="$(prune_flavour ${latest})" \
        && log -ne "${kernel}... " \
          && kernel="${kernel}$(extract_flavour $(${SSH} uname -r))" \
            && ${SSH} sudo depmod -a ${kernel} \
              && log done \
                && log "Upgraded kernel to: ${kernel}" \
  || log failed
