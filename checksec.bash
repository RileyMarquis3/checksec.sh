#!/usr/bin/env bash
# This version is no longer maintained/updated and only being kept for historal purposes

# --- Modified Version ---
# Name    : checksec.sh
# Version : 1.7.0
# Author  : Brian Davis
# Date    : Feburary 2014
# Download: https://github.com/slimm609/checksec.sh
#
# --- Modified Version ---
# Name    : checksec.sh
# Version : based on 1.5
# Author  : Robin David
# Date    : October 2013
# Download: https://github.com/RobinDavid/checksec
#
# --- Original version ---
# Name    : checksec.sh
# Version : 1.5
# Author  : Tobias Klein
# Date    : November 2011
# Download: http://www.trapkit.de/tools/checksec.html
# Changes : http://www.trapkit.de/tools/checksec_changes.txt

# set the common paths
PATH=${PATH}:/sbin/:/usr/sbin/:/usr/bin/:/bin/

# sanitize the environment before run
[[ "$(env | sed -r -e '/^(PWD|SHLVL|_)=/d')" ]] && exec -c "$0" "$@"

export PS4='+(${BASH_SOURCE##*/}:${LINENO}): ${FUNCNAME[0]:+${FUNCNAME[0]}(): }'

# License: BSD License
# https://opensource.org/licenses/bsd-license.php

# set global lang to C
export LC_ALL="C"

# version
SCRIPT_VERSION=2024060801
SCRIPT_MAJOR=2
SCRIPT_MINOR=7
SCRIPT_REVISION=1

# global vars
debug=false
verbose=false
format="cli"
SCRIPT_NAME="checksec"
SCRIPT_URL="https://github.com/slimm609/checksec.sh/raw/master/${SCRIPT_NAME}"
SIG_URL="https://github.com/slimm609/checksec.sh/raw/master/$(basename ${SCRIPT_NAME} .sh).sig"
# Currently unused, adding for reference
# https://github.com/gcc-mirror/gcc/blob/master/gcc/builtins.def#L1112
# FORTIFY_FUNCTIONS=(memcpy_chk memmove_chk mempcpy_chk memset_chk stpcpy_chk stpncpy_chk strcat_chk strcpy_chk strncat_chk strncpy_chk snprintf_chk sprintf_chk vsnprintf_chk vsprintf_chk fprintf_chk printf_chk vfprintf_chk vprintf_chk)

pkg_release=false
commandsmissing=false
OPT=0
extended_checks=false
# FORTIFY_SOURCE vars
FS_end=_chk
FS_cnt_total=0
FS_cnt_checked=0
FS_cnt_unchecked=0

# check if directory exists
dir_exists() {
  if [[ -d "${1}" ]]; then
    return 0
  else
    return 1
  fi
}

# check user privileges
root_privs() {
  if [[ $(id -u) -eq 0 ]]; then
    return 0
  else
    return 1
  fi
}

# check for required files and deps first
# check if command exists
command_exists() {
  type "${1}" > /dev/null 2>&1
}

for command in cat awk sed sysctl objdump uname mktemp openssl grep stat file find sort head ps readlink basename id which xargs ldconfig tr; do
  if ! (command_exists ${command}); then
    echo >&2 -e "\e[31mWARNING: '${command}' not found! It's required for most checks.\e[0m"
    commandsmissing=true
  fi
done

if [[ ${commandsmissing} == true ]]; then
  echo >&2 -e "\n\e[31mWARNING: Not all necessary commands found. Some tests might not work!\e[0m\n"
  sleep 2
fi

# search for libc
# shall be called before using variable FS_libc
search_libc() {
  if [[ -z ${FS_libc} ]]; then
    # if a specific search path is given, use it
    if [[ -n "${LIBC_FILE}" ]]; then
      if [[ -f "${LIBC_FILE}" ]]; then
        FS_libc=${LIBC_FILE}
      elif [[ -d "${LIBC_FILE}" ]]; then
        LIBC_SEARCH_PATH=${LIBC_FILE}
      fi
    # otherwise use ldconfig to get the libc location
    elif [[ -f $(ldconfig -p | grep 'libc\.so' | awk '{print $4}' | head -n 1) ]]; then
      FS_libc=$(ldconfig -p | grep 'libc\.so' | awk '{print $4}' | head -n 1)
    fi

    # if a search path was given or ldconfig failed we need to search for libc
    if [[ -z ${FS_libc} ]]; then
      # if a search path was specified, look for libc in LIBC_SEARCH_PATH
      if [[ -n "${LIBC_SEARCH_PATH}" ]]; then
        FS_libc=$(find "${LIBC_SEARCH_PATH}" \( -name "libc.so.6" -o -name "libc.so.7" -o -name "libc.so" \) -print -quit 2> /dev/null)
      # if ldconfig failed, then as a last resort search for libc in "/lib/", "/lib64/" and "/"
      else
        FS_libc=$(find /lib/ /lib64/ / \( -name "libc.so.6" -o -name "libc.so.7" -o -name "libc.so" \) -print -quit 2> /dev/null)
      fi
    fi

    #FS_libc is used across multiple functions
    if [[ -e ${FS_libc} ]]; then
      export FS_libc
    else
      printf "\033[31mError: libc not found.\033[m\n\n"
      exit 1
    fi
  fi
}

for command in readelf eu-readelf greadelf; do
  if (command_exists ${command}); then
    readelf="${command} -W"
    break
  fi
done

if [[ -z ${readelf} ]]; then
  echo -e "\n\e[31mERROR: readelf is a required tool for almost all tests. Aborting...\e[0m\n"
  exit
fi

sysarch=$(uname -m)
if [[ "${sysarch}" == "x86_64" ]]; then
  arch="64"
elif [[ "${sysarch}" == "i?86" ]]; then
  arch="32"
elif [[ "${sysarch}" =~ "arm" ]]; then
  arch="arm"
elif [[ "${sysarch}" =~ "aarch64" ]]; then
  arch="aarch64"
fi

# check for system-wide ASLR support
aslrcheck() {
  # PaX ASLR support
  if ! (grep -q 'Name:' /proc/1/status 2> /dev/null); then
    echo_message '\033[33m insufficient privileges for PaX ASLR checks\033[m\n' '' '' ''
    echo_message '  Fallback to standard Linux ASLR check' '' '' ''
  fi

  if grep -q 'PaX:' /proc/1/status 2> /dev/null; then
    if grep -q 'PaX:' /proc/1/status 2> /dev/null | grep -q 'R'; then
      echo_message '\033[32mPaX ASLR enabled\033[m\n\n' '' '' ''
    else
      echo_message '\033[31mPaX ASLR disabled\033[m\n\n' '' '' ''
    fi
  else
    # standard Linux 'kernel.randomize_va_space' ASLR support
    # (see the kernel file 'Documentation/admin-guide/sysctl/kernel.rst' for a detailed description)
    echo_message " (kernel.randomize_va_space): " '' '' ''
    if sysctl -a 2> /dev/null | grep -q 'kernel\.randomize_va_space = 1'; then
      echo_message '\033[33mPartial (Setting: 1)\033[m\n\n' '' '' ''
      echo_message "  Description - Make the addresses of mmap base, stack and VDSO page randomized.\n" '' '' ''
      echo_message "  This, among other things, implies that shared libraries will be loaded to \n" '' '' ''
      echo_message "  random addresses. Also for PIE-linked binaries, the location of code start\n" '' '' ''
      echo_message "  is randomized. Heap addresses are *not* randomized.\n\n" '' '' ''
    elif sysctl -a 2> /dev/null | grep -q 'kernel\.randomize_va_space = 2'; then
      echo_message '\033[32mFull (Setting: 2)\033[m\n\n' '' '' ''
      echo_message "  Description - Make the addresses of mmap base, heap, stack and VDSO page randomized.\n" '' '' ''
      echo_message "  This, among other things, implies that shared libraries will be loaded to random \n" '' '' ''
      echo_message "  addresses. Also for PIE-linked binaries, the location of code start is randomized.\n\n" '' '' ''
    elif sysctl -a 2> /dev/null | grep -q 'kernel\.randomize_va_space = 0'; then
      echo_message '\033[31mNone (Setting: 0)\033[m\n' '' '' ''
    else
      echo_message '\033[31mNot supported\033[m\n' '' '' ''
    fi
    echo_message "  See the kernel file 'Documentation/admin-guide/sysctl/kernel.rst' for more details.\n\n" '' '' ''
  fi
}

chk_dir() {
  if [[ -z "${CHK_DIR}" ]]; then
    printf "\033[31mError: Please provide a valid directory.\033[m\n\n"
    exit 1
  fi
  # follow symlink
  if [[ -L "${CHK_DIR}" ]]; then
    CHK_DIR=$(readlink -f "${CHK_DIR}")
  fi
  # remove trailing slashes
  tempdir=$(echo "${CHK_DIR}" | sed -e "s/\/*$//")
  if [[ ! -d "${tempdir}" ]]; then
    printf "\033[31mError: The directory '%s' does not exist.\033[m\n\n" "${tempdir}"
    exit 1
  fi
  if ${extended_checks}; then
    echo_message "RELRO           STACK CANARY      NX            PIE             SELFRANDO             Clang CFI            SafeStack            RPATH      RUNPATH    Symbols      \tFORTIFY\tFortified\tFortifiable   Filename\n" '' "<dir name='$tempdir'>\n" "{ \"dir\": { \"name\":\"$tempdir\" }"
  else
    echo_message "RELRO           STACK CANARY      NX            PIE             RPATH      RUNPATH    Symbols      \tFORTIFY\tFortified\tFortifiable   Filename\n" '' "<dir name='$tempdir'>\n" "{ \"dir\": { \"name\":\"$tempdir\" }"
  fi
  fdircount=0
  fdirtotal=0

  while read -r N; do
    if [[ "${N}" != "[A-Za-z1-0]*" ]]; then
      out=$(file "$(readlink -f "${N}")")
      if [[ ${out} =~ ELF ]]; then
        ((fdirtotal++))
      fi
    fi
  done < <(find "${tempdir}" -type f 2> /dev/null)
  if [[ $fdirtotal -gt 0 ]]; then
    echo_message "" "" "" ","
  fi
  while read -r N; do
    if [[ "${N}" != "[A-Za-z1-0]*" ]]; then
      # read permissions?
      if [[ ! -r "${N}" ]]; then
        printf "\033[31mError: No read permissions for '%s' (run as root).\033[m\n" ", ${N}"
      else
        # ELF executable?
        out=$(file "$(readlink -f "${N}")")
        if [[ ! ${out} =~ ELF ]]; then
          if [[ "${verbose}" = "true" ]]; then
            echo_message "\033[34m*** Not an ELF file: ${tempdir}/" "" "" ""
            file "${N}"
            echo_message "\033[m" "" "" ""
          fi
        else
          ((fdircount++))
          echo_message "" "" "    " ""
          filecheck "${N}"
          if [[ "$(find "${N}" \( -perm -004000 -o -perm -002000 \) -type f -print)" ]]; then
            echo_message "\033[37;41m${N}\033[m\n" ",${N}\n" " filename='${N}' />\n" ", \"filename\":\"${N}\"}"
          else
            echo_message "${N}\n" ",${N}\n" " filename='${N}' />\n" ", \"filename\":\"${N}\"}"
          fi
          if [[ "${fdircount}" == "${fdirtotal}" ]]; then
            echo_message "" "" "" ""
          else
            echo_message "" "" "" ","
          fi
        fi
      fi
    fi
  done < <(find "${tempdir}" -type f 2> /dev/null)
  echo_message "" "" "</dir>\n" "}"
}

