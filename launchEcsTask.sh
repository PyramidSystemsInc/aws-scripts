# /bin/bash

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
    exitIfScriptFailed
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
  OVERWRITE_ECR=false
  REVISION="hasnotbeenset"
  CONTAINERS=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      # Required inputs
      --cluster) CLUSTER_NAME=$2; shift 2;;
      --task) TASK_NAME="$2"; shift 2;;
      # One, and only one, of the following inputs is required
      --container) CONTAINERS+=("$2"); shift 2;;
      --revision) REVISION=("$2"); shift 2;;
      # Optional inputs
      --overwrite-ecr) OVERWRITE_ECR=true; shift 1;;
      --region) AWS_REGION="$2"; shift 2;;
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
  if [ "${#CONTAINERS}" -eq 0 ]; then
    REGISTERING_NEW_TASK_DEFINITION=false
    if [ "$REVISION" == "hasnotbeenset" ]; then
      REVISION="latest"
    fi
    gatherTaskDefinitionResourcesRequired
  elif [ "${#CONTAINERS}" -ge 1 ] && [ "$REVISION" == "hasnotbeenset" ]; then
    REGISTERING_NEW_TASK_DEFINITION=true
    parseAllDockerRunCommands
  else
    echo "ERROR: Only one of the following flags should be used: One or more '--container <DOCKER RUN COMMAND>' flags to register a new task definition -OR- a single '--revision <NUMBER>' flag in order to run an existing task definition. Omitting both tags assumes you want to use an existing task defintion and the latest revision of that task"
  fi
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
      -p) PORT_MAPPINGS+=("$2"); shift 2;;
      --publish) PORT_MAPPINGS+=("$2"); shift 2;;
      -c) CPU+=($(($2 * $CPU_COEF))); shift 2;;
      --cpu) CPU+=($(($2 * $CPU_COEF))); shift 2;;
      -m) MEM=$(echo "scale=0; (($2 * $MEMORY_COEF) / 1)" | bc); MEMORY+=("$MEM"); shift 2;;
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
    getNewUniqueInstanceName
    createNewInstanceOpenPortSpec
    COMMAND="./createEc2Instance.sh --name "$NEW_INSTANCE_NAME" --image "$AWS_EC2_AMI" --type "$MINIMUM_SUITABLE_INSTANCE_TYPE" --iam-role jenkins_instance --port 22 "$NEW_INSTANCE_OPEN_PORTS_SPEC" --startup-script installEcsAgentOnEc2Instance.sh"
    $($COMMAND >> /dev/null)
    exitIfScriptFailed
    findNewInstanceInformation
    waitUntilInstanceRegisteredInCluster
  fi
}

# Get a unique name in the form of `ecs-<CLUSTER_NAME>-<UNIQUE_NUMBER>` which
# does not conflict with any existing EC2 key pair or EC2 security group names
function getNewUniqueInstanceName() {
  CLUSTER_STATUS=$(aws ecs describe-clusters --clusters "$CLUSTER_NAME" | jq '.clusters[0]')
  CLUSTER_INSTANCE_COUNT=$(echo "$CLUSTER_STATUS" | jq '.registeredContainerInstancesCount')
  CANDIDATE_INDEX=$(($CLUSTER_INSTANCE_COUNT + 1))
  KEY_PAIRS=$(aws ec2 describe-key-pairs --region "$AWS_REGION" | jq '.KeyPairs')
  KEY_PAIR_COUNT=$(echo "$KEY_PAIRS" | jq '. | length')
  SECURITY_GROUPS=$(aws ec2 describe-security-groups --region "$AWS_REGION" | jq '.SecurityGroups')
  SECURITY_GROUP_COUNT=$(echo "$SECURITY_GROUPS" | jq '. | length')
  UNIQUE_NAME_FOUND=false
  while [ "$UNIQUE_NAME_FOUND" == "false" ] ; do
    UNIQUE_NAME_FOUND=true
    INSTANCE_NAME_CANDIDATE=ecs-"$CLUSTER_NAME"-"$CANDIDATE_INDEX"
    for (( KEY_PAIR_INDEX=0; KEY_PAIR_INDEX<KEY_PAIR_COUNT; KEY_PAIR_INDEX++ )); do
      THIS_KEY_PAIR=$(sed -e 's/^"//' -e 's/"$//' <<< $(echo "$KEY_PAIRS" | jq '.['"$KEY_PAIR_INDEX"'].KeyName'))
      if [ "$INSTANCE_NAME_CANDIDATE" == "$THIS_KEY_PAIR" ]; then
        UNIQUE_NAME_FOUND=false
        break
      fi
    done
    for (( SECURITY_GROUP_INDEX=0; SECURITY_GROUP_INDEX<SECURITY_GROUP_COUNT; SECURITY_GROUP_INDEX++ )); do
      THIS_SECURITY_GROUP=$(sed -e 's/^"//' -e 's/"$//' <<< $(echo "$SECURITY_GROUPS" | jq '.['"$SECURITY_GROUP_INDEX"'].GroupName'))
      if [ "$INSTANCE_NAME_CANDIDATE" == "$THIS_SECURITY_GROUP" ]; then
        UNIQUE_NAME_FOUND=false
        break
      fi
    done
    CANDIDATE_INDEX=$(($CANDIDATE_INDEX + 1))
  done
  NEW_INSTANCE_NAME="$INSTANCE_NAME_CANDIDATE"
}

