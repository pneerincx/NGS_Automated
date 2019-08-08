#!/bin/bash

#
##
### Environment and Bash sanity.
##
#
if [[ "${BASH_VERSINFO}" -lt 4 || "${BASH_VERSINFO[0]}" -lt 4 ]]
then
	echo "Sorry, you need at least bash 4.x to use ${0}." >&2
	exit 1
fi

set -e # Exit if any subcommand or pipeline returns a non-zero exit status.
set -u # Raise exception if variable is unbound. Combined with set -e will halt execution when an unbound variable is encountered.
set -o pipefail # Fail when any command in series of piped commands failed as opposed to only when the last command failed.

umask 0027

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
	trap - EXIT
	exit 1
fi

function showHelp() {
	#
	# Display commandline help on STDOUT.
	#
	cat <<EOH
===============================================================================================================
Script to copy (sync) data from a succesfully finished analysis project from tmp to prm storage.

Usage:

	$(basename $0) OPTIONS

Options:

	-h   Show this help.
	-g   Group.
	-n   Dry-run: Do not perform actual sync, but only list changes instead.
	-l   Log level.
		Must be one of TRACE, DEBUG, INFO (default), WARN, ERROR or FATAL.

Config and dependencies:

	This script needs 3 config files, which must be located in ${CFG_DIR}:
	1. <group>.cfg       for the group specified with -g
	2. <host>.cfg        for this server. E.g.:"${HOSTNAME_SHORT}.cfg"
	3. sharedConfig.cfg  for all groups and all servers.
	In addition the library sharedFunctions.bash is required and this one must be located in ${LIB_DIR}.
===============================================================================================================

EOH
	trap - EXIT
	exit 0
}

