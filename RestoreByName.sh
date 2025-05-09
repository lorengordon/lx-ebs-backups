#!/bin/bash
# shellcheck disable=SC1090,SC2155,SC2001,SC2207
#
# This script is designed to restore an EBS or EBS-group using the 
# value in the snapshots' "Name" tag:
# * If the snapshots' "Name" tags are not set, this script will fail
# * If the name-value passed to the script is not an exact-match for 
#   any snapshots' "Name" tag, this script will fail
#
# Note: this script assumes that you are attaching an EBS to an
#       existing instance, either with the intention to recover 
#       individual files or to act as a full restore of a damaged 
#       or destroyed EBS. The full restore may be made available
#       on a new instance or on the instance that originally
#       generated the EBS snapshot.
#
# Dependencies:
# - Generic: See the top-level README_dependencies.md for script dependencies
# - Specific:
#   * All snapshots - or groups of snapshots - to be restored via this
#     script must have a unique "Name" tag (at least within the scope
#     of an Amazon region). Non-unique "Name" tags will result in
#     collisions during restores
#
# License:
# - This script released under the Apache 2.0 OSS License
#
######################################################################

# Starter Variables
PATH=/sbin:/usr/sbin:/bin:/usr/bin:/opt/AWScli/bin
export PROGNAME="$( basename "${BASH_SOURCE[0]}" )"
export PROGDIR="$( dirname "${BASH_SOURCE[0]}" )"
EBSTYPE="standard"

# Put the bulk of our variables into an external file so they
# can be easily re-used across scripts
# shellcheck source=/dev/null
source "${PROGDIR}/commonVars.env"

# Output log-data to multiple locations
function MultiLog() {
   echo "${1}"
   logger -p local0.info -t "[NamedRestore]" "${1}"
}

# Verify AZ-validity
function VerifyAZ() {
   local AZLIST

   AZLIST=$(aws ec2 describe-availability-zones \
      --query "AvailabilityZones[].ZoneName[]" --output text | tr "\t" "\n")
   echo "${AZLIST}" | grep -qw "${1}" && echo "${1}"
}

# Get list of snspshots matching "Name"
function GetSnapList() {
   local SNAPLIST

   SNAPLIST=$( aws ec2 describe-snapshots --output=text --filters  \
      "Name=tag:Snapshot Group,Values=${SNAPGRP}" --query  \
      "Snapshots[].SnapshotId" )
   
   # Make sure our query resulted in a valid match
   if [[ -z ${SNAPLIST} ]]
   then
      MultiLog "No snapshots found matching pattern \"${SNAPGRP}\". Aborting..." >&2
      exit 1
   else
      echo "${SNAPLIST}"
   fi
}

# Create EBSes from snaps
function SnapToEBS() {
   local COUNT
   local CREATEDEBS

   COUNT=0
   for SNAPID in ${RESTORELST}
   do
      MultiLog "Creating EBS from snapshot \"${SNAPID}\"... "
      if [[ ${EBSTYPE} = "io1" ]]
      then
         NEWEBS=$(aws ec2 create-volume --output=text --snapshot-id "${SNAPID}" \
               --volume-type "${EBSTYPE}" --iops "${IOPS}" \
               --availability-zone "${INSTANCEAZ}" --query VolumeId)
      else
         NEWEBS=$(aws ec2 create-volume --output=text --snapshot-id "${SNAPID}" \
               --volume-type "${EBSTYPE}" --availability-zone "${INSTANCEAZ}" \
               --query VolumeId)
      fi

      # If EBS-creation fails, call the error
      if [ "${NEWEBS}" = "" ]
      then
         MultiLog "EBS-creation failed!"
      # Add a meaningful name to the EBS if creation succeeds
      else
	 aws ec2 create-tags --resource "${NEWEBS}" --tags \
	    "Key=Name,Value=Restore of ${SNAPGRP}"
         VOLLIST[COUNT]="${NEWEBS}"
         COUNT=$(( COUNT + 1 ))
      fi
   done
   CREATEDEBS="${VOLLIST[*]}"
   MultiLog "Created EBS(es): ${CREATEDEBS}"
}