chk_file() {
  if [[ -z "${CHK_FILE}" ]]; then
    printf "\033[31mError: Please provide a valid file.\033[m\n\n"
    exit 1
  fi

  # does the file exist?
  if [[ ! -e "${CHK_FILE}" ]]; then
    printf "\033[31mError: The file '%s' does not exist.\033[m\n\n" "${CHK_FILE}"
    exit 1
  fi

  # read permissions?
  if [[ ! -r "${CHK_FILE}" ]]; then
    printf "\033[31mError: No read permissions for '%s' (run as root).\033[m\n\n" "${CHK_FILE}"
    exit 1
  fi

  # ELF executable?
  out=$(file "$(readlink -f "${CHK_FILE}")")
  if [[ ! ${out} =~ ELF ]]; then
    printf "\033[31mError: Not an ELF file: "
    file "${CHK_FILE}"
    printf "\033[m\n"
    exit 1
  fi
  if ${extended_checks}; then
    echo_message "RELRO           STACK CANARY      NX            PIE             SELFRANDO             Clang CFI            SafeStack            RPATH      RUNPATH\tSymbols\t\tFORTIFY\tFortified\tFortifiable\tFILE\n" '' '' '{'
  else
    echo_message "RELRO           STACK CANARY      NX            PIE             RPATH      RUNPATH\tSymbols\t\tFORTIFY\tFortified\tFortifiable\tFILE\n" '' '' '{'
  fi
  filecheck "${CHK_FILE}"
  if [[ "$(find "${CHK_FILE}" \( -perm -004000 -o -perm -002000 \) -type f -print)" ]]; then
    echo_message "\033[37;41m${CHK_FILE}\033[m\n" ",${CHK_FILE}\n" " filename='${CHK_FILE}'/>\n" " } }"
  else
    echo_message "${CHK_FILE}\n" ",${CHK_FILE}\n" " filename='${CHK_FILE}'/>\n" " } }"
  fi
}

chk_file_list() {

  if ${extended_checks}; then
    echo_message "RELRO           STACK CANARY      NX            PIE             SELFRANDO             Clang CFI            SafeStack            RPATH      RUNPATH\tSymbols\t\tFORTIFY\tFortified\tFortifiable\tFILE\n" '' '' '{\n'
  else
    echo_message "RELRO           STACK CANARY      NX            PIE             RPATH      RUNPATH\tSymbols\t\tFORTIFY\tFortified\tFortifiable\tFILE\n" '' '' '{\n'
  fi

  LAST_LINE_NUMBER=$(wc -l < "${CHK_FILE_LIST}")
  CURRENT_LINE_NUMBER=0
  while IFS="" read -r p || [[ -n "${p}" ]]; do
    CHK_FILE="${p}"
    CURRENT_LINE_NUMBER=$((CURRENT_LINE_NUMBER + 1))

    if [[ -z "${CHK_FILE}" ]]; then
      printf "\033[31mError: Please provide a valid file.\033[m\n\n"
      exit 1
    fi

    # does the file exist?
    if [[ ! -e "${CHK_FILE}" ]]; then
      printf "\033[31mError: The file '%s' does not exist.\033[m\n\n" "${CHK_FILE}"
      exit 1
    fi

    # read permissions?
    if [[ ! -r "${CHK_FILE}" ]]; then
      printf "\033[31mError: No read permissions for '%s' (run as root).\033[m\n\n" "${CHK_FILE}"
      exit 1
    fi

    # ELF executable?
    out=$(file "$(readlink -f "${CHK_FILE}")")
    if [[ ! ${out} =~ ELF ]]; then
      printf "\033[31mError: Not an ELF file: "
      file "${CHK_FILE}"
      printf "\033[m\n"
      exit 1
    fi
    filecheck "${CHK_FILE}"
    if [[ "$(find "${CHK_FILE}" \( -perm -004000 -o -perm -002000 \) -type f -print)" ]]; then
      echo_message "\033[37;41m${CHK_FILE}\033[m\n" ",${CHK_FILE}\n" " filename='${CHK_FILE}'/>\n" " } }"
    else
      LINE_ENDING=" },\n"
      if [[ $CURRENT_LINE_NUMBER -eq $LAST_LINE_NUMBER ]]; then
        LINE_ENDING=" }\n"
      fi
      echo_message "${CHK_FILE}\n" ",${CHK_FILE}\n" " filename='${CHK_FILE}'/>\n" "${LINE_ENDING}"
    fi

  done < "${CHK_FILE_LIST}"

  echo_message '' '' '' ' }\n'
}

chk_fortify_file() {
  # if first char of pathname is '~' replace it with '${HOME}'
  if [[ "${CHK_FORTIFY_FILE:0:1}" = '~' ]]; then
    CHK_FORTIFY_FILE=${HOME}/${CHK_FORTIFY_FILE:1}
  fi

  if [[ -z "${CHK_FORTIFY_FILE}" ]]; then
    printf "\033[31mError: Please provide a valid file.\033[m\n\n"
    exit 1
  fi
  # does the file exist?
  if [[ ! -f "${CHK_FORTIFY_FILE}" ]]; then
    printf "\033[31mError: The file '%s' does not exist.\033[m\n\n" "${CHK_FORTIFY_FILE}"
    exit 1
  fi
  # read permissions?
  if [[ ! -r "${CHK_FORTIFY_FILE}" ]]; then
    printf "\033[31mError: No read permissions for '%s' (run as root).\033[m\n\n" "${CHK_FORTIFY_FILE}"
    exit 1
  fi
  # ELF executable?
  out=$(file "$(readlink -f "${CHK_FORTIFY_FILE}")")
  if [[ ! ${out} =~ ELF ]]; then
    printf "\033[31mError: Not an ELF file: "
    file "${CHK_FORTIFY_FILE}"
    printf "\033[m\n"
    exit 1
  fi

  search_libc

  FS_chk_func_libc=()
  FS_functions=()
  while IFS='' read -r line; do FS_chk_func_libc+=("$line"); done < <(${readelf} -s "${FS_libc}" 2> /dev/null | grep _chk@@ | awk '{ print $8 }' | cut -c 3- | sed -e 's/_chk@.*//' | sort -u)
  while IFS='' read -r line; do FS_functions+=("$line"); done < <(${readelf} -s "${CHK_FORTIFY_FILE}" 2> /dev/null | awk '{ print $8 }' | sed 's/_*//' | sed -e 's/@.*//' | sort -u)
  echo_message "" "" "<fortify-test name='${CHK_FORTIFY_FILE}' " "{ \"fortify-test\": { \"name\":\"${CHK_FORTIFY_FILE}\" "
  FS_libc_check
  FS_binary_check
  FS_comparison
  FS_summary
  echo_message "" "" "</fortify-test>\n" "} }"
}

chk_fortify_proc() {
  if [[ -z "${CHK_FORTIFY_PROC}" ]]; then
    printf "\033[31mError: Please provide a valid process ID.\033[m\n\n"
    exit 1
  fi
  if ! (isNumeric "${CHK_FORTIFY_PROC}"); then
    printf "\033[31mError: Please provide a valid process ID.\033[m\n\n"
    exit 1
  fi
  cd /proc || exit
  N=${CHK_FORTIFY_PROC}
  if [[ -d "${N}" ]]; then
    # read permissions?
    if [[ ! -r "${N}/exe" ]]; then
      if ! (root_privs); then
        printf "\033[31mNo read permissions for '/proc/%s/exe' (run as root).\033[m\n\n" "${N}"
        exit 1
      fi
      if [[ ! "$(readlink "${N}/exe")" ]]; then
        printf "\033[31mPermission denied. Requested process ID belongs to a kernel thread.\033[m\n\n"
        exit 1
      fi
      exit 1
    fi
    name=$(head -1 "${N}/status" | cut -b 7-)
    echo_message "* Process name (PID)                         : ${name} (${N})\n" "" "" ""

    search_libc

    FS_chk_func_libc=()
    FS_functions=()
    while IFS='' read -r line; do FS_chk_func_libc+=("$line"); done < <(${readelf} -s "${FS_libc}" 2> /dev/null | grep _chk@@ | awk '{ print $8 }' | cut -c 3- | sed -e 's/_chk@.*//' | sort -u)
    while IFS='' read -r line; do FS_functions+=("$line"); done < <(${readelf} -s "${CHK_FORTIFY_PROC}/exe" 2> /dev/null | awk '{ print $8 }' | sed 's/_*//' | sed -e 's/@.*//' | sort -u)
    echo_message "" "" "<fortify-test name='${name}' pid='${N}' " "{ \"fortify-test\": { \"name\":\"${name}\", \"pid\":\"${N}\" "
    FS_libc_check
    FS_binary_check
    FS_comparison
    FS_summary
    echo_message "" "" "</fortify-test>\n" "} }"
  fi
}

chk_proc_all() {
  cd /proc || exit
  echo_message "* System-wide ASLR" "" "" ""
  aslrcheck
  echo_message "* Does the CPU support NX: " "" "<procs>" ""
  nxcheck
  echo_message "* Core-Dumps access to all users: " "" "" ""
  coredumpcheck
  if ${extended_checks}; then
    echo_message "         COMMAND    PID RELRO           STACK CANARY            Clang CFI            SafeStack            SECCOMP          NX/PaX        PIE                     SELFRANDO             FORTIFY\n" "" "" '{'
  else
    echo_message "         COMMAND    PID RELRO           STACK CANARY            SECCOMP          NX/PaX        PIE                     FORTIFY\n" "" "" '{'
  fi
  lastpid=0
  currpid=0
  for N in [1-9]*; do
    if [[ "${N}" != "$$" ]] && readlink -q "${N}"/exe > /dev/null; then
      ((lastpid++))
    fi
  done
  for N in [1-9]*; do
    if [[ "${N}" != "$$" ]] && readlink -q "${N}"/exe > /dev/null; then
      ((currpid++))
      name=$(head -1 "${N}"/status | cut -b 7-)
      if [[ $format == "cli" ]]; then
        printf "%16s" "${name}"
        printf "%7d " "${N}"
      else
        echo_message "" "${N}," " <proc pid='${N}'" " \"${N}\": { "
        echo_message "" "${name}," " name='${name}'" "\"name\":\"${name}\","
      fi
      proccheck "${N}"
      if [[ "${lastpid}" == "${currpid}" ]]; then
        echo_message "\n" "\n" "</proc>\n" ""
      else
        echo_message "\n" "\n" "</proc>\n" ","
      fi
    fi
  done
  echo_message "" "" "</procs>" " }\n"
  if [[ ! -e /usr/bin/id ]]; then
    echo_message "\n\033[33mNote: If you are running 'checksec.sh' as an unprivileged user, you\n" "" "" ""
    echo_message "      will not see all processes. Please run the script as root.\033[m\n\n" "" "" "\n"
  else
    if ! (root_privs); then
      echo_message "\n\033[33mNote: You are running 'checksec.sh' as an unprivileged user.\n" "" "" ""
      echo_message "      Too see all processes, please run the script as root.\033[m\n\n" "" "" "\n"
    fi
  fi
}

