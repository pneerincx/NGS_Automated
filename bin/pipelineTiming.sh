#!/bin/bash

set -e
set -u


# module load NGS_Automated/beta; pipelineTiming.sh -g umcg-atd -s gattaca01.gcc.rug.nl -r /groups/umcg-atd/scr01/ -l DEBUG

#
##      This script will run on Leucine-zipper or zinc-finger. First it will pull the project files, from projects from whom the demultiplex pipeline is fished.
###     And then it will check if the run0*.pipeline.started is older than 6h, *.generateScripts.started is older than 5h and the *.copyProjectDataToPrm.finished is older than 5(last time it was modified). 
####    If the .started is not older than 5 or 6h, no worries the pipeline is probably still running.
####    If there is no .started file it will check if there is a .finished file. If there is a .fished file, no worries, the pipeline is fished. 
###    
## 

if [[ "${BASH_VERSINFO}" -lt 4 || "${BASH_VERSINFO[0]}" -lt 4 ]]
then
    echo "Sorry, you need at least bash 4.x to use ${0}." >&2
    exit 1
fi


# Env vars.
export TMPDIR="${TMPDIR:-/tmp}" # Default to /tmp if $TMPDIR was not defined.
SCRIPT_NAME="$(basename ${0})"
SCRIPT_NAME="${SCRIPT_NAME%.*sh}"
INSTALLATION_DIR="$(cd -P "$(dirname "${0}")/.." && pwd)"
LIB_DIR="${INSTALLATION_DIR}/lib"
CFG_DIR="${INSTALLATION_DIR}/etc"
HOSTNAME_SHORT="$(hostname -s)"
ROLE_USER="$(whoami)"
REAL_USER="$(logname 2>/dev/null || echo 'no login name')"


#
##
### Functions.
##
#

if [[ -f "${LIB_DIR}/sharedFunctions.bash" && -r "${LIB_DIR}/sharedFunctions.bash" ]]
then
    source "${LIB_DIR}/sharedFunctions.bash"
else
    printf '%s\n' "FATAL: cannot find or cannot access sharedFunctions.bash"
    exit 1
fi

function showHelp() {
        #
        # Display commandline help on STDOUT.
        #
        cat <<EOH
======================================================================================================================
Script to start NGS_Demultiplexing automagicly when sequencer is finished, and corresponding samplesheet is available.

Usage:

        $(basename $0) OPTIONS

Options:

        -h   Show this help.
        -g   Group.
        -l   Log level.
                Must be one of TRACE, DEBUG, INFO (default), WARN, ERROR or FATAL.
        -s   Source server address from where the rawdate will be fetched
                Must be a Fully Qualified Domain Name (FQDN).
                E.g. gattaca01.gcc.rug.nl or gattaca02.gcc.rug.nl
        -r   Root dir on the server specified with -s and from where the raw data will be fetched (optional).
                By default this is the SCR_ROOT_DIR variable, which is compiled from variables specified in the
                <group>.cfg, <source_host>.cfg and sharedConfig.cfg config files (see below.)
                You need to override SCR_ROOT_DIR when the data is to be fetched from a non default path,
                which is for example the case when fetching data from another group.
Config and dependencies:

    This script needs 3 config files, which must be located in ${CFG_DIR}:
     1. <group>.cfg     for the group specified with -g
     2. <this_host>.cfg        for this server. E.g.:"${HOSTNAME_SHORT}.cfg"
     3. <source_host>.cfg for the source server. E.g.: "<hostname>.cfg" (Short name without domain)
     4. sharedConfig.cfg  for all groups and all servers.
    In addition the library sharedFunctions.bash is required and this one must be located in ${LIB_DIR}.

======================================================================================================================

EOH
        trap - EXIT
        exit 0
}


#
##
### Main.
##
#

#
# Get commandline arguments.
#
log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Parsing commandline arguments..."
declare group=''
declare sourceServerFQDN=''
declare sourceServerRootDir=''