function waitUntilInstanceRegisteredInCluster() {
  while : ; do
    CLUSTER_INSTANCES=$(aws ecs list-container-instances --cluster sample --region "$AWS_REGION" | jq '.containerInstanceArns')
    CLUSTER_INSTANCE_COUNT=$(echo $CLUSTER_INSTANCES | jq '. | length')
    for (( CLUSTER_INSTANCE_INDEX=0; CLUSTER_INSTANCE_INDEX<CLUSTER_INSTANCE_COUNT; CLUSTER_INSTANCE_INDEX++ )); do
      CLUSTER_INSTANCE_ID=$(sed -e 's/^.*\///' -e 's/"$//' <<< $(echo "$CLUSTER_INSTANCES" | jq '.['"$CLUSTER_INSTANCE_INDEX"']'))
      CLUSTER_EC2_INSTANCE_ID=$(sed -e 's/^"//' -e 's/"$//' <<< $(aws ecs describe-container-instances --cluster sample --container-instances "$CLUSTER_INSTANCE_ID" | jq '.containerInstances[0].ec2InstanceId'))
      if [ "$CLUSTER_EC2_INSTANCE_ID" == "$NEW_INSTANCE_ID" ]; then
        break 2
      fi
    done
    sleep 2
  done
}

function findNewInstanceInformation() {
  EC2_INSTANCES=$(aws ec2 describe-instances --query 'Reservations[*].Instances[*].[State.Name,Tags[?Key==`Name`].Value,PublicIpAddress,InstanceId]')
  INSTANCE_COUNT=$(echo $EC2_INSTANCES | jq '. | length')
  for (( INSTANCE_INDEX=0; INSTANCE_INDEX<INSTANCE_COUNT; INSTANCE_INDEX++ )); do
    THIS_INSTANCE=$(echo $EC2_INSTANCES | jq '.['"$INSTANCE_INDEX"'][0]')
    THIS_INSTANCE_STATE=$(echo $THIS_INSTANCE | jq '.[0]')
    THIS_INSTANCE_NAME=$(sed -e 's/^"//' -e 's/"$//' <<< $(echo $THIS_INSTANCE | jq '.[1][0]'))
    if [ "$THIS_INSTANCE_STATE" == \"running\" ] && [ "$THIS_INSTANCE_NAME" == "$NEW_INSTANCE_NAME" ]; then
      THIS_INSTANCE_IP=$(sed -e 's/^"//' -e 's/"$//' <<< $(echo $THIS_INSTANCE | jq '.[2]'))
      THIS_INSTANCE_ID=$(sed -e 's/^"//' -e 's/"$//' <<< $(echo $THIS_INSTANCE | jq '.[3]'))
      break
    fi
  done
  if [ -z "$THIS_INSTANCE_IP" ]; then
    echo -e "${COLOR_RED_BOLD}ERROR: The instance could not be found"
    echo -e "${COLOR_NONE}"
    exit 2
  else
    NEW_INSTANCE_PUBLIC_IP=$THIS_INSTANCE_IP
    NEW_INSTANCE_ID=$THIS_INSTANCE_ID
  fi
}

function declareConstants() {
  CPU_COEF=1024
  MEMORY_COEF=926
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

function registerEcsTaskDefinitionIfNeeded() {
  if [ "$REGISTERING_NEW_TASK_DEFINITION" == true ]; then
    ./registerEcsTaskDefinition.sh "$TASK_NAME" "${CONTAINERS[*]}" "$OVERWRITE_ECR" "$AWS_REGION"
    exitIfScriptFailed
  fi
}

function launchTask() {
  if [ "$REVISION" == "hasnotbeenset" ] || [ "$REVISION" == "latest" ] ; then
    ECS_LAUNCH_STATUS=$(aws ecs run-task --cluster "$CLUSTER_NAME" --task-definition "$TASK_NAME" --region "$AWS_REGION")
  else
    ECS_LAUNCH_STATUS=$(aws ecs run-task --cluster "$CLUSTER_NAME" --task-definition "$TASK_NAME":"$REVISION" --region "$AWS_REGION")
  fi
}

function exitIfScriptFailed() {
  if [ $? -eq 2 ]; then
    exit 2
  fi
}

function gatherTaskDefinitionResourcesRequired() {
  NUMBER_REGEX='^[0-9]+$'
  if [ ! "$REVISION" == "latest" ] && [[ $REVISION =~ $NUMBER_REGEX ]]; then
    TASK_NAME_WITH_REVISION="$TASK_NAME"":""$REVISION"
  else
    TASK_NAME_WITH_REVISION="$TASK_NAME"
  fi
  TASK_DEFINITION_INFO=$(aws ecs describe-task-definition --task-definition "$TASK_NAME_WITH_REVISION" --region "$AWS_REGION" 2>/dev/null)
  # TODO: This is where port mappings should be retrieved from when using existing task definitions
  if [ $? -eq 0 ]; then
    TASK_DEFINITION_INFO=$(echo $TASK_DEFINITION_INFO | jq '.taskDefinition.containerDefinitions')
  else
    echo "ERROR! The revision number specifed does not exist"
    exit 2
  fi
  CONTAINER_DEFINITION_COUNT=$(echo "$TASK_DEFINITION_INFO" | jq '. | length')
  for (( CONTAINER_DEFINITION_INDEX=0; CONTAINER_DEFINITION_INDEX<CONTAINER_DEFINITION_COUNT; CONTAINER_DEFINITION_INDEX++ )); do
    THIS_CONTAINER_CPU_REQUIREMENT=$(echo "$TASK_DEFINITION_INFO" | jq '.['"$CONTAINIER_DEFINITION_INDEX"'].cpu')
    THIS_CONTAINER_MEMORY_REQUIREMENT=$(echo "$TASK_DEFINITION_INFO" | jq '.['"$CONTAINIER_DEFINITION_INDEX"'].memory')
    CPU+=($THIS_CONTAINER_CPU_REQUIREMENT)
    MEMORY+=($THIS_CONTAINER_MEMORY_REQUIREMENT)
  done
}

function createNewInstanceOpenPortSpec() {
  NEW_INSTANCE_OPEN_PORTS_SPEC=""
  for PORT_MAPPING in "${PORT_MAPPINGS[@]}"; do
    NEW_INSTANCE_OPEN_PORTS_SPEC+="--port $(sed -e 's/:.*$//' <<< $PORT_MAPPING) "
  done
}

declareConstants
handleInput "$@"
defineColorPalette
createClusterIfItDoesNotExist
calculateSumResourceRequirementsForTask
findExistingSuitableInstanceInCluster
getMinimumSuitableInstanceType
createAndRegisterNewInstanceIfNeeded
registerEcsTaskDefinitionIfNeeded
launchTask

# 104 and 246 are where ports need to be set up (in this script)

# host:container
# host is for Ec2 Instance
# both are for the task definition

# PUT ONE WAY
# If creating a new instance and creating a new task definition,... expose all the correct ports from the port mappings provided
# If creating a new instance and using an existing task definition,... lookup the host ports required and expose all that is needed
# If using an existing instance and creating a new task definition,... redo all the ports to fit the current task from port mappings
# If using an existing instance and using an existing task definition,... lookup the host ports required and redo all the ports

# PUT ANOTHER WAY
# If creating a new instance and creating a new task definition,... createNewInstanceOpenPortSpec()
# If creating a new instance and using an existing task definition,... getOpenPortsRequiredForTaskDefinitions() & createNewInstanceOpenPortSpec()
# If using an existing instance and creating a new task definition,... editInstanceOpenPorts()
# If using an existing instance and using an existing task definition,... getOpenPortsRequiredForTaskDefinitions() & editInstanceOpenPorts()
