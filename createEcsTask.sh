#! /bin/bash

# Query to see if the ECS cluster exists. If it does not, create the ECS cluster
function createClusterIfItDoesNotExist() {
  CLUSTER_EXISTS=false
  CLUSTER_ARNS=$(aws ecs list-clusters | jq '.clusterArns')
  CLUSTER_COUNT=$(echo "$CLUSTER_ARNS" | jq '. | length')
  for (( CLUSTER_INDEX=0; CLUSTER_INDEX<CLUSTER_COUNT; CLUSTER_INDEX++ )); do
    THIS_CLUSTER_NAME=$(sed -e 's|.*/||' -e 's/"$//' <<< $(echo "$CLUSTER_ARNS" | jq '.['"$CLUSTER_INDEX"']'))
    if [ "$THIS_CLUSTER_NAME" == "$CLUSTER_NAME" ]; then
      CLUSTER_EXISTS=true
    fi
  done
  if [ "$CLUSTER_EXISTS" == "false" ]; then
    ./createEcsCluster.sh --name "$CLUSTER_NAME" --region "$AWS_REGION"
    echo $INSTANCE_PUBLIC_IP
  fi
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
      --cluster) CLUSTER_NAME=$2; shift 2;;
      --region) AWS_REGION="$2"; shift 2;;
      --container) CONTAINER="$2"; shift 2;;
      # Optional inputs yet to be implemented
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

function createAndRegisterNewInstanceIfNeeded() {
  CLUSTER_STATUS=$(aws ecs describe-clusters --clusters "$CLUSTER_NAME" | jq '.clusters[0]')
  CLUSTER_INSTANCE_COUNT=$(echo "$CLUSTER_STATUS" | jq '.registeredContainerInstancesCount')
  CLUSTER_PENDING_TASKS_COUNT=$(echo "$CLUSTER_STATUS" | jq '.pendingTasksCount')
  CLUSTER_RUNNING_TASKS_COUNT=$(echo "$CLUSTER_STATUS" | jq '.runningTasksCount')
  if [ $(($CLUSTER_PENDING_TASKS_COUNT + $CLUSTER_RUNNING_TASKS_COUNT)) -ge $CLUSTER_INSTANCE_COUNT ]; then
    NEXT_CLUSTER_INDEX=$(($CLUSTER_INSTANCE_COUNT + 1))
    NEW_INSTANCE_NAME=ecs-"$CLUSTER_NAME"-"$NEXT_CLUSTER_INDEX"
    ./createEc2Instance.sh --name "$NEW_INSTANCE_NAME" --image ami-40142d25 --type t3.micro --port 22 --wait-for-init
    ./registerEc2InstanceInEcsCluster.sh --cluster "$CLUSTER_NAME" --instance-name "$NEW_INSTANCE_NAME"
  fi
}

handleInput "$@"
defineColorPalette
#createClusterIfItDoesNotExist
#createAndRegisterNewInstanceIfNeeded
./generateTaskDefinition.sh "$CONTAINER"
