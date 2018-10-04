#! /bin/bash

# Create ECS cluster
function createCluster() {
  aws ecs create-cluster --cluster-name "$CLUSTER_NAME" --region "$AWS_REGION" >> /dev/null
}

# Define all colors used for output
function defineColorPalette() {
  COLOR_RED='\033[0;91m'
  COLOR_WHITE_BOLD='\033[1;97m'
  COLOR_NONE='\033[0m'
}

# Handle user input
function handleInput() {
  AWS_REGION="us-east-2"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      # Required inputs
      --instance-name) INSTANCE_NAME="$2"; shift 2;;
      --instance-type) INSTANCE_TYPE="$2"; shift 2;;
      --cluster) CLUSTER_NAME=$2; shift 2;;
      # Optional inputs yet to be implemented
      --region) AWS_REGION="$2"; shift 2;;
      --skip-output) NO_OUTPUT=true; shift 1;;
      -h) HELP_WANTED=true; shift 1;;
      --help) HELP_WANTED=true; shift 1;;
      -*) echo "unknown option: $1" >&2; exit 1;;
      *) args+="$1 "; shift 1;;
    esac
  done
  if [ ${#args} -gt 0 ]; then
    echo -e "${COLOR_WHITE_BOLD}NOTICE: The following arguments were ignored: ${args}"
    echo -e "${COLOR_NONE}"
  fi
}

function findInstanceIpAddress() {
  EC2_INSTANCES=$(aws ec2 describe-instances --query 'Reservations[*].Instances[*].[State.Name,Tags[?Key==`Name`].Value,PublicIpAddress]')
  INSTANCE_COUNT=$(echo $EC2_INSTANCES | jq '. | length')
  for (( INSTANCE_INDEX=0; INSTANCE_INDEX<INSTANCE_COUNT; INSTANCE_INDEX++ )); do
    THIS_INSTANCE=$(echo $EC2_INSTANCES | jq '.['"$INSTANCE_INDEX"'][0]')
    THIS_INSTANCE_STATE=$(echo $THIS_INSTANCE | jq '.[0]')
    THIS_INSTANCE_NAME=$(sed -e 's/^"//' -e 's/"$//' <<< $(echo $THIS_INSTANCE | jq '.[1][0]'))
    if [ "$THIS_INSTANCE_STATE" == \"running\" ] && [ "$THIS_INSTANCE_NAME" == "$INSTANCE_NAME" ]; then
      THIS_INSTANCE_IP=$(sed -e 's/^"//' -e 's/"$//' <<< $(echo $THIS_INSTANCE | jq '.[2]'))
    fi
  done
  if [ -z "$THIS_INSTANCE_IP" ]; then
    echo -e "${COLOR_RED_BOLD}ERROR: The instance could not be found"
    echo -e "${COLOR_NONE}"
    exit 2
  else
    INSTANCE_PUBLIC_IP=$THIS_INSTANCE_IP
  fi
}

function findInstanceResources() {
  . ./awsT3InstanceSpecs.sh
  for AWS_T3_INSTANCE_SPEC in ${!AWS_T3_INSTANCE_SPEC@}; do
    if [ ${AWS_T3_INSTANCE_SPEC[name]} == $INSTANCE_TYPE ]; then
      INSTANCE_CPU=${AWS_T3_INSTANCE_SPEC[cpu]}
      INSTANCE_MEMORY=${AWS_T3_INSTANCE_SPEC[memory]}
      break
    fi
  done
}

function getIdentityInformation() {
  IDENTITY_DOCUMENT=$(ssh -i ~/Desktop/"$INSTANCE_NAME".pem ec2-user@"$INSTANCE_PUBLIC_IP" 'echo "" | sudo -Sv && bash -s' < ./getIdentityDocument.sh)
  IDENTITY_SIGNATURE=$(ssh -i ~/Desktop/"$INSTANCE_NAME".pem ec2-user@"$INSTANCE_PUBLIC_IP" 'echo "" | sudo -Sv && bash -s' < ./getIdentitySignature.sh)
}

function createResourceInformationJson() {
  # TODO: Must add in other resources such as ports
  #RESOURCES=$(cat total-resources.json)
	RESOURCES=$(cat <<-EOF
		[
		  {
		    "integerValue": $INSTANCE_CPU,
		    "longValue": 0,
		    "type": "INTEGER",
		    "name": "CPU",
		    "doubleValue": 0.0
		  },
		  {
		    "integerValue": $INSTANCE_MEMORY,
		    "longValue": 0,
		    "type": "INTEGER",
		    "name": "MEMORY",
		    "doubleValue": 0.0
		  }
		]
	EOF
	)
}

function registerInstanceWithCluster() {
  aws ecs register-container-instance --cluster "$CLUSTER_NAME" --instance-identity-document "$IDENTITY_DOCUMENT" --instance-identity-document-signature "$IDENTITY_SIGNATURE" --total-resources "$RESOURCES" >> /dev/null
}

handleInput "$@"
defineColorPalette
findInstanceIpAddress
findInstanceResources
getIdentityInformation
createResourceInformationJson
registerInstanceWithCluster