while getopts "g:l:s:r:h" opt
do
        case $opt in
                h)
                        showHelp
                        ;;
                g)
                        GROUP="${OPTARG}"
                        ;;
                s)
                        sourceServerFQDN="${OPTARG}"
                        sourceServer="${sourceServerFQDN%%.*}"
                        ;;
                r)
                        sourceServerRootDir="${OPTARG}"
                        ;;
                l)
                        l4b_log_level=${OPTARG^^}
                        l4b_log_level_prio=${l4b_log_levels[${l4b_log_level}]}
                        ;;
                \?)
                        log4Bash "${LINENO}" "${FUNCNAME:-main}" '1' "Invalid option -${OPTARG}. Try $(basename $0) -h for help."
                        ;;
                :)
                        log4Bash "${LINENO}" "${FUNCNAME:-main}" '1' "Option -${OPTARG} requires an argument. Try $(basename $0) -h for help."
                        ;;
        esac
done

#
# Check commandline options.
#
if [[ -z "${GROUP:-}" ]]
then
        log4Bash 'FATAL' "${LINENO}" "${FUNCNAME:-main}" '1' 'Must specify a group with -g.'
fi
if [[ -z "${sourceServerFQDN:-}" ]]
then
log4Bash 'FATAL' "${LINENO}" "${FUNCNAME:-main}" '1' 'Must specify a Fully Qualified Domain Name (FQDN) for sourceServer with -s.'
fi

#
# Source config files.
#
log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Sourcing config files..."
declare -a configFiles=(
        "${CFG_DIR}/${GROUP}.cfg"
        "${CFG_DIR}/${HOSTNAME_SHORT}.cfg"
        "${CFG_DIR}/${sourceServer}.cfg"
        "${CFG_DIR}/sharedConfig.cfg"
        "${HOME}/molgenis.cfg"
)

for configFile in "${configFiles[@]}"; do 
        if [[ -f "${configFile}" && -r "${configFile}" ]]
        then
                log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Sourcing config file ${configFile}..."
                #
                # In some Bash versions the source command does not work properly with process substitution.
                # Therefore we source a first time with process substitution for proper error handling
                # and a second time without just to make sure we can use the content from the sourced files.
                #
                mixed_stdouterr=$(source ${configFile} 2>&1) || log4Bash 'FATAL' ${LINENO} "${FUNCNAME:-main}" ${?} "Cannot source ${configFile}."
                source ${configFile}  # May seem redundant, but is a mandatory workaround for some Bash versions.
        else
                log4Bash 'FATAL' "${LINENO}" "${FUNCNAME:-main}" '1' "Config file ${configFile} missing or not accessible."
        fi
done

#
# Overrule group's SCR_ROOT_DIR if necessary.
#
if [[ ! -z "${sourceServerRootDir:-}" ]]
then
    SCR_ROOT_DIR="${sourceServerRootDir}"
    log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Using alternative sourceServerRootDir ${sourceServerRootDir} as SCR_ROOT_DIR."
fi


#
# Make sure to use an account for cron jobs and *without* write access to prm storage.
#
if [[ "${ROLE_USER}" != "${ATEAMBOTUSER}" ]]
then
        log4Bash 'FATAL' "${LINENO}" "${FUNCNAME:-main}" '1' "This script must be executed by user ${ATEAMBOTUSER}, but you are ${ROLE_USER} (${REAL_USER})."
fi

run='run01'
logsDir="${TMP_ROOT_DIR}/logs/"
projectStartDir="${TMP_ROOT_DIR}/logs/Timestamp" 

rsync -av ${sourceServerFQDN}:"${SCR_ROOT_DIR}/logs/Timestamp/*.csv" "${projectStartDir}" 

