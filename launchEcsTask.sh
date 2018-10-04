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
  CONTAINERS=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      # Required inputs
      --cluster) CLUSTER_NAME=$2; shift 2;;
      --task) TASK_NAME="$2"; shift 2;;
      --region) AWS_REGION="$2"; shift 2;;
      # Optional inputs yet to be implemented
      --container) CONTAINERS+=("$2"); shift 2;;
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
  parseAllDockerRunCommands
}

# Break Docker run statement into individual variables
function parseAllDockerRunCommands() {
  for CONTAINER in "${CONTAINERS[@]}"; do
    parseDockerRunCommand $CONTAINER
  done
}

function parseDockerRunCommand() {
  ARGS=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --name) NAME+=("$2"); shift 2;;
      --cpu) CPU+=($(($2 * $CPU_COEF))); shift 2;;
      --memory) MEM=$(echo "scale=0; (($2 * $MEMORY_COEF) / 1)" | bc); MEMORY+=("$MEM"); shift 2;;
      docker) shift 1;;
      run) shift 1;;
      -*) echo "unknown option: $1" >&2; exit 1;;
      *) ARGS+=("$1"); shift 1;;
    esac
  done
  for ARG in "${ARGS[@]}"; do
    if [ -n "$ARG" ]; then
      IMAGE+=("$ARG")
    fi
  done
}

function createAndRegisterNewInstanceIfNeeded() {
  if [ "$INSTANCE_SUITS_TASK" == false ]; then
    CLUSTER_STATUS=$(aws ecs describe-clusters --clusters "$CLUSTER_NAME" | jq '.clusters[0]')
    CLUSTER_INSTANCE_COUNT=$(echo "$CLUSTER_STATUS" | jq '.registeredContainerInstancesCount')
    NEXT_CLUSTER_INDEX=$(($CLUSTER_INSTANCE_COUNT + 1))
    # TODO: Ensure name is unique
    NEW_INSTANCE_NAME=ecs-"$CLUSTER_NAME"-"$NEXT_CLUSTER_INDEX"
    # TODO: Do SSH polling in createEc2Instance.sh to remove --wait-for-init
    ./createEc2Instance.sh --name "$NEW_INSTANCE_NAME" --image "$AWS_EC2_AMI" --type "$MINIMUM_SUITABLE_INSTANCE_TYPE" --port 22 --wait-for-init
    ./registerEc2InstanceInEcsCluster.sh --cluster "$CLUSTER_NAME" --instance-name "$NEW_INSTANCE_NAME" --instance-type "$MINIMUM_SUITABLE_INSTANCE_TYPE"
  fi
}

function declareConstants() {
  CPU_COEF=1024
  MEMORY_COEF=995
  AWS_EC2_AMI="ami-40142d25"
}

function calculateSumResourceRequirementsForTask() {
  CPU_REQUIREMENT=0
  for CPU_VALUE in "${CPU[@]}"; do
    CPU_REQUIREMENT=$(($CPU_REQUIREMENT + $CPU_VALUE))
  done
  MEMORY_REQUIREMENT=0
  for MEMORY_VALUE in "${MEMORY[@]}"; do
    MEMORY_REQUIREMENT=$(($MEMORY_REQUIREMENT + $MEMORY_VALUE))
  done
}

function findExistingSuitableInstanceInCluster() {
  INSTANCE_SUITS_TASK=false
  CONTAINER_INSTANCE_ARNS=$(aws ecs list-container-instances --cluster "$CLUSTER_NAME" --region "$AWS_REGION" | jq '.containerInstanceArns')
  INSTANCE_COUNT=$(echo $CONTAINER_INSTANCE_ARNS | jq '. | length')
  for (( INSTANCE_INDEX=0; INSTANCE_INDEX<INSTANCE_COUNT; INSTANCE_INDEX++ )); do
    THIS_INSTANCE_ARN=$(sed -e 's/^"//' -e 's/"$//' <<< $(echo "$CONTAINER_INSTANCE_ARNS" | jq '.['"$INSTANCE_INDEX"']'))
    findRemainingResourcesOnInstance
    checkIfInstanceSuitsTask
  done
}

function findRemainingResourcesOnInstance() {
  RESOURCES=$(aws ecs describe-container-instances --cluster "$CLUSTER_NAME" --container-instances "$THIS_INSTANCE_ARN" --region "$AWS_REGION" | jq '.containerInstances[0].remainingResources')
  RESOURCE_COUNT=$(echo "$RESOURCES" | jq '. | length')
  for (( RESOURCE_INDEX=0; RESOURCE_INDEX<RESOURCE_COUNT; RESOURCE_INDEX++ )); do
    THIS_RESOURCE=$(echo "$RESOURCES" | jq '.['"$RESOURCE_INDEX"']')
    THIS_RESOURCE_NAME=$(echo "$THIS_RESOURCE" | jq '.name')
    if [ "$THIS_RESOURCE_NAME" == \"CPU\" ]; then
      THIS_INSTANCE_CPU_REMAINING=$(echo "$THIS_RESOURCE" | jq '.integerValue')
    elif [ "$THIS_RESOURCE_NAME" == \"MEMORY\" ]; then
      THIS_INSTANCE_MEMORY_REMAINING=$(echo "$THIS_RESOURCE" | jq '.integerValue')
    fi
  done
}

function checkIfInstanceSuitsTask() {
  if [ $THIS_INSTANCE_CPU_REMAINING -ge $CPU_REQUIREMENT ] && [ $THIS_INSTANCE_MEMORY_REMAINING -ge $MEMORY_REQUIREMENT ]; then
    INSTANCE_SUITS_TASK="$THIS_INSTANCE_ARN"
    break
  fi
}

function getMinimumSuitableInstanceType() {
  . ./awsT3InstanceSpecs.sh
  MINIMUM_SUITABLE_INSTANCE_TYPE=false
  if [ "$INSTANCE_SUITS_TASK" == false ]; then
    for AWS_T3_INSTANCE_SPEC in ${!AWS_T3_INSTANCE_SPEC@}; do
      if [ ${AWS_T3_INSTANCE_SPEC[cpu]} -ge $CPU_REQUIREMENT ] && [ ${AWS_T3_INSTANCE_SPEC[memory]} -ge $MEMORY_REQUIREMENT ]; then
        MINIMUM_SUITABLE_INSTANCE_TYPE=${AWS_T3_INSTANCE_SPEC[name]}
        break
      fi
    done
  fi
}

function registerEcsTaskDefinition() {
  ./registerEcsTaskDefinition.sh "$TASK_NAME" "${CONTAINERS[*]}" "$AWS_REGION"
}

declareConstants
handleInput "$@"
defineColorPalette
createClusterIfItDoesNotExist
calculateSumResourceRequirementsForTask
findExistingSuitableInstanceInCluster
getMinimumSuitableInstanceType
createAndRegisterNewInstanceIfNeeded
registerEcsTaskDefinition
#launchTask