# Compute list of available attachment slots
function ComputeFreeSlots() {
   local ALLSLOTS
   local COUNT

   # List of disk slots AWS recommends for Linux instances
   ALLSLOTS=(
      /dev/sdf
      /dev/sdg
      /dev/sdh
      /dev/sdi
      /dev/sdj
      /dev/sdk
      /dev/sdl
      /dev/sdm
      /dev/sdn
      /dev/sdo
      /dev/sdp
      /dev/sdq
      /dev/sdr
      /dev/sds
      /dev/sdt
      /dev/sdu
      /dev/sdv
      /dev/sdw
      /dev/sdx
      /dev/sdy
      /dev/sdz
   )

   # Determine used DeviceName slots to generate list of free slots
   USED=($(aws ec2 describe-instances --output=text --instance-ids \
      "${THISINSTID}" --query \
      "Reservations[].Instances[].BlockDeviceMappings[].DeviceName"))

   COUNT=0
   # Prune candidate slot-list
   while [[ ${COUNT} -lt ${#USED[@]} ]]
   do
      ALLSLOTS=( $( echo "${ALLSLOTS[@]}" | sed "s#${USED[${COUNT}]}##" ) )
      COUNT=$(( COUNT +1 ))
   done
}

# Map EBS(es) to free slot(s)
function EBStoSlot() {
   local COUNT
      
   if [[ ${#VOLLIST[@]} -le ${#ALLSLOTS[@]} ]]
   then
      COUNT=0

      while [ ${COUNT} -lt ${#VOLLIST[@]} ]
      do
         MultiLog "Mapping ${VOLLIST[${COUNT}]} to ${ALLSLOTS[${COUNT}]}"
         aws ec2 attach-volume --output=text \
             --volume-id "${VOLLIST[${COUNT}]}" \
             --instance-id "${THISINSTID}" \
             --device "${ALLSLOTS[${COUNT}]}" > /dev/null 2>&1 || \
	   MultiLog "Failed to map ${VOLLIST[${COUNT}]} to ${ALLSLOTS[${COUNT}]}" >&2
         COUNT=$(( COUNT + 1 ))
      done
   fi
}

function RestoreImport() {
   (echo "NOT IMPLEMENTED. Unresolved Red Hat BZ #1202785 prevents use of"
   printf "\t'vgimportclone' utility\n\n"
   echo "Restoration import will look something like:"
   printf "\tvgimportclone -n OrclVG_Restore -i /dev/xvdf1 /dev/xvdg1 \\ \n"
   printf "\t/dev/xvdm1 /dev/xvdn1 /dev/xvdo1\n") >&2
}

#############################
## End of function delares ##
#############################

#######################################
##                                   ##
## Main program functioning and flow ##
##                                   ##
#######################################

# Make sure a searchable Name was passed
if [[ "$#" -lt 1 ]] || [[ "${SNAPGRP}" = "UNDEF" ]]
then
   MultiLog "Failed to specify required parameters" >&2
   exit 1
else
   INSTANCEAZ=$(curl -s \
      http://169.254.169.254/latest/meta-data/placement/availability-zone/)
fi

####################################
# Snarf args into parseable buffer
####################################
OPTIONBUFR=$(
      getopt -o g:t:i:a: --longoptions snapgrp:,ebstype:,iops:,az: \
        -n "${PROGNAME}" -- "$@"
   )
# Note the quotes around '$OPTIONBUFR': they are essential!
eval set -- "${OPTIONBUFR}"

###################################
# Parse contents of ${OPTIONBUFR}
###################################
while true
do
   case "$1" in
      -g|--snapgrp)
         # Mandatory argument. Operating in quoted mode: an
	 # empty parameter will be generated if its optional
	 # argument is not found
	 case "$2" in
	    "")
	       MultiLog "Error: option required but not specified" >&2
	       shift 2;
	       exit 1
	       ;;
	    *)
               SNAPGRP=${2}
	       shift 2;
	       ;;
	 esac
	 ;;
      -t|--ebstype)
         # Mandatory argument. Operating in quoted mode: an
	 # empty parameter will be generated if its optional
	 # argument is not found
	 case "$2" in
	    io1)
               EBSTYPE=${2}
	       MultiLog "Info: EBS-type set to \"${EBSTYPE}\"."
	       shift 2;
	       ;;
	    gp2)
               EBSTYPE=${2}
	       MultiLog "Info: EBS-type set to \"${EBSTYPE}\"."
	       shift 2;
	       ;;
	    standard)
               EBSTYPE=${2}
	       MultiLog "Info: EBS-type set to \"${EBSTYPE}\"."
	       shift 2;
	       ;;
	    "")
	       MultiLog "Error: option required but not specified" >&2
	       shift 2;
	       exit 1
	       ;;
	    *) 
               EBSTYPE=${2}
	       MultiLog "Error: Selected EBS-type [${EBSTYPE}] not valid. Aborting!" >&2
               shift 2;
	       exit 1
	       ;;
	 esac
	 ;;
      -i|--iops)
         # Mandatory argument. Operating in quoted mode: an
         # empty parameter will be generated if its optional
         # argument is not found
         case "$2" in
            "")
               MultiLog "Error: option required but not specified" >&2
               shift 2;
               exit 1
               ;;
            *)
               IOPS=${2}
               shift 2;
               ;;
         esac
         ;;
      -a|--az)
         # Mandatory argument. Operating in quoted mode: an
         # empty parameter will be generated if its optional
         # argument is not found
         case "$2" in
            "")
               MultiLog "Error: option required but not specified" >&2
               shift 2;
               exit 1
               ;;
            *)
               TARGAZ="$( VerifyAZ "${2}" )"
               shift 2;
               if [ "${TARGAZ}" = "" ]
               then
                  MultiLog "Error: requested AZ not found. Aborting" >&2
                  exit 1
               else
                  INSTANCEAZ="${TARGAZ}"
               fi
               ;;
         esac
         ;;
      --)
         shift
         break
         ;;
      *)
         MultiLog "Internal error!" >&2
         exit 1
         ;;
   esac
done

# Ensure that an IOPS value is set for 'io1' EBS-type
if [ "${EBSTYPE}" = "io1" ] && [ "${IOPS}" = "" ]
then
   MultiLog "Error: EBS-type \"${EBSTYPE}\" selected but no IOPS value specified. Aborting!" >&2
   exit 1
elif [ "${EBSTYPE}" = "io1" ] && [ "${IOPS}" != "" ]
then
   MultiLog "Info: IOPS value set to \"${IOPS}\"."
fi

# Let operator know that specifying IOPS not compatible with EBS-type
if [ "${EBSTYPE}" = "gp2" ] || [ "${EBSTYPE}" = "standard" ]
then
   if [ "${IOPS}" != "" ]
   then
      MultiLog "Info: specified IOPS but is discarded when EBS-type is \"${EBSTYPE}\"."
   fi
fi

# Call snapshot-finder function
RESTORELST="$(GetSnapList)"

# Bail if we have an empty list
if [ "${RESTORELST}" = "" ]
then
   MultiLog "No matching-snapshots found for restore" >&2
   exit 1
else
   SnapToEBS
   ComputeFreeSlots
#    EBStoSlot
#    RestoreImport
fi