for projectSheet in $(ls "${projectStartDir}")
do 

    project=$(basename "${projectSheet}" .csv)
    
    if [[ ! -d "${logsDir}/${project}/" ]]
    then
        continue
    fi
    
    ## step 1, checks the generatedScirps
    if [ -e "${logsDir}/${project}/${run}.generateScripts.finished" ]
    then    
        echo "generatedScripts is finisched"
        echo "${TMP_ROOT_DIR}/logs/${project}/${run}.${SCRIPT_NAME}.finished"
    else
        timeStampGeneratedScripts=$(find "${logsDir}/${project}/" -type f -mmin +300 -iname "${run}.generateScripts.started")
        if [[ -z "${timeStampGeneratedScripts}" ]]
        then
            echo "generatedScipts has not started jet or is running"
            continue
        else
            echo "generatedScripts.started file is OLDER than 5 hour."
            echo "${TMP_ROOT_DIR}/logs/${project}/${run}.generateScriptsTiming.failed"
            echo -e "Dear GCC helpdesk,\n\nPlease check if there is somethink wrong with the pipeline.\nThe generatedScripts step for project ${project} is not finished after 5h.\n\nKind regards\nGCC" > "${TMP_ROOT_DIR}/logs/${project}/${run}.generateScriptsTiming.failed"
            continue
        fi
    fi
    echo "generatedScripts finished for project ${project}"
    
    ## step 2, checks the pipeline
    if [ -e "${logsDir}/${project}/${run}.pipeline.finished" ]
    then
        echo "pipeline is finisched"
        echo "${TMP_ROOT_DIR}/logs/${project}/${run}.${SCRIPT_NAME}.finisched"
    else
        timeStampPipeline=$(find "${logsDir}/${project}/" -type f -mmin +360 -iname "${run}.pipeline.started")
        if [[ -z "${timeStampPipeline}" ]]
        then
            echo "pipeline is has not started jet or is still running"
            continue
        else
            echo "pipeline.started file is OLDER than 6 hour."
            echo "${TMP_ROOT_DIR}/logs/${project}/${run}.${SCRIPT_NAME}.failed"
            echo -e "Dear GCC helpdesk,\n\nPlease check if there is somethink wrong with the pipeline.\nThe pipeline for project ${project} is not finished after 6h.\n\nKind regards\nGCC" > "${TMP_ROOT_DIR}/logs/${project}/${run}.${SCRIPT_NAME}.failed"
            continue
        fi
    fi 
    echo "pipeline finished for project ${project}"
    
    ## step 3, check the copyProjectDataPrm
    if [ -e "${logsDir}/${project}/${run}.copyProjectDataPrm.finished" ]
    then
        echo "copyProjectDataPrm is finisched"
        echo "${TMP_ROOT_DIR}/logs/${project}/${run}.${SCRIPT_NAME}.finisched"
    else
        timeStampCopyProjectDataToPrm=$(find "${logsDir}/${project}/" -type f -mmin +300 -iname "${run}.copyProjectDataPrm.started")
        if [[ -z "${timeStampCopyProjectDataToPrm}" ]]
        then
            echo "copyProjectDataToPrm has not started jet, or is running"
            continue
        else
            echo "copyProjectDataPrm.started file is OLDER than 5 hour."
            echo "${TMP_ROOT_DIR}/logs/${project}/${run}.copyProjectDataPrmTiming.failed"
            echo -e "Dear GCC helpdesk,\n\nPlease check if there is somethink wrong with the pipeline.\nThe copyProjectDataPrm has started but is not finished after 6h for project ${project}.\n\nKind regards\nGCC" > "${TMP_ROOT_DIR}/logs/${project}/${run}.copyProjectDataPrmTiming.failed"
            continue
        fi
    fi

    echo "copyProjectDataToPrm finished for project ${project}"
    $(ssh ${sourceServerFQDN} "mv ${SCR_ROOT_DIR}/logs/Timestamp/${projectSheet} ${SCR_ROOT_DIR}/logs/Timestamp/archive/")
    mv "${projectStartDir}/${projectSheet}" "${projectStartDir}/archive/"
done

trap - EXIT
exit 0