chk_proc() {
  if [[ -z "${CHK_PROC}" ]]; then
    printf "\033[31mError: Please provide a valid process name.\033[m\n\n"
    exit 1
  fi
  cd /proc || exit
  # assume a process name was given
  IFS=" " read -r -a fpids <<< "$(pgrep -d ' ' "${CHK_PROC}")"
  # if nothing was found check if it is a PID
  if [[ ${#fpids} -eq 0 ]]; then
    if (isNumeric "${CHK_PROC}") && [[ -n "$(ps -p "${CHK_PROC}" -o pid=)" ]]; then
      fpids=("${CHK_PROC}")
    else
      printf "\033[31mError: Please provide a valid process name or pid.\033[m\n\n"
      exit 1
    fi
  fi

  echo_message "* System-wide ASLR" '' '' ''
  aslrcheck
  echo_message "* Does the CPU support NX: " '' '' ''
  nxcheck
  if ${extended_checks}; then
    echo_message "         COMMAND    PID RELRO           STACK CANARY            Clang CFI            SafeStack            SECCOMP          NX/PaX        PIE                     SELFRANDO             FORTIFY\n" "" "" '{'
  else
    echo_message "         COMMAND    PID RELRO           STACK CANARY            SECCOMP          NX/PaX        PIE                     FORTIFY\n" "" "" '{'
  fi
  pos=$((${#fpids[*]} - 1))
  last=${fpids[$pos]}
  for N in "${fpids[@]}"; do
    if [[ -d "${N}" ]]; then
      name=$(head -1 "${N}"/status | cut -b 7-)
      if [[ $format == "cli" ]]; then
        printf "%16s" "${name}"
        printf "%7d " "${N}"
      else
        echo_message "" "${N}," "<proc pid='${N}'" " \"${N}\": {"
        echo_message "" "${name}," " name='${name}'" "\"name\":\"${name}\","
      fi
      if [[ ! -r "${N}/exe" ]]; then
        if ! (root_privs); then
          printf "\033[31mNo read permissions for '/proc/%s/exe' (run as root).\033[m\n\n" "${N}"
          exit 1
        fi
        if [[ ! "$(readlink "${N}/exe")" ]]; then
          printf "\033[31mPermission denied. Requested process ID belongs to a kernel thread.\033[m\n\n"
          exit 1
        fi
        exit 1
      fi
      proccheck "${N}"
      if [[ "${N}" == "$last" ]]; then
        echo_message "\n" "\n" "</proc>\n" ""
      else
        echo_message "\n" "\n" "</proc>\n" ","
      fi
    fi
  done
  echo_message "\n" "\n" "\n" "}\n"
}

chk_proc_libs() {
  if [[ -z "${CHK_PROC_LIBS}" ]]; then
    printf "\033[31mError: Please provide a valid process ID.\033[m\n\n"
    exit 1
  fi
  if ! (isNumeric "${CHK_PROC_LIBS}"); then
    printf "\033[31mError: Please provide a valid process ID.\033[m\n\n"
    exit 1
  fi
  cd /proc || exit
  echo_message "* System-wide ASLR" '' '' ''
  aslrcheck
  echo_message "* Does the CPU support NX: " '' '' ''
  nxcheck
  echo_message "* Process information:\n\n" "" "" ""
  if ${extended_checks}; then
    echo_message "         COMMAND    PID RELRO           STACK CANARY            Clang CFI            SafeStack            SECCOMP        NX/PaX        PIE                     Fortify Source\n" '' '' ''
  else
    echo_message "         COMMAND    PID RELRO           STACK CANARY            SECCOMP        NX/PaX        PIE                     Fortify Source\n" '' '' ''
  fi
  N=${CHK_PROC_LIBS}
  if [[ -d "${N}" ]]; then
    name=$(head -1 "${N}/status" | cut -b 7-)
    if [[ "${format}" == "cli" ]]; then
      printf "%16s" "${name}"
      printf "%7d " "${N}"
    else
      echo_message "" "${name}," "<proc name='${name}'" "{ \"proc\": { \"name\":\"${name}\", "
      echo_message "" "${N}," " pid='${N}'" "\"pid\":\"${N}\","
    fi
    # read permissions?
    if [[ ! -r "${N}/exe" ]]; then
      if ! (root_privs); then
        printf "\033[31mNo read permissions for '/proc/%s/exe' (run as root).\033[m\n\n" "${N}"
        exit 1
      fi
      if [[ ! "$(readlink "${N}"/exe)" ]]; then
        printf "\033[31mPermission denied. Requested process ID belongs to a kernel thread.\033[m\n\n"
        exit 1
      fi
      exit 1
    fi
    proccheck "${N}"
    echo_message "\n\n\n" "\n" "\n" ","
    if ${extended_checks}; then
      echo_message "    RELRO           STACK CANARY   Clang CFI            SafeStack            NX/PaX        PIE            Clang CFI            SafeStack            RPath       RunPath   Fortify Fortified   Fortifiable\n" '' '' ''
    else
      echo_message "    RELRO           STACK CANARY   NX/PaX        PIE            RPath       RunPath   Fortify Fortified   Fortifiable\n" '' '' ''
    fi
    libcheck "${N}"
    echo_message "\n" "\n" "</proc>\n" "} } }"
  fi
}

#Check core dumps restricted?
coredumpcheck() {
  if [[ -f /etc/security/limits.conf ]]; then
    coreValue=$(grep -Exic "hard[[:blank:]]+core[[:blank:]]+0" /etc/security/limits.conf)
    coreValueDefault=$(grep -Exic "\*[[:blank:]]+hard[[:blank:]]+core[[:blank:]]+0" /etc/security/limits.conf)
  else
    coreValue=0
    coreValueDefault=0
  fi
  dumpableValue=$(sysctl -n fs.suid_dumpable)
  if { [[ "${coreValue}" == 1 ]] || [[ "${coreValueDefault}" == 1 ]]; } && { [[ "${dumpableValue}" == 0 ]] || [[ "${dumpableValue}" == 2 ]]; }; then
    echo_message '\033[32mRestricted\033[m\n\n' '' '' ''
  else
    echo_message '\033[31mNot Restricted\033[m\n\n' '' '' ''
  fi
}

debug_report() {
  echo "***** Checksec debug *****"
  failed=false
  id
  uname -a

  echo "checksec version: ${SCRIPT_MAJOR}.${SCRIPT_MINOR}.${SCRIPT_REVISION} -- ${SCRIPT_VERSION}"

  if [[ -f /etc/os-release ]]; then
    # freedesktop.org and systemd
    # shellcheck disable=SC1091
    source /etc/os-release
    # shellcheck disable=SC2153
    OS=${NAME}
    VER=${VERSION_ID}
  elif type lsb_release > /dev/null 2>&1; then
    # linuxbase.org
    OS=$(lsb_release -si)
    VER=$(lsb_release -sr)
  elif [[ -f /etc/lsb-release ]]; then
    # For some versions of Debian/Ubuntu without lsb_release command
    # shellcheck disable=SC1091
    source /etc/lsb-release
    OS=${DISTRIB_ID}
    VER=${DISTRIB_RELEASE}
  elif [[ -f /etc/debian_version ]]; then
    # Older Debian/Ubuntu/etc.
    OS=Debian
    VER=$(cat /etc/debian_version)
  elif [[ -f /etc/SuSe-release ]]; then
    # Older SuSE/etc.
    OS=$(cat /etc/SuSe-release)
    VER=$(uname -r)
  elif [[ -f /etc/redhat-release ]]; then
    # Older Red Hat, CentOS, etc.
    OS=$(cat /etc/redhat-release)
    VER=$(uname -r)
  else
    # Fall back to uname, e.g. "Linux <version>", also works for BSD, etc.
    OS=$(uname -s)
    VER=$(uname -r)
  fi

  echo "OS=${OS}"
  echo "VER=${VER}"

  for command in cat awk sysctl sed uname objdump mktemp openssl grep stat file find head ps readlink basename id which wget curl readelf eu-readelf; do
    path="$(command -v ${command})"
    if [[ -e "${path}" ]]; then
      ls -l "${path}"
      if [[ -L "${path}" ]]; then
        absolutepath=$(readlink -f "${path}")
        ls -l "${absolutepath}"
        file "${absolutepath}"
      else
        file "${path}"
      fi
    else
      echo "*** can not find command ${command}"
      failed=true
    fi
  done

  if ${failed}; then
    exit 1
  fi
}

# check file(s)
filecheck() {
  # check for RELRO support
  if [[ $(${readelf} -l "${1}" 2> /dev/null) =~ "no program headers" ]]; then
    echo_message '\033[32mN/A          \033[m   ' 'N/A,' '<file relro="n/a"' " \"${1}\": { \"relro\":\"n/a\","
  elif ${readelf} -l "${1}" 2> /dev/null | grep -q 'GNU_RELRO'; then
    if ${readelf} -d "${1}" 2> /dev/null | grep -q 'BIND_NOW' || ! ${readelf} -l "${1}" 2> /dev/null | grep -q '\.got\.plt'; then
      echo_message '\033[32mFull RELRO   \033[m   ' 'Full RELRO,' '<file relro="full"' " \"${1}\": { \"relro\":\"full\","
    else
      echo_message '\033[33mPartial RELRO\033[m   ' 'Partial RELRO,' '<file relro="partial"' " \"${1}\": { \"relro\":\"partial\","
    fi
  else
    echo_message '\033[31mNo RELRO     \033[m   ' 'No RELRO,' '<file relro="no"' " \"${1}\": { \"relro\":\"no\","
  fi

  # fallback on dynamic section to retrieve symbols when symbol table is unavailable
  use_dynamic=
  if [[ $(${readelf} -s "${1}" 2> /dev/null) =~ "Dynamic symbol information is not available" ]]; then
    use_dynamic="--use-dynamic"
  fi

  # check for stack canary support
  if ${readelf} -s "${use_dynamic}" "${1}" 2> /dev/null | grep " UND " | grep -Eq '__stack_chk_fail|__stack_chk_guard|__intel_security_cookie'; then
    echo_message '\033[32mCanary found   \033[m   ' 'Canary found,' ' canary="yes"' '"canary":"yes",'
  else
    echo_message '\033[31mNo canary found\033[m   ' 'No Canary found,' ' canary="no"' '"canary":"no",'
  fi

  # check for NX support
  # shellcheck disable=SC2126
  if [[ $(${readelf} -l "${1}" 2> /dev/null) =~ "no program headers" ]]; then
    echo_message '\033[32mN/A        \033[m   ' 'N/A,' ' nx="n/a"' '"nx":"n/a",'
  elif ${readelf} -l "${1}" 2> /dev/null | grep -q 'GNU_STACK'; then
    if [[ $(${readelf} -l "${1}" 2> /dev/null | grep 'GNU_STACK' | grep -oP '(?<=0x).*(?=RW )' | grep -o . | sort -u | tr -d '\n') != " 0x" ]]; then
      echo_message '\033[31mNX disabled\033[m   ' 'NX disabled,' ' nx="no"' '"nx":"no",'
    else
      echo_message '\033[32mNX enabled \033[m   ' 'NX enabled,' ' nx="yes"' '"nx":"yes",'
    fi
  else
    echo_message '\033[31mNX disabled\033[m   ' 'NX disabled,' ' nx="no"' '"nx":"no",'
  fi

  # check for PIE support
  if ${readelf} -h "${1}" 2> /dev/null | grep -q 'Type:[[:space:]]*EXEC'; then
    echo_message '\033[31mNo PIE       \033[m   ' 'No PIE,' ' pie="no"' '"pie":"no",'
  elif ${readelf} -h "${1}" 2> /dev/null | grep -q 'Type:[[:space:]]*DYN'; then
    if ${readelf} -d "${1}" 2> /dev/null | grep -q 'DEBUG'; then
      echo_message '\033[32mPIE enabled  \033[m   ' 'PIE enabled,' ' pie="yes"' '"pie":"yes",'
    else
      echo_message '\033[33mDSO          \033[m   ' 'DSO,' ' pie="dso"' '"pie":"dso",'
    fi
  elif ${readelf} -h "${1}" 2> /dev/null | grep -q 'Type:[[:space:]]*REL'; then
    echo_message '\033[33mREL          \033[m   ' 'REL,' ' pie="rel"' '"pie":"rel",'
  else
    echo_message '\033[33mNot an ELF file\033[m   ' 'Not an ELF file,' ' pie="not_elf"' '"pie":"not_elf",'
  fi

  if ${extended_checks}; then
    # check for selfrando support
    if ${readelf} -S "${1}" 2> /dev/null | grep -c 'txtrp' | grep -q '1'; then
      echo_message '\033[32mSelfrando enabled  \033[m   '
    else
      echo_message '\033[31mNo Selfrando       \033[m   '
    fi
  fi

  if ${extended_checks}; then
    # check if compiled with Clang CFI
    #if $readelf -s "$1" 2>/dev/null | grep -Eq '\.cfi'; then
    read -r cfifunc <<< "$($readelf -s "${use_dynamic}" "${1}" 2> /dev/null | grep '\.cfi' | awk '{ print $8 }')"
    func=${cfifunc/.cfi/}
    if [ -n "$cfifunc" ] && $readelf -s "${use_dynamic}" "$1" 2> /dev/null | grep -q "$func$"; then
      echo_message '\033[32mClang CFI found   \033[m   ' 'with CFI,' ' clangcfi="yes"' '"clangcfi":"yes",'
    else
      echo_message '\033[31mNo Clang CFI found\033[m   ' 'without CFI,' ' clangcfi="no"' '"clangcfi":"no",'
    fi

    # check if compiled with Clang SafeStack
    if $readelf -s "${use_dynamic}" "$1" 2> /dev/null | grep -Eq '__safestack_init'; then
      echo_message '\033[32mSafeStack found   \033[m   ' 'with SafeStack,' ' safestack="yes"' '"safestack":"yes",'
    else
      echo_message '\033[31mNo SafeStack found\033[m   ' 'without SafeStack,' ' safestack="no"' '"safestack":"no",'
    fi
  fi

  # check for rpath / run path
  # search for a line that matches RPATH and extract the colon-separated path list within brackets
  # example input: "0x000000000000000f (RPATH) Library rpath: [/lib/systemd:/lib/apparmor]"
  if [[ $(${readelf} -d "${1}" 2> /dev/null) =~ "no dynamic section" ]]; then
    echo_message '\033[32mN/A      \033[m  ' 'N/A,' ' rpath="n/a"' '"rpath":"n/a",'
  else
    IFS=: read -r -a rpath_array <<< "$(${readelf} -d "${1}" 2> /dev/null | awk -F'[][]' '/RPATH/ {print $2}')"
    if [[ "${#rpath_array[@]}" -gt 0 ]]; then
      if xargs stat -c %A <<< "${rpath_array[*]}" 2> /dev/null | grep -q 'rw'; then
        echo_message '\033[31mRW-RPATH \033[m  ' 'RPATH,' ' rpath="yes"' '"rpath":"yes",'
      else
        echo_message '\033[31mRPATH   \033[m  ' 'RPATH,' ' rpath="yes"' '"rpath":"yes",'
      fi
    else
      echo_message '\033[32mNo RPATH \033[m  ' 'No RPATH,' ' rpath="no"' '"rpath":"no",'
    fi
  fi

  # search for a line that matches RUNPATH and extract the colon-separated path list within brackets
  if [[ $(${readelf} -d "${1}" 2> /dev/null) =~ "no dynamic section" ]]; then
    echo_message '\033[32mN/A        \033[m  ' 'N/A,' ' runpath="n/a"' '"runpath":"n/a",'
  else
    IFS=: read -r -a runpath_array <<< "$(${readelf} -d "${1}" 2> /dev/null | awk -F'[][]' '/RUNPATH/ {print $2}')"
    if [[ "${#runpath_array[@]}" -gt 0 ]]; then
      if xargs stat -c %A <<< "${runpath_array[*]}" 2> /dev/null | grep -q 'rw'; then
        echo_message '\033[31mRW-RUNPATH \033[m  ' 'RUNPATH,' ' runpath="yes"' '"runpath":"yes",'
      else
        echo_message '\033[31mRUNPATH   \033[m  ' 'RUNPATH,' ' runpath="yes"' '"runpath":"yes",'
      fi
    else
      echo_message '\033[32mNo RUNPATH \033[m  ' 'No RUNPATH,' ' runpath="no"' '"runpath":"no",'
    fi
  fi

  # check for stripped symbols in the binary
  IFS=" " read -r -a SYM_cnt <<< "$(${readelf} --symbols "${1}" 2> /dev/null | grep '\.symtab' | cut -d' ' -f5 | cut -d: -f1)"
  if ${readelf} --symbols "${1}" 2> /dev/null | grep -q '\.symtab'; then
    echo_message "\033[31m${SYM_cnt[0]} Symbols\t\033[m" 'Symbols,' ' symbols="yes"' '"symbols":"yes",'
  else
    echo_message '\033[32mNo Symbols\t\033[m' 'No Symbols,' ' symbols="no"' '"symbols":"no",'
  fi

  search_libc
  libc_found="false"
  if ${readelf} -d "${1}" 2> /dev/null | grep 'NEEDED' | grep -q 'libc\.so'; then
    libc_found="true"
  fi
  FS_filechk_func_libc="$(${readelf} -s "${use_dynamic}" "${FS_libc}" 2> /dev/null | sed -ne 's/.*__\(.*_chk\)@@.*/\1/p')"
  FS_func_libc="${FS_filechk_func_libc//_chk/}"
  FS_func="$(${readelf} -s "${use_dynamic}" "${1}" 2> /dev/null | awk '{ print $8 }' | sed -e 's/_*//' -e 's/@.*//' -e '/^$/d')"
  FS_cnt_checked=$(grep -cFxf <(sort -u <<< "${FS_filechk_func_libc}") <(sort -u <<< "${FS_func}"))
  FS_cnt_unchecked=$(grep -cFxf <(sort -u <<< "${FS_func_libc}") <(sort -u <<< "${FS_func}"))
  FS_cnt_total=$((FS_cnt_unchecked + FS_cnt_checked))

  if [[ "${libc_found}" == "false" ]] || [[ "${FS_cnt_total}" -eq "0" ]]; then
    echo_message "\033[32mN/A\033[m" "N/A," ' fortify_source="n/a" ' '"fortify_source":"n/a",'
  elif [[ "${FS_cnt_checked}" -eq "0" ]]; then
    echo_message "\033[31mNo\033[m" "No," ' fortify_source="no" ' '"fortify_source":"no",'
  else
    echo_message '\033[32mYes\033[m' 'Yes,' ' fortify_source="yes" ' '"fortify_source":"yes",'
  fi
  echo_message "\t${FS_cnt_checked}\t" "${FS_cnt_checked}", "fortified=\"${FS_cnt_checked}\" " "\"fortified\":\"${FS_cnt_checked}\","
  echo_message "\t${FS_cnt_total}\t\t" "${FS_cnt_total}" "fortify-able=\"${FS_cnt_total}\"" "\"fortify-able\":\"${FS_cnt_total}\""
}

# format
format() {
  list="cli csv xml json"
  if [[ -n "${output_format}" ]]; then
    if [[ ! ${list} =~ ${output_format} ]]; then
      printf "\033[31mError: Please provide a valid format {cli, csv, xml, json}.\033[m\n\n"
      exit 1
    fi
  fi
  if [[ "${output_format}" == "xml" ]]; then
    echo '<?xml version="1.0" encoding="UTF-8"?>'
  fi
  format="${output_format}"
}

# --- FORTIFY_SOURCE subfunctions (start) ---
# is FORTIFY_SOURCE supported by libc?
FS_libc_check() {
  echo_message "* FORTIFY_SOURCE support available (libc)    : " "" ""

  if [[ "${#FS_chk_func_libc[@]}" != "0" ]]; then
    echo_message "\033[32mYes\033[m\n" "Yes," " libc_fortify_source='yes' " ', "libc_fortify_source":"yes"'
  else
    echo_message "\033[31mNo\033[m\n" "No," " libc_fortify_source='no' " ', "libc_fortify_source":"no"'
    exit 1
  fi
}

# was the binary compiled with FORTIFY_SOURCE?
FS_binary_check() {
  echo_message "* Binary compiled with FORTIFY_SOURCE support: " "" "" ""

  for ((FS_elem_functions = 0; FS_elem_functions < ${#FS_functions[@]}; FS_elem_functions++)); do
    if [[ ${FS_functions[$FS_elem_functions]} =~ _chk$ ]]; then
      echo_message "\033[32mYes\033[m\n" "Yes\n" " binary_compiled_with_fortify='yes'>\n" ', "binary_compiled_with_fortify":"yes"'
      return
    fi
  done
  echo_message "\033[31mNo\033[m\n" "No\n" " binary_compiled_with_fortify='no'>\n" ', "binary_compiled_with_fortify":"no"'
}

FS_comparison() {
  echo_message "\n" "" ""
  echo_message " ------ EXECUTABLE-FILE ------- . -------- LIBC --------\n" "" "" ""
  echo_message " Fortifiable library functions | Checked function names\n" "" "" ""
  echo_message " -------------------------------------------------------\n" "" "" ""

  # PRECONDITION. FS_chk_func_libc[] and FS_functions[] are both sorted to current locale and unique (sort -u).
  for ((FS_elem_libc = 0, FS_elem_functions = 0;  \
  FS_elem_libc < ${#FS_chk_func_libc[@]} && \
  FS_elem_functions < ${#FS_functions[@]}; )); do
    FS_tmp_func=${FS_functions[$FS_elem_functions]}
    FS_tmp_libc=${FS_chk_func_libc[$FS_elem_libc]}

    if [[ ${FS_tmp_func} < ${FS_tmp_libc} ]]; then
      ((FS_elem_functions++))
    elif [[ ${FS_tmp_func} == "${FS_tmp_libc}" ]]; then
      if [[ ${format} == "cli" ]]; then
        printf " \033[31m%-30s\033[m | __%s%s\n" "${FS_tmp_func}" "${FS_tmp_libc}" "${FS_end}"
      else
        echo_message "" "${FS_tmp_func},${FS_tmp_libc},yes\n" "    <function name='${FS_tmp_func}' libc='${FS_tmp_libc}' fortifiable='yes' />\n" ", \"function\": { \"name\":\"${FS_tmp_func}\", \"libc\":\"${FS_tmp_libc}\", \"fortifiable\":\"yes\" }"
      fi
      ((FS_cnt_total++))
      ((FS_cnt_unchecked++))
      ((FS_elem_functions++))
      # HERE LIES DRAGONS. If you advance the libc pointer now, you will miss the _chk!
    elif [[ ${FS_tmp_func} < ${FS_tmp_libc}_chk ]]; then
      ((FS_elem_functions++))
    elif [[ ${FS_tmp_func} == "${FS_tmp_libc}_chk" ]]; then
      if [[ ${format} == "cli" ]]; then
        printf " \033[32m%-30s\033[m | __%s%s\n" "${FS_tmp_func}" "${FS_tmp_libc}" "${FS_end}"
      else
        echo_message "" "${FS_tmp_func},${FS_tmp_libc},no\n" "    <function name='${FS_tmp_func}' libc='${FS_tmp_libc}' fortifiable='no' />\n" ", \"function\": { \"name\":\"${FS_tmp_func}\", \"libc\":\"${FS_tmp_libc}\", \"fortifiable\":\"no\" }"
      fi
      ((FS_cnt_total++))
      ((FS_cnt_checked++))
      ((FS_elem_functions++))
      ((FS_elem_libc++))
    else
      #  [[ ${FS_tmp_func} > ${FS_tmp_libc}_chk ]]
      ((FS_elem_libc++))
    fi
  done
}

FS_summary() {
  echo_message "\n" "" "\n" ""
  echo_message "SUMMARY:\n\n" "" "" ""
  echo_message "* Number of checked functions in libc                : ${#FS_chk_func_libc[@]}\n" "${#FS_chk_func_libc[@]}," "    <stats nb_libc_func='${#FS_chk_func_libc[@]}'" ", \"stats\": { \"nb_libc_func\":\"${#FS_chk_func_libc[@]}\""
  echo_message "* Total number of library functions in the executable: ${#FS_functions[@]}\n" "${#FS_functions[@]}," " nb_total_func='${#FS_functions[@]}'" ", \"nb_total_func\":\"${#FS_functions[@]}\""
  echo_message "* Number of Fortifiable functions in the executable : ${FS_cnt_total}\n" "${FS_cnt_total}," " nb_fortifiable_func='${FS_cnt_total}'" ", \"nb_fortifiable_func\":\"${FS_cnt_total}\""
  echo_message "* Number of checked functions in the executable      : \033[32m${FS_cnt_checked}\033[m\n" "${FS_cnt_checked}," " nb_checked_func='${FS_cnt_checked}'" ", \"nb_checked_func\":\"${FS_cnt_checked}\""
  echo_message "* Number of unchecked functions in the executable    : \033[31m${FS_cnt_unchecked}\033[m\n" "${FS_cnt_unchecked}" " nb_unchecked_func='${FS_cnt_unchecked}' />" ", \"nb_unchecked_func\":\"${FS_cnt_unchecked}\" } "
  echo_message "\n" "\n" "\n" ""
}

echo_message() {
  if [[ ${format} == "csv" ]]; then
    echo -n -e "$2"
  elif [[ ${format} == "xml" ]]; then
    echo -n -e "$3"
  elif [[ ${format} == "json" ]]; then
    echo -n -e "$4"
  else #default to cli
    echo -n -e "${1}"
  fi
}

# check if input is numeric
isNumeric() {
  echo "$@" | grep -q -v "[^0-9]"
}

# help
help() {
  echo "Usage: checksec [--format={cli,csv,xml,json}] [OPTION]"
  echo
  echo
  echo "Options:"
  echo
  echo " ## Checksec Options"
  echo "  --file={file}"
  echo "  --dir={directory}"
  echo "  --libcfile={file or search path for libc}"
  echo "  --listfile={text file with one file per line}"
  echo "  --proc={process name}"
  echo "  --proc-all"
  echo "  --proc-libs={process ID}"
  echo "  --kernel[=kconfig]"
  echo "  --fortify-file={executable-file}"
  echo "  --fortify-proc={process ID}"
  echo "  --version"
  echo "  --help"
  if ! ${pkg_release}; then
    echo "  --update or --upgrade"
  fi
  echo
  echo " ## Modifiers"
  echo "  --debug"
  echo "  --verbose"
  echo "  --format={cli,csv,xml,json}"
  echo "  --output={cli,csv,xml,json}"
  echo "  --extended"
  echo
  echo "For more information, see:"
  echo "  http://github.com/slimm609/checksec.sh"
  echo
}

chk_kernel() {
  if [[ ${CHK_KERNEL} == "kernel" ]]; then
    CHK_KERNEL=""
  fi
  if [[ -e "${CHK_KERNEL}" ]] && [[ ! -d "${CHK_KERNEL}" ]]; then
    if [[ -s "$(pwd -P)/${CHK_KERNEL}" ]]; then
      configfile=$(pwd -P)/${CHK_KERNEL}
    elif [[ -s "${CHK_KERNEL}" ]]; then
      configfile=${CHK_KERNEL}
    else
      "Error: config file specified do not exist"
      exit 1
    fi
    echo_message "* Kernel protection information for : $configfile \n\n" "" "" ""
    cd /proc && kernelcheck "$configfile" || exit
  else
    cd /proc || exit
    echo_message "* Kernel protection information:\n\n" "" "" ""
    kernelcheck
  fi
}

# check selinux status
getsestatus() {
  local status
  if (command_exists getenforce); then
    sestatus=$(getenforce)
    if [[ "${sestatus}" == "Disabled" ]]; then
      status=0
    elif [[ "${sestatus}" == "Permissive" ]]; then
      status=1
    elif [[ "${sestatus}" == "Enforcing" ]]; then
      status=2
    fi
  elif (command_exists sestatus); then
    sestatus=$(sestatus | grep "SELinux status" | awk '{ print $3}')
    if [[ "${sestatus}" == "disabled" ]]; then
      status=0
    elif [[ "${sestatus}" == "enabled" ]]; then
      sestatus2=$(sestatus | grep "Current" | awk '{ print $3}')
      if [[ "${sestatus2}" == "permissive" ]]; then
        status=1
      elif [[ "${sestatus2}" == "enforcing" ]]; then
        status=2
      fi
    fi
  fi
  return ${status}
}

# check for kernel protection mechanisms
kernelcheck() {
  echo_message "  Description - List the status of kernel protection mechanisms. Rather than\n" '' '' ''
  echo_message "  inspect kernel mechanisms that may aid in the prevention of exploitation of\n" '' '' ''
  echo_message "  userspace processes, this option lists the status of kernel configuration\n" '' '' ''
  echo_message "  options that harden the kernel itself against attack.\n\n" '' '' ''
  echo_message "  Kernel config:\n" '' '' '{ "kernel": '

  if [[ ! "${1}" == "" ]]; then
    kconfig="cat ${1}"
    echo_message "  Warning: The config ${1} on disk may not represent running kernel config!\n\n" "${1}" "<kernel config=\"${1}\"" "{ \"KernelConfig\":\"${1}\""
    # update the architecture based on the config rather than the system
    if ${kconfig} | grep -qi 'CONFIG_ARM=y\|CONFIG_ARM=y'; then
      arch="arm"
    fi
    if ${kconfig} | grep -qi 'CONFIG_ARM64=y'; then
      arch="aarch64"
    fi
    if ${kconfig} | grep -qi 'CONFIG_X86_64=y'; then
      arch="64"
    fi
    if ${kconfig} | grep -qi 'CONFIG_X86_32=y'; then
      arch="32"
    fi
  elif [[ -f /proc/config.gz ]]; then
    kconfig="zcat /proc/config.gz"
    echo_message "\033[32m/proc/config.gz\033[m\n\n" '/proc/config.gz' '<kernel config="/proc/config.gz"' '{ "KernelConfig":"/proc/config.gz"'
  elif [[ -f /boot/config-"$(uname -r)" ]]; then
    kern=$(uname -r)
    kconfig="cat /boot/config-${kern}"
    echo_message "\033[33m    /boot/config-${kern}\033[m\n\n" "/boot/config-${kern}," "<kernel config='/boot/config-${kern}'" "{ \"KernelConfig\":\"/boot/config-${kern}\""
    echo_message "  Warning: The config on disk may not represent running kernel config!\n           Running kernel: ${kern}\n\n" "" "" ""
  elif [[ -f "${KBUILD_OUTPUT:-/usr/src/linux}"/.config ]]; then
    kconfig="cat ${KBUILD_OUTPUT:-/usr/src/linux}/.config"
    echo_message "\033[33m${KBUILD_OUTPUT:-/usr/src/linux}/.config\033[m\n\n" "${KBUILD_OUTPUT:-/usr/src/linux}/.config," "<kernel config='${KBUILD_OUTPUT:-/usr/src/linux}/.config'" "{ \"KernelConfig\":\"${KBUILD_OUTPUT:-/usr/src/linux}/.config\""
    echo_message "  Warning: The config on disk may not represent running kernel config!\n\n" "" "" ""
  else
    echo_message "\033[31mNOT FOUND\033[m\n\n" "NOT FOUND,,,,,,," "<kernel config='not_found' />" '{ "KernelConfig":"not_found" } }'
    exit 0
  fi

  echo_message "  Vanilla Kernel ASLR:                    " "" "" ""
  randomize_va=$(sysctl -n kernel.randomize_va_space)
  if [[ "${randomize_va}" == "2" ]]; then
    echo_message "\033[32mFull\033[m\n" "Full," " randomize_va_space='full'" ', "randomize_va_space":"full"'
  elif [[ "${randomize_va}" == "1" ]]; then
    echo_message "\033[33mPartial\033[m\n" "Partial," " randomize_va_space='partial'" ', "randomize_va_space":"partial"'
  else
    echo_message "\033[31mNone\033[m\n" "None," " randomize_va_space='none'" ', "randomize_va_space":"none"'
  fi

  echo_message "  NX protection:                          " "" "" ""
  if (command_exists journalctl); then
    nx_protection=$(journalctl -kb -o cat | grep -Fw NX | head -n 1)
  elif (command_exists dmesg) && (root_privs); then
    nx_protection=$(dmesg -t 2> /dev/null | grep -Fw NX)
  fi
  if [ -n "$nx_protection" ]; then
    if [[ "${nx_protection}" == "NX (Execute Disable) protection: active" ]]; then
      echo_message "\033[32mEnabled\033[m\n" "Enabled," " nx_protection='yes'" ', "nx_protection":"yes"'
    else
      echo_message "\033[31mDisabled\033[m\n" "Disabled," " nx_protection='no'" ', "nx_protection":"no"'
    fi
  else
    echo_message "\033[33mSkipped\033[m\n" "Skipped," " nx_protection='skipped'" ', "nx_protection":"skipped"'
  fi

  echo_message "  Protected symlinks:                     " "" "" ""
  symlink=$(sysctl -n fs.protected_symlinks)
  if [[ "${symlink}" == "1" ]]; then
    echo_message "\033[32mEnabled\033[m\n" "Enabled," " protect_symlinks='yes'" ', "protect_symlinks":"yes"'
  else
    echo_message "\033[31mDisabled\033[m\n" "Disabled," " protect_symlinks='no'" ', "protect_symlinks":"no"'
  fi

  echo_message "  Protected hardlinks:                    " "" "" ""
  hardlink=$(sysctl -n fs.protected_hardlinks)
  if [[ "${hardlink}" == "1" ]]; then
    echo_message "\033[32mEnabled\033[m\n" "Enabled," " protect_hardlinks='yes'" ', "protect_hardlinks":"yes"'
  else
    echo_message "\033[31mDisabled\033[m\n" "Disabled," " protect_hardlinks='no'" ', "protect_hardlinks":"no"'
  fi

  echo_message "  Protected fifos:                        " "" "" ""
  fifos=$(sysctl -n fs.protected_fifos)
  if [[ -z "${fifos}" ]]; then
    echo_message "\033[33mUnsupported\033[m\n" "Unsupported," " protect_fifos='unsupported'" ', "protect_fifos":"unsupported"'
  elif [[ "${fifos}" == "1" ]]; then
    echo_message "\033[33mPartial\033[m\n" "Partial," " protect_fifos='partial'" ', "protect_fifos":"partial"'
  elif [[ "${fifos}" == "2" ]]; then
    echo_message "\033[32mEnabled\033[m\n" "Enabled," " protect_fifos='yes'" ', "protect_fifos":"yes"'
  else
    echo_message "\033[31mDisabled\033[m\n" "Disabled," " protect_fifos='no'" ', "protect_fifos":"no"'
  fi

  echo_message "  Protected regular:                      " "" "" ""
  regular=$(sysctl -n fs.protected_regular)
  if [[ -z "${regular}" ]]; then
    echo_message "\033[33mUnsupported\033[m\n" "Unsupported," " protect_regular='unsupported'" ', "protect_regular":"unsupported"'
  elif [[ "${regular}" == "1" ]]; then
    echo_message "\033[33mPartial\033[m\n" "Partial," " protect_regular='partial'" ', "protect_regular":"partial"'
  elif [[ "${regular}" == "2" ]]; then
    echo_message "\033[32mEnabled\033[m\n" "Enabled," " protect_regular='yes'" ', "protect_regular":"yes"'
  else
    echo_message "\033[31mDisabled\033[m\n" "Disabled," " protect_regular='no'" ', "protect_regular":"no"'
  fi

  echo_message "  Ipv4 reverse path filtering:            " "" "" ""
  ipv4_rpath=$(sysctl -n net.ipv4.conf.all.rp_filter)
  if [[ "${ipv4_rpath}" == "1" ]]; then
    echo_message "\033[32mEnabled\033[m\n" "Enabled," " ipv4_rpath='yes'" ', "ipv4_rpath":"yes"'
  else
    echo_message "\033[31mDisabled\033[m\n" "Disabled," " ipv4_rpath='no'" ', "ipv4_rpath":"no"'
  fi

  echo_message "  Kernel heap randomization:              " "" "" ""
  # NOTE: y means it turns off kernel heap randomization for backwards compatability (libc5)
  if ${kconfig} | grep -qi 'CONFIG_COMPAT_BRK=y'; then
    echo_message "\033[31mDisabled\033[m\n" "Disabled," " kernel_heap_randomization='no'" ', "kernel_heap_randomization":"no"'
  else
    echo_message "\033[32mEnabled\033[m\n" "Enabled," " kernel_heap_randomization='yes'" ', "kernel_heap_randomization":"yes"'
  fi

  if ${kconfig} | grep -qi 'CONFIG_CC_STACKPROTECTOR' || ${kconfig} | grep -qa 'CONFIG_STACKPROTECTOR'; then
    echo_message "  GCC stack protector support:            " "" "" ""
    if ${kconfig} | grep -qi 'CONFIG_CC_STACKPROTECTOR=y' || ${kconfig} | grep -qi 'CONFIG_STACKPROTECTOR=y'; then
      echo_message "\033[32mEnabled\033[m\n" "Enabled," " gcc_stack_protector='yes'" ', "gcc_stack_protector":"yes"'

      if ${kconfig} | grep -qi 'CONFIG_CC_STACKPROTECTOR_STRONG' || ${kconfig} | grep -qi 'CONFIG_STACKPROTECTOR_STRONG'; then
        echo_message "  GCC stack protector strong:             " "" "" ""
        if ${kconfig} | grep -qi 'CONFIG_CC_STACKPROTECTOR_STRONG=y' || ${kconfig} | grep -qi 'CONFIG_STACKPROTECTOR_STRONG=y'; then
          echo_message "\033[32mEnabled\033[m\n" "Enabled," " gcc_stack_protector_strong='yes'" ', "gcc_stack_protector_strong":"yes"'
        else
          echo_message "\033[31mDisabled\033[m\n" "Disabled," " gcc_stack_protector_strong='no'" ', "gcc_stack_protector_strong":"no"'
        fi
      fi
    else
      echo_message "\033[31mDisabled\033[m\n" "Disabled," " gcc_stack_protector='no'" ', "gcc_stack_protector":"no"'
    fi
  fi

  if ${kconfig} | grep -qi 'CONFIG_GCC_PLUGIN_STRUCTLEAK'; then
    echo_message "  GCC structleak plugin:                  " "" "" ""
    if ${kconfig} | grep -qi 'CONFIG_GCC_PLUGIN_STRUCTLEAK=y'; then
      echo_message "\033[32mEnabled\033[m\n" "Enabled," " gcc_structleak='yes'" ', "gcc_structleak":"yes"'
      echo_message "  GCC structleak by ref plugin:           " "" "" ""
      if ${kconfig} | grep -qi 'CONFIG_GCC_PLUGIN_STRUCTLEAK_BYREF_ALL=y'; then
        echo_message "\033[32mEnabled\033[m\n" "Enabled," " gcc_structleak_byref='yes'" ', "gcc_structleak_byref":"yes"'
      else
        echo_message "\033[32mEnabled\033[m\n" "Enabled," " gcc_structleak_byref='no'" ', "gcc_structleak_byref":"no"'
      fi
    else
      echo_message "\033[31mDisabled\033[m\n" "Disabled," " gcc_structleak='no'" ', "gcc_structleak":"no"'
    fi
  fi

  if ${kconfig} | grep -qi 'CONFIG_SLAB_FREELIST_RANDOM'; then
    echo_message "  SLAB freelist randomization:            " "" "" ""
    if ${kconfig} | grep -qi 'CONFIG_SLAB_FREELIST_RANDOM=y'; then
      echo_message "\033[32mEnabled\033[m\n" "Enabled," " slab_freelist_randomization='yes'" ', "slab_freelist_randomization":"yes"'
    else
      echo_message "\033[31mDisabled\033[m\n" "Disabled," " slab_freelist_randomization='no'" ', "slab_freelist_randomization":"no"'
    fi
  fi

  if ${kconfig} | grep -qi 'CPU_SW_DOMAIN_PAN=y'; then
    echo_message "  Use CPU domains:                        " "" "" ""
    if ${kconfig} | grep -qi 'CPU_SW_DOMAIN_PAN=y'; then
      echo_message "\033[32mEnabled\033[m\n" "Enabled," " cpu_sw_domain'yes'" ', "cpu_sw_domain":"yes"'
    else
      echo_message "\033[31mDisabled\033[m\n" "Disabled," " cpu_sw_domain='no'" ', "cpu_sw_domain":"no"'
    fi
  fi

  if ${kconfig} | grep -qi 'CONFIG_VMAP_STACK'; then
    echo_message "  Virtually-mapped kernel stack:          " "" "" ""
    if ${kconfig} | grep -qi 'CONFIG_VMAP_STACK=y'; then
      echo_message "\033[32mEnabled\033[m\n" "Enabled," " virtually_mapped_stack='yes'" ', "virtually_mapped_stack":"yes"'
    else
      echo_message "\033[31mDisabled\033[m\n" "Disabled," " virtually_mapped_stack='no'" ', "virtually_mapped_stack":"no"'
    fi
  fi

  if ${kconfig} | grep -qi 'CONFIG_STRICT_DEVMEM'; then
    echo_message "  Restrict /dev/mem access:               " "" "" ""
    if ${kconfig} | grep -qi 'CONFIG_STRICT_DEVMEM=y'; then
      echo_message "\033[32mEnabled\033[m\n" "Enabled," " restrict_dev_mem_access='yes'" ', "restrict_dev_mem_access":"yes"'
    else
      echo_message "\033[31mDisabled\033[m\n" "Disabled," " restrict_dev_mem_access='no'" ', "restrict_dev_mem_access":"no"'
    fi
  fi

  if ${kconfig} | grep -qi 'CONFIG_IO_STRICT_DEVMEM'; then
    echo_message "  Restrict I/O access to /dev/mem:        " "" "" ""
    if ${kconfig} | grep -qi 'CONFIG_IO_STRICT_DEVMEM=y'; then
      echo_message "\033[32mEnabled\033[m\n" "Enabled," " restrict_io_dev_mem_access='yes'" ', "restrict_io_dev_mem_access":"yes"'
    else
      echo_message "\033[31mDisabled\033[m\n" "Disabled," " restrict_io_dev_mem_access='no'" ', "restrict_io_dev_mem_access":"no"'
    fi
  fi

  if ${kconfig} | grep -qi 'CONFIG_REFCOUNT_FULL'; then
    echo_message "  Full reference count validation:        " "" "" ""
    if ${kconfig} | grep -qi 'CONFIG_REFCOUNT_FULL=y'; then
      echo_message "\033[32mEnabled\033[m\n" "Enabled," " full_refcount_validation='yes'" ', "full_refcount_validation":"yes"'
    else
      echo_message "\033[31mDisabled\033[m\n" "Disabled," " full_refcount_validation='no'" ', "full_refcount_validation":"no"'
    fi
  fi

  echo_message "  Exec Shield:                            " """" ""
  execshield=$(sysctl -n kernel.exec-shield 2> /dev/null)
  if [[ -z "${execshield}" ]]; then
    echo_message '\033[32mUnsupported\033[m\n' '' '' ''
  elif [[ "${execshield}" == "1" ]]; then
    echo_message '\033[32mEnabled\033[m\n' '' '' ''
  else
    echo_message '\033[31mDisabled\033[m\n' '' '' ''
  fi

  echo_message "  YAMA:                                   " """" ""
  yama_ptrace_scope=$(sysctl -n kernel.yama.ptrace_scope 2> /dev/null)
  if [[ -z "${yama_ptrace_scope}" ]]; then
    echo_message "\033[31mDisabled\033[m\n\n" "Disabled," " yama_ptrace_scope='disabled'" ', "yama_ptrace_scope":"disabled"'
  elif [[ "${yama_ptrace_scope}" == "0" ]]; then
    echo_message "\033[31mInactive\033[m\n\n" "Inactive," " yama_ptrace_scope='inactive'" ', "yama_ptrace_scope":"inactive"'
  else
    echo_message "\033[32mActive\033[m\n\n" "Active," " yama_ptrace_scope='active'" ', "yama_ptrace_scope":"active"'
  fi

  if ${kconfig} | grep -qi 'CONFIG_HARDENED_USERCOPY'; then
    echo_message "  Hardened Usercopy:                      " "" "" ""
    if ${kconfig} | grep -qi 'CONFIG_HARDENED_USERCOPY=y'; then
      echo_message "\033[32mEnabled\033[m\n" "Enabled," " hardened_usercopy='yes'" ', "hardened_usercopy":"yes"'
    else
      echo_message "\033[31mDisabled\033[m\n" "Disabled," " hardened_usercopy='no'" ', "hardened_usercopy":"no"'
    fi
  fi

  if ${kconfig} | grep -qi 'CONFIG_FORTIFY_SOURCE'; then
    echo_message "  Harden str/mem functions:               " "" "" ""
    if ${kconfig} | grep -qi 'CONFIG_FORTIFY_SOURCE=y'; then
      echo_message "\033[32mEnabled\033[m\n" "Enabled," " fortify_source='yes'" ', "fortify_source":"yes"'
    else
      echo_message "\033[31mDisabled\033[m\n" "Disabled," " fortify_source='no'" ', "fortify_source":"no"'
    fi
  fi

  if ${kconfig} | grep -qi 'CONFIG_DEVKMEM'; then
    echo_message "  Restrict /dev/kmem access:              " "" "" ""
    if ${kconfig} | grep -qi 'CONFIG_DEVKMEM=y'; then
      echo_message "\033[31mDisabled\033[m\n" "Disabled," " restrict_dev_kmem_access='no'" ', "restrict_dev_kmem_access":"no"'
    else
      echo_message "\033[32mEnabled\033[m\n" "Enabled," " restrict_dev_kmem_access='yes'" ', "restrict_dev_kmem_access":"yes"'
    fi
  fi

  #x86 only
  if [[ "${arch}" == "32" ]] || [[ "${arch}" == "64" ]]; then
    echo_message "\n" "\n" "" ""
    echo_message "* X86 only:            \n" "" "" ""

    if ! ${kconfig} | grep -qi 'CONFIG_PAX_SIZE_OVERFLOW=y'; then
      if ${kconfig} | grep -qi 'CONFIG_DEBUG_STRICT_USER_COPY_CHECKS'; then
        echo_message "  Strict user copy checks:                " "" "" ""
        if ${kconfig} | grep -qi 'CONFIG_DEBUG_STRICT_USER_COPY_CHECKS=y'; then
          echo_message "\033[32mEnabled\033[m\n" "Enabled," " strict_user_copy_check='yes'" ', "strict_user_copy_check":"yes"'
        else
          echo_message "\033[31mDisabled\033[m\n" "Disabled," " strict_user_copy_check='no'" ', "strict_user_copy_check":"no"'
        fi
      fi
    fi

    if ${kconfig} | grep -qi 'CONFIG_RANDOMIZE_BASE' || ${kconfig} | grep -qi 'CONFIG_PAX_ASLR'; then
      echo_message "  Address space layout randomization:     " "" "" ""
      if ${kconfig} | grep -qi 'CONFIG_RANDOMIZE_BASE=y' || ${kconfig} | grep -qi 'CONFIG_PAX_ASLR=y'; then
        echo_message "\033[32mEnabled\033[m\n" "Enabled," " random_address_space_layout='yes'" ', "random_address_space_layout":"yes"'
      else
        echo_message "\033[31mDisabled\033[m\n" "Disabled," " random_address_space_layout='no'" ', "random_address_space_layout":"no"'
      fi
    fi
  fi

  #ARM only
  if [[ "${arch}" == "arm" ]]; then
    echo_message "\n" "\n" "\n" ""
    echo_message "* ARM only:            \n" "" "" ""

    if ${kconfig} | grep -qi 'CONFIG_ARM_KERNMEM_PERMS'; then
      echo_message "  Restrict kernel memory permissions:     " "" "" ""
      if ${kconfig} | grep -qi 'CONFIG_ARM_KERNMEM_PERMS=y'; then
        echo_message "\033[32mEnabled\033[m\n" "Enabled," " arm_kernmem_perms='yes'" ', "arm_kernmem_perms":"yes"'
      else
        echo_message "\033[31mDisabled\033[m\n" "Disabled," " arm_kernmem_perms='no'" ', "arm_kernmem_perms":"no"'
      fi
    fi

    if ${kconfig} | grep -qi 'CONFIG_DEBUG_ALIGN_RODATA'; then
      echo_message "  Make rodata strictly non-excutable:     " "" "" ""
      if ${kconfig} | grep -qi 'CONFIG_DEBUG_ALIGN_RODATA=y'; then
        echo_message "\033[32mEnabled\033[m\n" "Enabled," " arm_strict_rodata='yes'" ', "arm_strict_rodata":"yes"'
      else
        echo_message "\033[31mDisabled\033[m\n" "Disabled," " arm_strict_rodata='no'" ', "arm_strict_rodata":"no"'
      fi
    fi

  fi

  #ARM64 only
  if [[ "${arch}" == "aarch64" ]]; then
    echo_message "\n" "\n" "\n" ""
    echo_message "* ARM64 only:            \n" "" "" ""

    if ${kconfig} | grep -qi 'CONFIG_UNMAP_KERNEL_AT_EL0'; then
      echo_message "  Unmap kernel in userspace (KAISER):     " "" "" ""
      if ${kconfig} | grep -qi 'CONFIG_UNMAP_KERNEL_AT_EL0=y'; then
        echo_message "\033[32mEnabled\033[m\n" "Enabled," " unmap_kernel_in_userspace='yes'" ', "unmap_kernel_in_userspace":"yes"'
      else
        echo_message "\033[31mDisabled\033[m\n" "Disabled," " unmap_kernel_in_userspace='no'" ', "unmap_kernel_in_userspace":"no"'
      fi
    fi

    if ${kconfig} | grep -qi 'CONFIG_HARDEN_BRANCH_PREDICTOR'; then
      echo_message "  Harden branch predictor:                " "" "" ""
      if ${kconfig} | grep -qi 'CONFIG_HARDEN_BRANCH_PREDICTOR=y'; then
        echo_message "\033[32mEnabled\033[m\n" "Enabled," " harden_branch_predictor='yes'" ', "harden_branch_predictor":"yes"'
      else
        echo_message "\033[31mDisabled\033[m\n" "Disabled," " harden_branch_predictor='no'" ', "harden_branch_predictor":"no"'
      fi
    fi

    if ${kconfig} | grep -qi 'CONFIG_HARDEN_EL2_VECTORS'; then
      echo_message "  Harden EL2 vector mapping:              " "" "" ""
      if ${kconfig} | grep -qi 'CONFIG_HARDEN_EL2_VECTORS=y'; then
        echo_message "\033[32mEnabled\033[m\n" "Enabled," " harden_el2_vector_mapping='yes'" ', "harden_el2_vector_mapping":"yes"'
      else
        echo_message "\033[31mDisabled\033[m\n" "Disabled," " harden_el2_vector_mapping='no'" ', "harden_el2_vector_mapping":"no"'
      fi
    fi

    if ${kconfig} | grep -qi 'CONFIG_ARM64_SSBD'; then
      echo_message "  Speculative store bypass disable:       " "" "" ""
      if ${kconfig} | grep -qi 'CONFIG_ARM64_SSBD=y'; then
        echo_message "\033[32mEnabled\033[m\n" "Enabled," " speculative_store_bypass_disable='yes'" ', "speculative_store_bypass_disable":"yes"'
      else
        echo_message "\033[31mDisabled\033[m\n" "Disabled," " speculative_store_bypass_disable='no'" ', "speculative_store_bypass_disable":"no"'
      fi
    fi

    if ${kconfig} | grep -qi 'CONFIG_ARM64_SW_TTBR0_PAN'; then
      echo_message "  Emulate privileged access never:        " "" "" ""
      if ${kconfig} | grep -qi 'CONFIG_ARM64_SW_TTBR0_PAN=y'; then
        echo_message "\033[32mEnabled\033[m\n" "Enabled," " emulate_privileged_access_never='yes'" ', "emulate_privileged_access_never":"yes"'
      else
        echo_message "\033[31mDisabled\033[m\n" "Disabled," " emulate_privileged_access_never='no'" ', "emulate_privileged_access_never":"no"'
      fi
    fi

    if ${kconfig} | grep -qi 'CONFIG_RANDOMIZE_BASE'; then
      echo_message "  Randomize address of kernel image:      " "" "" ""
      if ${kconfig} | grep -qi 'CONFIG_RANDOMIZE_BASE=y'; then
        echo_message "\033[32mEnabled\033[m\n" "Enabled," " randomize_kernel_address='yes'" ', "randomize_kernel_address":"yes"'
      else
        echo_message "\033[31mDisabled\033[m\n" "Disabled," " randomize_kernel_address='no'" ', "randomize_kernel_address":"no"'
      fi
    fi

    if ${kconfig} | grep -qi 'CONFIG_RANDOMIZE_MODULE_REGION_FULL'; then
      echo_message "  Randomize module region over 4GB:       " "" "" ""
      if ${kconfig} | grep -qi 'CONFIG_RANDOMIZE_MODULE_REGION_FULL=y'; then
        echo_message "\033[32mEnabled\033[m\n" "Enabled," " randomize_module_region_full='yes'" ', "randomize_module_region_full":"yes"'
      else
        echo_message "\033[31mDisabled\033[m\n" "Disabled," " randomize_module_region_full='no'" ', "randomize_module_region_full":"no"'
      fi
    fi
  fi

  echo_message "" "" ">" "},"

  echo_message "\n" "\n" "\n" ""
  echo_message "* SELinux:                                " "" "" ""
  if ${kconfig} | grep -qi 'CONFIG_SECURITY_SELINUX=y'; then
    getsestatus
    sestatus=$?
    if [[ ${sestatus} == 0 ]]; then
      echo_message "\033[31mDisabled\033[m\n" "Disabled,," "    <selinux enabled='no'" '"selinux":{ "enabled":"no"'
      echo_message "\n  SELinux infomation available here: \n" "" "" ""
      echo_message "    http://selinuxproject.org/\n" "" "" ""
    elif [[ ${sestatus} == 1 ]]; then
      echo_message "\033[33mPermissive\033[m\n" "Permissive," "    <selinux enabled='yes' mode='permissive'" '"selinux":{ "enabled":"yes", "mode":"permissive"'
    elif [[ ${sestatus} == 2 ]]; then
      echo_message "\033[32mEnforcing\033[m\n" "Enforcing," "    <selinux enabled='yes' mode='enforcing'" '"selinux":{ "enabled":"yes", "mode":"enforcing"'
    fi
  else
    echo_message "\033[31mNo SELinux\033[m\n" "Disabled,," "    <selinux enabled='no'" '"selinux":{ "enabled":"no"'
    echo_message "\n  SELinux infomation available here: \n" "" "" ""
    echo_message "    http://selinuxproject.org/\n" "" "" ""
  fi

  if [[ ${sestatus} == 1 ]] || [[ ${sestatus} == 2 ]]; then
    echo_message "  Checkreqprot:                         " "" "" ""
    if [[ $(cat /sys/fs/selinux/checkreqprot) == 0 ]]; then
      echo_message "\033[32m  Enabled\033[m\n" "Enabled," " checkreqprot='yes'" ', "checkreqprot":"yes"'
    else
      echo_message "\033[31m  Disabled\033[m\n" "Disabled," " checkreqprot='no'" ', "checkreqprot":"no"'
    fi

    echo_message "  Deny Unknown:                         " "" "" ""
    if [[ $(cat /sys/fs/selinux/deny_unknown) == 1 ]]; then
      echo_message "\033[32m  Enabled\033[m\n" "Enabled" " deny_unknown='yes'" ', "deny_unknown":"yes"'
    else
      echo_message "\033[31m  Disabled\033[m\n" "Disabled" " deny_unknown='no'" ', "deny_unknown":"no"'
    fi
  fi
  echo_message "\n" "\n" " />\n</kernel>\n" " }}"
}

# check mapped libraries
libcheck() {
  IFS=" " read -r -a libs <<< "$(awk '{ print $6 }' "/proc/${1}/maps" | grep '/' | sort -u | xargs file | grep ELF | awk '{ print $1 }' | sed 's/:/ /')"
  echo_message "\n* Loaded libraries (file information, # of mapped files: ${#libs[@]}):\n\n" "" "" "\"libs\": {"

  for ((element = 0; element < ${#libs[@]}; element++)); do
    echo_message "  ${libs[$element]}:\n" "${libs[$element]}," "" ""
    echo_message "    " "" "    " ""
    filecheck "${libs[$element]}"
    if [[ ${element} == $((${#libs[@]} - 1)) ]]; then
      echo_message "\n\n" "\n" " filename='${libs[$element]}' />\n" ""
    else
      echo_message "\n\n" "\n" " filename='${libs[$element]}' />\n" "},"
    fi
  done
}

# check cpu nx flag
nxcheck() {
  if grep -qFw 'nx' /proc/cpuinfo; then
    echo_message '\033[32mYes\033[m\n\n' '' '' ''
  else
    echo_message '\033[31mNo\033[m\n\n' '' '' ''
  fi
}

# check process(es)
proccheck() {
  # check for RELRO support
  if ${readelf} -l "${1}/exe" 2> /dev/null | grep -q 'Program Headers'; then
    if ${readelf} -l "${1}/exe" 2> /dev/null | grep -q 'GNU_RELRO'; then
      if ${readelf} -d "${1}/exe" 2> /dev/null | grep -q 'BIND_NOW' || ! ${readelf} -l "${1}/exe" 2> /dev/null | grep -q '\.got\.plt'; then
        echo_message '\033[32mFull RELRO   \033[m   ' 'Full RELRO,' ' relro="full"' '"relro":"full",'
      else
        echo_message '\033[33mPartial RELRO\033[m   ' 'Partial RELRO,' ' relro="partial"' '"relro":"partial",'
      fi
    else
      echo_message '\033[31mNo RELRO     \033[m   ' 'No RELRO,' ' relro="no"' '"relro":"no",'
    fi
  else
    echo -n -e '\033[31mPermission denied (please run as root)\033[m\n'
    exit 1
  fi

  # check for stack canary support
  if ${readelf} -s "${1}/exe" 2> /dev/null | grep -q 'Symbol table'; then
    if ${readelf} -s "${1}/exe" 2> /dev/null | grep " UND " | grep -Eq '__stack_chk_fail|__stack_chk_guard|__intel_security_cookie'; then
      echo_message '\033[32mCanary found         \033[m   ' 'Canary found,' ' canary="yes"' '"canary":"yes",'
    else
      echo_message '\033[31mNo canary found      \033[m   ' 'No Canary found,' ' canary="no"' '"canary":"no",'
    fi
  else
    if [[ "${1}" == "1" ]]; then
      echo_message '\033[33mPermission denied    \033[m   ' 'Permission denied,' ' canary="Permission denied"' '"canary":"Permission denied",'
    else
      echo_message '\033[33mNo symbol table found \033[m  ' 'No symbol table found,' ' canary="No symbol table found"' '"canary":"No symbol table found",'
    fi
  fi

  if ${extended_checks}; then
    # check if compiled with Clang CFI
    $debug && echo -e "\n***function proccheck->clangcfi"
    #if $readelf -s "$1" 2>/dev/null | grep -Eq '\.cfi'; then
    read -r -a cfifunc <<< "$($readelf -s "$1/exe" 2> /dev/null | grep '\.cfi' | awk '{ print $8 }')"
    func=${cfifunc/.cfi/}
    # TODO: fix this check properly, need more clang CFI files to be able to test properly
    # shellcheck disable=SC2128
    if [ -n "$cfifunc" ] && $readelf -s "$1/exe" 2> /dev/null | grep -q "$func$"; then
      echo_message '\033[32mClang CFI found   \033[m   ' 'with CFI,' ' clangcfi="yes"' '"clangcfi":"yes",'
    else
      echo_message '\033[31mNo Clang CFI found\033[m   ' 'without CFI,' ' clangcfi="no"' '"clangcfi":"no",'
    fi

    # check if compiled with Clang SafeStack
    $debug && echo -e "\n***function proccheck->safestack"
    if $readelf -s "$1/exe" 2> /dev/null | grep -Eq '__safestack_init'; then
      echo_message '\033[32mSafeStack found   \033[m   ' 'with SafeStack,' ' safestack="yes"' '"safestack":"yes",'
    else
      echo_message '\033[31mNo SafeStack found\033[m   ' 'without SafeStack,' ' safestack="no"' '"safestack":"no",'
    fi
  fi

  # check for Seccomp mode
  seccomp=$(grep 'Seccomp:' "${1}/status" 2> /dev/null | cut -b10)
  if [[ "${seccomp}" == "1" ]]; then
    echo_message '\033[32mSeccomp strict\033[m   ' 'Seccomp strict,' ' seccomp="strict"' '"seccomp":"strict",'
  elif [[ "${seccomp}" == "2" ]]; then
    echo_message '\033[32mSeccomp-bpf   \033[m   ' 'Seccomp-bpf,' ' seccomp="bpf"' '"seccomp":"bpf",'
  else
    echo_message '\033[31mNo Seccomp    \033[m   ' 'No Seccomp,' ' seccomp="no"' '"seccomp":"no",'
  fi

  # first check for PaX support
  # shellcheck disable=SC2126
  if [[ $(grep -c 'PaX:' "${1}/status" 2> /dev/null) -gt 0 ]]; then
    pageexec=$(grep 'PaX:' "${1}/status" 2> /dev/null | cut -b6)
    segmexec=$(grep 'PaX:' "${1}/status" 2> /dev/null | cut -b10)
    mprotect=$(grep 'PaX:' "${1}/status" 2> /dev/null | cut -b8)
    randmmap=$(grep 'PaX:' "${1}/status" 2> /dev/null | cut -b9)
    if [[ "${pageexec}" = "P" || "${segmexec}" = "S" ]] && [[ "${mprotect}" = "M" && "${randmmap}" = "R" ]]; then
      echo_message '\033[32mPaX enabled\033[m   ' 'Pax enabled,' ' pax="yes"' '"pax":"yes",'
    elif [[ "${pageexec}" = "p" && "${segmexec}" = "s" && "${randmmap}" = "R" ]]; then
      echo_message '\033[33mPaX ASLR only\033[m ' 'Pax ASLR only,' ' pax="aslr_only"' '"pax":"aslr_only",'
    elif [[ "${pageexec}" = "P" || "${segmexec}" = "S" ]] && [[ "${mprotect}" = "m" && "${randmmap}" = "R" ]]; then
      echo_message '\033[33mPaX mprot off \033[m' 'Pax mprot off,' ' pax="mprot_off"' '"pax":"mprot_off",'
    elif [[ "${pageexec}" = "P" || "${segmexec}" = "S" ]] && [[ "${mprotect}" = "M" && "${randmmap}" = "r" ]]; then
      echo_message '\033[33mPaX ASLR off\033[m  ' 'Pax ASLR off,' ' pax="aslr_off"' '"pax":"aslr_off",'
    elif [[ "${pageexec}" = "P" || "${segmexec}" = "S" ]] && [[ "${mprotect}" = "m" && "${randmmap}" = "r" ]]; then
      echo_message '\033[33mPaX NX only\033[m   ' 'Pax NX only,' ' pax="nx_only"' '"pax":"nx_only",'
    else
      echo_message '\033[31mPaX disabled\033[m  ' 'Pax disabled,' ' pax="no"' '"pax":"no",'
    fi
    # fallback check for NX support
  elif [[ $(${readelf} -l "${1}/exe" 2> /dev/null | grep 'GNU_STACK' | grep -oP '(?<=0x).*(?=RW )' | grep -o . | sort -u | tr -d '\n') != " 0x" ]]; then
    echo_message '\033[31mNX disabled\033[m   ' 'NX disabled,' ' nx="no"' '"nx":"no",'
  else
    echo_message '\033[32mNX enabled \033[m   ' 'NX enabled,' ' nx="yes"' '"nx":"yes",'
  fi

  # check for PIE support
  if ${readelf} -h "${1}/exe" 2> /dev/null | grep -q 'Type:[[:space:]]*EXEC'; then
    echo_message '\033[31mNo PIE               \033[m   ' 'No PIE,' ' pie="no"' '"pie":"no",'
  elif ${readelf} -h "${1}/exe" 2> /dev/null | grep -q 'Type:[[:space:]]*DYN'; then
    if ${readelf} -d "${1}/exe" 2> /dev/null | grep -q 'DEBUG'; then
      echo_message '\033[32mPIE enabled          \033[m   ' 'PIE enabled,' ' pie="yes"' '"pie":"yes",'
    else
      echo_message '\033[33mDynamic Shared Object\033[m   ' 'Dynamic Shared Object,' ' pie="dso"' '"pie":"dso",'
    fi
  else
    echo_message '\033[33mNot an ELF file      \033[m   ' 'Not an ELF file,' ' pie="not_elf"' '"pie":"not_elf",'
  fi

  if ${extended_checks}; then
    # check for selfrando support
    if ${readelf} -S "${1}/exe" 2> /dev/null | grep -c 'txtrp' | grep -q '1'; then
      echo_message '\033[32mSelfrando enabled    \033[m   '
    else
      echo_message '\033[31mNo Selfrando         \033[m   '
    fi
  fi

  #check for Fortify source support
  search_libc
  libc_found="false"
  if ${readelf} -d "$(readlink "${1}"/exe)" 2> /dev/null | grep 'NEEDED' | grep -q 'libc\.so'; then
    libc_found="true"
  fi
  Proc_FS_filechk_func_libc="$(${readelf} -s "${use_dynamic}" "${FS_libc}" 2> /dev/null | sed -ne 's/.*__\(.*_chk\)@@.*/\1/p')"
  Proc_FS_func_libc="${Proc_FS_filechk_func_libc//_chk/}"
  Proc_FS_func="$(${readelf} -s "${use_dynamic}" "${1}/exe" 2> /dev/null | awk '{ print $8 }' | sed -e 's/_*//' -e 's/@.*//' -e '/^$/d')"
  Proc_FS_cnt_checked=$(grep -cFxf <(sort -u <<< "${Proc_FS_filechk_func_libc}") <(sort -u <<< "${Proc_FS_func}"))
  Proc_FS_cnt_unchecked=$(grep -cFxf <(sort -u <<< "${Proc_FS_func_libc}") <(sort -u <<< "${Proc_FS_func}"))
  Proc_FS_cnt_total=$((Proc_FS_cnt_unchecked + Proc_FS_cnt_checked))

  if [[ "${libc_found}" == "false" ]] || [[ "${Proc_FS_cnt_total}" -eq "0" ]]; then
    echo_message "\033[32mN/A\033[m" "N/A," ' fortify_source="n/a">' '"fortify_source":"n/a" }'
  elif [[ "${Proc_FS_cnt_checked}" -eq "0" ]]; then
    echo_message "\033[31mNo\033[m" "No," ' fortify_source="no">' '"fortify_source":"no" }'
  else
    echo_message '\033[32mYes\033[m' 'Yes,' ' fortify_source="yes">' '"fortify_source":"yes" }'
  fi
}

#openssl public key for verification of updates
read -r PUBKEY << EOF
LS0tLS1CRUdJTiBQVUJMSUMgS0VZLS0tLS0KTUlJQklqQU5CZ2txaGtpRzl3MEJBUUVGQUFPQ0FROEFNSUlCQ2dLQ0FRRUF3Z25kcnk2WGJpNE8wR2w1T2UzSQp1eWRyMlZqR1hteDJFM0thd0wrK1F3a2FVT0RHOEVuT24weFZ1S1ZkZEphZjY3Rmxzd3pPYjh1RFRDTjdsWURnCnFKQXdmNllTOUFsdU5RRmlFQWhFRlgxL0dsMi9TSnFHYXhFVU9HTlV3NTI5a3BVR0MwNmN6SHhENEcvdWNBQlkKT05iWm9Vc1pIYmRnZUNueWs1dzZ0SWs3MEplNmZ2em5Da2JxbUZhS0UyQnhWTERLU0liSDBTak5XT3RSMmF6ZAp1V3p2RU1kVXFlZlZjYXErUDFjV0dLNy94VllSNkV3ME1aQTdWU0xkREhlRUVySW9Kc3UvM2VaeUR5ZDlaUlJvCmdpajM2R1N2SFREclU1ZVdXRlN0Q01UM29DRDhMSjVpbXBReWpWd3Z5M3Z4ZVNVYzVkdytZUDU0OU9jNHF2bzYKOXdJREFRQUIKLS0tLS1FTkQgUFVCTElDIEtFWS0tLS0tCg==
EOF

# Update/Upgrade
# shellcheck disable=SC2120
upgrade() {
  if ${pkg_release}; then
    printf "\033[31mError: Unknown option '%s'.\033[m\n\n" "${1}"
    help
    exit 1
  fi
  umask 027
  TMP_FILE=$(mktemp /tmp/checksec.XXXXXXXXXX)
  SIG_FILE=$(mktemp /tmp/checksec_sig.XXXXXXXX)
  PUBKEY_FILE=$(mktemp /tmp/checksec_pubkey.XXXXXXXXXX)
  fetch "${SCRIPT_URL}" "${TMP_FILE}"
  fetch "${SIG_URL}" "${SIG_FILE}"
  echo "${PUBKEY}" | base64 -d > "${PUBKEY_FILE}"
  if ! openssl dgst -sha256 -verify "${PUBKEY_FILE}" -signature "${SIG_FILE}" "${TMP_FILE}" > /dev/null 2>&1; then
    echo "file signature does not match. Update may be tampered"
    rm -f "${TMP_FILE}" "${SIG_FILE}" "${PUBKEY_FILE}" > /dev/null 2>&1
    exit 1
  fi
  UPDATE_VERSION=$(grep "^SCRIPT_VERSION" "${TMP_FILE}" | awk -F"=" '{ print $2 }')
  if [[ "${SCRIPT_VERSION}" != "${UPDATE_VERSION}" ]]; then
    PERMS=$(stat -c "%a" "$0")
    rm -f "${SIG_FILE}" "${PUBKEY_FILE}" > /dev/null 2>&1
    mv "${TMP_FILE}" "$0" > /dev/null 2>&1
    exit_status=$?
    if [[ "${exit_status}" -eq "0" ]]; then
      echo "checksec.sh updated - Rev. ${UPDATE_VERSION}"
      chmod "${PERMS}" "${0}"
    else
      echo "Error: Could not update... Please check permissions"
      rm -f "${TMP_FILE}" > /dev/null 2>&1
      exit 1
    fi
  else
    echo "checksec.sh not updated... Already on latest version"
    rm -f "${TMP_FILE}" "${SIG_FILE}" "${PUBKEY_FILE}" > /dev/null 2>&1
    exit 1
  fi
}

# Version compare
vercomp() {
  if [[ "${1}" == "${2}" ]]; then
    return 0
  fi
  local IFS=.
  local i ver1="${1}" ver2="${2}"
  # fill empty fields in ver1 with zeros
  for ((i = ${#ver1[@]}; i < ${#ver2[@]}; i++)); do
    ver1[i]=0
  done
  for ((i = 0; i < ${#ver1[@]}; i++)); do
    if [[ -z ${ver2[i]} ]]; then
      # fill empty fields in ver2 with zeros
      ver2[i]=0
    fi
    if ((10#${ver1[i]} > 10#${ver2[i]})); then
      return 1
    fi
    if ((10#${ver1[i]} < 10#${ver2[i]})); then
      return 2
    fi
  done
  return 0
}

# Fetch the update
fetch() {
  if type wget > /dev/null 2>&1; then
    wget --no-check-certificate -O "${2}" "${1}" > /dev/null 2>&1
  elif type curl > /dev/null 2>&1; then
    curl --insecure --remote-name -o "${2}" "${1}" > /dev/null 2>&1
  else
    echo 'Warning: Neither wget nor curl is available. online updates unavailable' >&2
    exit 1
  fi
}

# version information
version() {
  echo "checksec v${SCRIPT_MAJOR}.${SCRIPT_MINOR}.${SCRIPT_REVISION}, Brian Davis, github.com/slimm609/checksec.sh, Dec 2015"
  echo "Based off checksec v1.5, Tobias Klein, www.trapkit.de, November 2011"
  echo
}

# run help if nothing is passed
if [[ $# -lt 1 ]]; then
  help
  exit 1
fi

optspec=":h-:"
while getopts "${optspec}" optchar; do
  case "${optchar}" in
    -)
      case "${OPTARG}" in
        version)
          version
          exit 0
          ;;
        debug)
          debug=true
          ;;
        trace)
          export BASH_XTRACEFD=5
          export PS4='(${BASH_SOURCE##*/}:${LINENO}): ${FUNCNAME[0]:+${FUNCNAME[0]}(): }'
          set -x
          ;;
        help)
          help
          exit 0
          ;;
        debug_report)
          debug_report
          exit 0
          ;;
        update | upgrade)
          # shellcheck disable=SC2119
          upgrade
          exit 0
          ;;
        format=* | output=*)
          output_format=${OPTARG#*=}
          format
          ;;
        verbose)
          verbose=true
          ;;
        extended)
          extended_checks=true
          ;;
        dir=*)
          CHK_DIR=${OPTARG#*=}
          OPT=$((OPT + 1))
          CHK_FUNCTION="chk_dir"
          ;;
        file=*)
          CHK_FILE=${OPTARG#*=}
          OPT=$((OPT + 1))
          CHK_FUNCTION="chk_file"
          ;;
        listfile=*)
          CHK_FILE_LIST=${OPTARG#*=}
          OPT=$((OPT + 1))
          CHK_FUNCTION="chk_file_list"
          ;;
        libcfile=*)
          LIBC_FILE=${OPTARG#*=}
          echo LIBC_FILE="${LIBC_FILE}"
          ;;
        proc-all)
          OPT=$((OPT + 1))
          CHK_FUNCTION="chk_proc_all"
          ;;
        proc=*)
          CHK_PROC=${OPTARG#*=}
          OPT=$((OPT + 1))
          CHK_FUNCTION="chk_proc"
          ;;
        proc-libs=*)
          CHK_PROC_LIBS=${OPTARG#*=}
          OPT=$((OPT + 1))
          CHK_FUNCTION="chk_proc_libs"
          ;;
        fortify-file=*)
          CHK_FORTIFY_FILE=${OPTARG#*=}
          OPT=$((OPT + 1))
          CHK_FUNCTION="chk_fortify_file"
          ;;
        fortify-proc=*)
          CHK_FORTIFY_PROC=${OPTARG#*=}
          OPT=$((OPT + 1))
          CHK_FUNCTION="chk_fortify_proc"
          ;;
        kernel=*)
          CHK_KERNEL=${OPTARG#*=}
          OPT=$((OPT + 1))
          CHK_FUNCTION="chk_kernel"
          ;;
        kernel)
          OPT=$((OPT + 1))
          CHK_FUNCTION="chk_kernel"
          ;;
        *)
          printf "\033[31mError: Unknown option %s.\033[m\n\n" "${OPTARG}"
          exit 1
          ;;
      esac
      ;;
    *)
      help
      exit 0
      ;;
  esac
done

if [[ "${OPT}" == 0 ]]; then
  printf "\033[31mError: No option selected. Please select an option.\033[m\n\n"
  exit 1
elif [[ "${OPT}" != 1 ]]; then
  printf "\033[31mError: To many options selected. Please select one at a time.\033[m\n\n"
  exit 1
fi

for variable in CHK_DIR CHK_FILE CHK_FORTIFY_FILE CHK_FORTIFY_PROC CHK_PROC CHK_PROC_LIBS; do
  if [[ -n ${!variable+x} ]]; then
    if [[ -z "${!variable}" ]]; then
      printf "\033[31mError: Option Required.\033[m\n\n"
      help
      exit 1
    fi
  fi
done

# call the function
${CHK_FUNCTION}