function rsyncProjectRun() {
	local _project="${1}"
	local _run="${2}"
	local _sampleType=${3}

	#
	# Determine whether an rsync is required for this run, which is the case when
	#  1. either the pipeline has finished and this copy script has not
	#  2. or when a pipeline has updated the results after a previous execution of this script. 
	#
	# Temporarily check for "${TMP_ROOT_DIR}/logs/${_project}/${_project}.pipeline.finished"
	#        in addition to "${TMP_ROOT_DIR}/logs/${_project}/${_run}.pipeline.finished"
	# for backwards compatibility with old NGS_Automated 1.x.
	#
	local _pipelineFinished='false'
	local _rsyncRequired='false'
	mkdir -m 2770 -p "${PRM_ROOT_DIR}/logs/${_project}/"
	if ssh ${DATA_MANAGER}@${HOSTNAME_TMP} test -e "${TMP_ROOT_DIAGNOSTICS_DIR}/logs/${_project}/${_run}.calculateProjectMd5s.finished"
	then
		_rsyncRequired='true'
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "Processing ${_project}/${_run}"
	else
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "No *.calculateProjectMd5s.finished present."
	fi

	log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Rsync required = ${_rsyncRequired}."
	if [[ "${_rsyncRequired}" == 'false' ]]
	then
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "Skipping ${_project}/${_run}."
		return
	else
		log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "Processing ${_project}/${_run}..." \
		2>&1 | tee -a "${JOB_CONTROLE_FILE_BASE}.started"
		echo "started: $(date +%FT%T%z)" > "${JOB_CONTROLE_FILE_BASE}.totalRunTime"

	fi

	#
	# Track and Trace: log that we will start rsyncing to prm.
	#
	local _url="https://${MOLGENISSERVER}/menu/track&trace/dataexplorer?entity=status_jobs&mod=data&query%5Bq%5D%5B0%5D%5Boperator%5D=SEARCH&query%5Bq%5D%5B0%5D%5Bvalue%5D=${_project}"
	printf '%s\n' "project,run_id,pipeline,url,copy_results_prm,date"  > "${JOB_CONTROLE_FILE_BASE}.trackAndTrace.csv"
	printf '%s\n' "${_project},${_project},${_sampleType},${_url},started,"      >> "${JOB_CONTROLE_FILE_BASE}.trackAndTrace.csv"
	trackAndTracePostFromFile 'status_projects' 'update'                 "${JOB_CONTROLE_FILE_BASE}.trackAndTrace.csv"

	#
	# Count the number of all files produced in this analysis run.
	#
	local _countFilesProjectRunDirTmp=$(ssh ${DATA_MANAGER}@${HOSTNAME_TMP} "find ${TMP_ROOT_DIAGNOSTICS_DIR}/projects/${_project}/${_run}/results/* -type f -o -type l | wc -l")

	# Perform rsync.
	#  1. For ${_run} dir: recursively with "default" archive (-a),
	#     which checks for differences based on file size and modification times.
	#     No need to use checksums here as we will verify checksums later anyway.
	#  2. For ${_run}.md5 list of checksums with archive (-a) and -c to determine 
	#     differences based on checksum instead of file size and modification time.
	#     It is vitally important (and computationally cheap) to make sure 
	#     the list of checksums is complete and up-to-date!
	#
	# ToDo: Do we need to add --delete to get rid of files that should no longer be there 
	#       if an analysis run got updated?
	#
	local _transferSoFarSoGood='true'
	echo "working on ${_project}/${_run}" > "${lockFile}"
	log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "Rsyncing ${_project}/${_run} dir..." \
	2>&1 | tee -a "${JOB_CONTROLE_FILE_BASE}.started" 
	rsync -av --progress --log-file="${JOB_CONTROLE_FILE_BASE}.started" --chmod='Du=rwx,Dg=rsx,Fu=rw,Fg=r,o-rwx' ${dryrun:-} \
		"${DATA_MANAGER}@${HOSTNAME_TMP}:${TMP_ROOT_DIAGNOSTICS_DIR}/projects/${_project}/${_run}" \
		"${PRM_ROOT_DIR}/projects/${_project}/" \
	|| {
		mv "${JOB_CONTROLE_FILE_BASE}."{started,failed}
		log4Bash 'ERROR' ${LINENO} "${FUNCNAME:-main}" ${?} "Failed to rsync ${DATA_MANAGER}@${HOSTNAME_TMP}:${TMP_ROOT_DIAGNOSTICS_DIR}/projects/${_project}/${_run} dir. See ${JOB_CONTROLE_FILE_BASE}.failed for details."
		echo "Ooops! $(date '+%Y-%m-%d-T%H%M'): rsync failed. See ${JOB_CONTROLE_FILE_BASE}.failed for details." \
			>> "${JOB_CONTROLE_FILE_BASE}.failed" \
		_transferSoFarSoGood='false'
		}
	
	log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "Rsyncing ${_project}/${_run}.md5 checksums..."
	rsync -acv --progress --log-file="${JOB_CONTROLE_FILE_BASE}.started" --chmod='Du=rwx,Dg=rsx,Fu=rw,Fg=r,o-rwx' ${dryrun:-} \
		"${DATA_MANAGER}@${HOSTNAME_TMP}:${TMP_ROOT_DIAGNOSTICS_DIR}/projects/${_project}/${_run}.md5" \
		"${PRM_ROOT_DIR}/projects/${_project}/" \
	|| {
		mv "${JOB_CONTROLE_FILE_BASE}."{started,failed}
		log4Bash 'ERROR' ${LINENO} "${FUNCNAME:-main}" ${?} "Failed to rsync ${DATA_MANAGER}@${HOSTNAME_TMP}:${TMP_ROOT_DIAGNOSTICS_DIR}/projects/${_project}/${_run}.md5. See ${JOB_CONTROLE_FILE_BASE}.failed for details."
		echo "Ooops! $(date '+%Y-%m-%d-T%H%M'): rsync failed. See ${JOB_CONTROLE_FILE_BASE}.failed for details." \
			>> "${JOB_CONTROLE_FILE_BASE}.failed" \
		_transferSoFarSoGood='false'
		}
	
	#
	# Sanity check.
	#
	#  1. Firstly do a quick count of the amount of files to make sure we are complete.
	#     (No need to waist a lot of time on computing checksums for a partially failed transfer).
	#  2. Secondly verify checksums on the destination.
	#
	if [[ "${_transferSoFarSoGood}" == 'true' ]]
	then
		local _countFilesProjectRunDirPrm=$(find ${PRM_ROOT_DIR}/projects/${_project}/${_run}/results/* -type f -o -type l | wc -l)
		if [[ ${_countFilesProjectRunDirTmp} -ne ${_countFilesProjectRunDirPrm} ]]
		then

			find "${PRM_ROOT_DIR}/projects/${_project}/${_run}/results/*" -type f -o -type l | sort -V > "${JOB_CONTROLE_FILE_BASE}.countPrmFiles.txt"
			ssh ${DATA_MANAGER}@${HOSTNAME_TMP} "find ${TMP_ROOT_DIAGNOSTICS_DIR}/projects/${_project}/${_run}/results/* -type f -o -type l | sort -V" > "${JOB_CONTROLE_FILE_BASE}.countTmpFiles.txt"

			echo "diff -q ${JOB_CONTROLE_FILE_BASE}.countPrmFiles.txt ${JOB_CONTROLE_FILE_BASE}.countTmpFiles.txt" >> "${JOB_CONTROLE_FILE_BASE}.started"
			echo "Ooops! $(date '+%Y-%m-%d-T%H%M'): Amount of files for ${_project}/${_run} on tmp (${_countFilesProjectRunDirTmp}) and prm (${_countFilesProjectRunDirPrm}) is NOT the same!" \
				>> "${JOB_CONTROLE_FILE_BASE}.started"
			log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' \
				"Amount of files for ${_project}/${_run} on tmp (${_countFilesProjectRunDirTmp}) and prm (${_countFilesProjectRunDirPrm}) is NOT the same!"
			_checksumVerification='FAILED'

		else
			log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' \
				"Amount of files on tmp and prm is the same for ${_project}/${_run}: ${_countFilesProjectRunDirPrm}."
			#
			# Verify checksums on prm storage.
			#
			local _checksumVerification='unknown'
			log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' \
				"Started verification of checksums by using checksums from ${PRM_ROOT_DIR}/projects/${_project}/${_run}.md5."
			cd ${PRM_ROOT_DIR}/projects/${_project}/
			if md5sum -c ${_run}.md5 > ${_run}.md5.log 2>&1
			then
				cd "${PRM_ROOT_DIR}/concordance/${PRMRAWDATA}/"
				declare -a files=($(find "${PRM_ROOT_DIR}/projects/${_project}/${_run}/results/${CONCORDANCEFILESPATH}" -mindepth 1 -maxdepth 1 \( -type l -o -type f \) -name "${CONCORDANCEFILESEXTENSION}"))
				for i in "${files[@]}"
				do
					if [ "${_sampleType}" == 'GAP' ]
					then

						sd=$(cat "${i}.sd")
						if [[ "${sd}" < '0.2' ]]
						then
							ln -sf "${i}"
						else
							log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' \
                                                        "SD for ${i} is higher than 0.2, skipped"
						fi
					else
						log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' \
                                                        "make symlinks for concordancecheck"
						ln -sf "${i}"
					fi
				done
				echo "removing symlink for project"
				rm -f "${PRM_ROOT_DIR}/concordance/${PRMRAWDATA}/${_project}.final.vcf.gz"
				cd -
				if [ "${_sampleType}" == 'GAP' ]
				then
					echo "Array RUN! making symlinks for DiagnosticOutput"
					cd "/groups/${GROUP}/${DAT_DISK}/DiagnosticOutput/"
					windowsPathDelimeter="\\"

					callrate=$(ls "${PRM_ROOT_DIR}/projects/${_project}/${_run}/results/Callrates_${_project}.txt")
					echo "\\\\zkh\appdata\medgen\leucinezipper${callrate//\//$windowsPathDelimeter}" > "Callrates_${_project}.txt"
					unix2dos "Callrates_${_project}.txt"

					penncnvproject=$(ls "${PRM_ROOT_DIR}/projects/${_project}/${_run}/results/${_project}_PennCNV.txt")
					echo "\\\\zkh\appdata\medgen\leucinezipper${penncnvproject//\//$windowsPathDelimeter}" > "${_project}_PennCNV.txt"
					unix2dos "${_project}_PennCNV.txt"
					log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "${PRM_ROOT_DIR}/projects/${_project}/${_run}/results/PennCNV_reports/"
					if [ -d  "${PRM_ROOT_DIR}/projects/${_project}/${_run}/results/PennCNV_reports/" ]
					then
						declare -a pennCNVFiles=($(find "${PRM_ROOT_DIR}/projects/${_project}/${_run}/results/PennCNV_reports/" -name "*.txt"))
						log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "number of PennCNV files: ${#pennCNVFiles[@]}"
						for pennCnv in ${pennCNVFiles[@]}
						do
							name=$(basename "${pennCnv}")
							convertedPennCNV=${pennCnv//\//$windowsPathDelimeter}
							echo "\\\\zkh\appdata\medgen\leucinezipper${pennCnv//\//$windowsPathDelimeter}" > "/groups/${GROUP}/${DAT_DISK}/DiagnosticOutput/perSample/${name}"
							unix2dos "/groups/${GROUP}/${DAT_DISK}/DiagnosticOutput/perSample/${name}"
						done
					fi
					cd -
				fi

				echo "The results can be found in: ${PRM_ROOT_DIR}." >> "${JOB_CONTROLE_FILE_BASE}.started"
				echo "OK! $(date '+%Y-%m-%d-T%H%M'): checksum verification succeeded. See ${PRM_ROOT_DIR}/projects/${_project}/${_run}.md5.log for details." \
				>>    "${JOB_CONTROLE_FILE_BASE}.started" \
				&& rm -f "${JOB_CONTROLE_FILE_BASE}.failed" \
				&& mv "${JOB_CONTROLE_FILE_BASE}."{started,finished}
				log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' 'Checksum verification succeeded.'
			else
				mv "${JOB_CONTROLE_FILE_BASE}."{started,failed}
				echo "Ooops! $(date '+%Y-%m-%d-T%H%M'): checksum verification failed. See ${PRM_ROOT_DIR}/logs/${_project}/${_run}.md5.failed.log for details." \
				>> "${JOB_CONTROLE_FILE_BASE}.failed"
				log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' "Checksum verification failed. See ${PRM_ROOT_DIR}/projects/${_project}/${_run}.md5.log for details."
			fi
			cd -

		fi

	fi

	#
	# Report status to track & trace.
	#
	if [[ -e "${JOB_CONTROLE_FILE_BASE}.failed" ]]; then
		log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' "Found ${JOB_CONTROLE_FILE_BASE}.failed. Setting track & trace state to failed :(."
		_url="https://${MOLGENISSERVER}/menu/track&trace/dataexplorer?entity=status_jobs&mod=data&query%5Bq%5D%5B0%5D%5Boperator%5D=SEARCH&query%5Bq%5D%5B0%5D%5Bvalue%5D=${_project}"
		printf '%s\n' "project,run_id,pipeline,url,copy_results_prm,date"  > "${JOB_CONTROLE_FILE_BASE}.trackAndTrace.csv"
		printf '%s\n' "${_project},${_project},DNA,${_url},failed,"       >> "${JOB_CONTROLE_FILE_BASE}.trackAndTrace.csv"
		trackAndTracePostFromFile 'status_projects' 'update'            "${JOB_CONTROLE_FILE_BASE}.trackAndTrace.csv"
	elif [[ -e "${JOB_CONTROLE_FILE_BASE}.finished" ]]; then
		echo "Project/run ${_project}/${_run} is ready. The data is available at ${PRM_ROOT_DIR}/projects/." \
			>> "${JOB_CONTROLE_FILE_BASE}.finished"
		log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "Found ${JOB_CONTROLE_FILE_BASE}.finished. Setting track & trace state to finished :)."
		_url="https://${MOLGENISSERVER}/menu/track&trace/dataexplorer?entity=status_jobs&mod=data&query%5Bq%5D%5B0%5D%5Boperator%5D=SEARCH&query%5Bq%5D%5B0%5D%5Bvalue%5D=${_project}"
		printf '%s\n' "project,run_id,pipeline,url,copy_results_prm,date"  > "${JOB_CONTROLE_FILE_BASE}.trackAndTrace.csv"
		printf '%s\n' "${_project},${_project},${_sampleType},${_url},finished,"     >> "${JOB_CONTROLE_FILE_BASE}.trackAndTrace.csv"
		trackAndTracePostFromFile 'status_projects' 'update'            "${JOB_CONTROLE_FILE_BASE}.trackAndTrace.csv"
		log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "${PRM_ROOT_DIR}/projects/${_project}/${_run}/results/multiqc_data/${_project}.run_date_info.csv"
#		if [[ -e "${PRM_ROOT_DIR}/projects/${_project}/${_run}/results/multiqc_data/${_project}.run_date_info.csv" ]]; then
		#
		# Load chronqc.
		#
#			log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "Found ${PRM_ROOT_DIR}/projects/${_project}/${_run}/results/multiqc_data/${_project}.run_date_info.csv. Updating ChronQC database with ${_project}."
#			module load chronqc/${CHRONQC_VERSION} || log4Bash 'FATAL' ${LINENO} "${FUNCNAME:-main}" ${?} 'Failed to load chronqc module.'
#			log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "$(module list)"
			# Get panel information from $_project} based on column 'capturingKit'.
#			_panel=$(awk -F "${SAMPLESHEET_SEP}" 'NR==1 { for (i=1; i<=NF; i++) { f[$i] = i}}{if(NR > 1) print $(f["capturingKit"]) }' ${PRM_ROOT_DIR}/projects/${_project}/${_run}/results/${project}.${SAMPLESHEET_EXT} | sort -u | cut -d'/' -f2)

#			chronqc database --update --db ${PRM_ROOT_DIR}/chronqc/${CHRONQC_DATABASE_NAME} \
#			--run-date-info ${PRM_ROOT_DIR}/projects/${_project}/${_run}/results/multiqc_data/${_project}.run_date_info.csv \
#			--multiqc-sources ${PRM_ROOT_DIR}/projects/${_project}/${_run}/results/multiqc_data/multiqc_sources.txt \
#			${PRM_ROOT_DIR}/projects/${_project}/${_run}/results/multiqc_data/multiqc_general_stats.txt \
#			${_panel}

#			echo "${_project}: panel: ${_panel} stored to Chronqc database." >> "${JOB_CONTROLE_FILE_BASE}.finished"
#		fi
		#
		# Set all the jobs to finished 
		#
#		grep '^processJob' ${TMP_ROOT_DIR}/projects/${_project}/${_run}/jobs/submit.sh \
#			| tr '"' ' ' \
#			| awk -v pro=${_project} '{OFS=","} {print pro"_"$2}' \
#			>> "${JOB_CONTROLE_FILE_BASE}.trackAndTraceJobIDs.csv"
		
#		while read line
#		do
#			trackAndTracePut 'status_jobs' "${line}" "status" "finished"
#		done<"${JOB_CONTROLE_FILE_BASE}.trackAndTraceJobIDs.csv"
		
	else
		log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' 'Ended up in unexpected state:'
		log4Bash 'FATAL' "${LINENO}" "${FUNCNAME:-main}" '1' "Expected either ${JOB_CONTROLE_FILE_BASE}.finished or ${JOB_CONTROLE_FILE_BASE}.failed, but both are absent."
	fi
	#log4Bash 'DEBUG' ${LINENO} "${FUNCNAME:-main}" 0 \
        #        "moving ${PRM_ROOT_DIR}/Samplesheets/${_project}.${SAMPLESHEET_EXT} ${PRM_ROOT_DIR}/Samplesheets/archive/"
	#mv "${PRM_ROOT_DIR}/Samplesheets/${_project}.${SAMPLESHEET_EXT}" "${PRM_ROOT_DIR}/Samplesheets/archive/"
	echo "finished: $(date +%FT%T%z)" >> "${JOB_CONTROLE_FILE_BASE}.totalRunTime"
}

function getSampleType(){
	local  _sampleSheet="${1}"
	declare -a sampleSheetColumnNames=()
	declare -A sampleSheetColumnOffsets=()
	declare    sampleType='DNA' # Default when not specified in sample sheet.
	declare    sampleTypeFieldIndex
	IFS="${SAMPLESHEET_SEP}" sampleSheetColumnNames=($(head -1 "${_sampleSheet}"))
	for (( offset = 0 ; offset < ${#sampleSheetColumnNames[@]:-0} ; offset++ ))
	do
		#
		# Backwards compatibility for "Sample Type" including - the horror - a space and optionally quotes :o.
		#
		regex='Sample Type'
		if [[ "${sampleSheetColumnNames[${offset}]}" =~ ${regex} ]]
		then
			columnName='sampleType'
		else
			columnName="${sampleSheetColumnNames[${offset}]}"
		fi
		sampleSheetColumnOffsets["${columnName}"]="${offset}"
	#	log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "${columnName} and sampleSheetColumnOffsets["${columnName}"] offset ${offset} "
	done
	
	if [[ ! -z "${sampleSheetColumnOffsets['sampleType']+isset}" ]]; then
		#
		# Get sampleType from sample sheet and check if all samples are of the same type.
		#
		sampleTypeFieldIndex=$((${sampleSheetColumnOffsets['sampleType']} + 1))
		sampleTypesCount=$(tail -n +2 "${_sampleSheet}" | cut -d "${SAMPLESHEET_SEP}" -f "${sampleTypeFieldIndex}" | sort | uniq | wc -l)
		if [[ "${sampleTypesCount}" -eq '1' ]]
		then
			sampleType=$(tail -n 1 "${_sampleSheet}" | cut -d "${SAMPLESHEET_SEP}" -f "${sampleTypeFieldIndex}")
	#		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Found sampleType: ${sampleType}."
			echo ${sampleType}
		else
			log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' "${_sampleSheet} contains multiple different sampleType values."
			log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' "Skipping ${project} due to error in sample sheet."
			continue
		fi
	else
	#	log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "sampleType column missing in sample sheet; will use default value: ${sampleType}."
		echo ${sampleType}
	fi
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
declare email='false'
declare dryrun=''
while getopts "g:l:hn" opt
do
	case $opt in
		h)
			showHelp
			;;
		g)
			group="${OPTARG}"
			;;
		n)
			dryrun='-n'
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
if [[ -z "${group:-}" ]]
then
	log4Bash 'FATAL' "${LINENO}" "${FUNCNAME:-main}" '1' 'Must specify a group with -g.'
fi
if [[ -n "${dryrun:-}" ]]
then
	log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' 'Enabled dryrun option for rsync.'
fi

#
# Source config files.
#
log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Sourcing config files..."
declare -a configFiles=(
	"${CFG_DIR}/${group}.cfg"
	"${CFG_DIR}/${HOSTNAME_SHORT}.cfg"
	"${CFG_DIR}/sharedConfig.cfg"
	"${HOME}/molgenis.cfg"
)
for configFile in "${configFiles[@]}"
do
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
# Write access to prm storage requires data manager account.
#
if [[ "${ROLE_USER}" != "${DATA_MANAGER}" ]]
then
	log4Bash 'FATAL' "${LINENO}" "${FUNCNAME:-main}" '1' "This script must be executed by user ${DATA_MANAGER}, but you are ${ROLE_USER} (${REAL_USER})."
fi

#
# Make sure only one copy of this script runs simultaneously 
# per data collection we want to copy to prm -> one copy per group.
# Therefore locking must be done after 
# * sourcing the file containing the lock function,
# * sourcing config files,
# * and parsing commandline arguments,
# but before doing the actual data trnasfers.
#
lockFile="${PRM_ROOT_DIR}/logs/${SCRIPT_NAME}.lock"
thereShallBeOnlyOne "${lockFile}"
log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Successfully got exclusive access to lock file ${lockFile}..."
log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Log files will be written to ${PRM_ROOT_DIR}/logs..."

#
# Use multiplexing to reduce the amount of SSH connections created
# when rsyncing using the group's data manager account.
# 
#  1. Become the "${DATA_MANAGER} user who will rsync the data to prm and 
#  2. Add to ~/.ssh/config:
#		ControlMaster auto
#		ControlPath ~/.ssh/tmp/%h_%p_%r
#		ControlPersist 5m
#  3. Create ~/.ssh/tmp dir:
#		mkdir -p -m 700 ~/.ssh/tmp
#  4. Recursively restrict access to the ~/.ssh dir to allow only the owner/user:
#		chmod -R go-rwx ~/.ssh
#

#
# Get a list of all projects for this group, loop over their run analysis ("run") sub dirs and check if there are any we need to rsync.
#
declare -a projects=($(ssh ${DATA_MANAGER}@${HOSTNAME_TMP} "find ${TMP_ROOT_DIAGNOSTICS_DIR}/projects/ -maxdepth 1 -mindepth 1 -type d"))
if [[ "${#projects[@]:-0}" -eq '0' ]]
then
	log4Bash 'WARN' "${LINENO}" "${FUNCNAME:-main}" '0' "No projects found @ ${TMP_ROOT_DIAGNOSTICS_DIR}/projects."
else
	for pro in "${projects[@]}"
	do
		project=$(basename ${pro})
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Processing project ${project}..."
		declare -a runs=($(ssh ${DATA_MANAGER}@${HOSTNAME_TMP} "find "${TMP_ROOT_DIAGNOSTICS_DIR}/projects/${project}/" -maxdepth 1 -mindepth 1 -type d"))
		if [[ "${#runs[@]:-0}" -eq '0' ]]
		then
			log4Bash 'WARN' "${LINENO}" "${FUNCNAME:-main}" '0' "No runs found for project ${project}."
		else
			for ru in "${runs[@]}"
			do
				run=$(basename ${ru})
				controlFileBase="${PRM_ROOT_DIR}/logs/${project}/${run}"
				export JOB_CONTROLE_FILE_BASE="${controlFileBase}.${SCRIPT_NAME}"
				calculateProjectMd5sFinishedFile="ssh ${DATA_MANAGER}@${HOSTNAME_TMP}:${TMP_ROOT_DIAGNOSTICS_DIR}/logs/${project}/${project}.calculateProjectMd5s.finished"
				log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Creating logs folder: ${PRM_ROOT_DIR}/logs/${project}/"
				mkdir -p "${PRM_ROOT_DIR}/logs/${project}/"
				if ssh ${DATA_MANAGER}@${HOSTNAME_TMP} test -e "${TMP_ROOT_DIAGNOSTICS_DIR}/logs/${project}/${run}.calculateProjectMd5s.finished"
				then
					if [[ -e "${JOB_CONTROLE_FILE_BASE}.finished" ]] && [[ "${calculateProjectMd5sFinishedFile}" -ot "${JOB_CONTROLE_FILE_BASE}.finished" ]]
					then
						log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "Skipping already processed batch ${project}/${run}."
					else
						rsync -av  ${DATA_MANAGER}@${HOSTNAME_TMP}:${TMP_ROOT_DIAGNOSTICS_DIR}/projects/${project}/${run}/jobs/${project}.${SAMPLESHEET_EXT} ${PRM_ROOT_DIR}/Samplesheets/
						sampleType=$(getSampleType ${PRM_ROOT_DIR}/Samplesheets/${project}.${SAMPLESHEET_EXT})
						log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "sampleType =${sampleType}"
						log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Processing run ${project}/${run}..."
						rsyncProjectRun "${project}" "${run}" "${sampleType}"

					fi
				else
					log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "${project}/${run} calculateProjectMd5s not yet finished"
				fi
			done
		fi
	done
fi

log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' 'Finished successfully!'
echo "" > "${lockFile}"
trap - EXIT
exit 0
