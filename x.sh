#! /bin/bash

# For an existing task defintion, query for the sum cpu, memory, and ports all its containers require to run
function calculateSumResourceRequirementsForExistingTask() {
  CPU_REQUIREMENT=0
  MEMORY_REQUIREMENT=0
  EXISTING_TASK_HOST_PORTS=()
  NUMBER_REGEX='^[0-9]+$'
  if [ ! "$REVISION" == "latest" ] && [[ $REVISION =~ $NUMBER_REGEX ]]; then
    TASK_NAME_WITH_REVISION="$TASK_NAME"":""$REVISION"
  else
    TASK_NAME_WITH_REVISION="$TASK_NAME"
  fi
  TASK_DEFINITION_INFO=$(aws ecs describe-task-definition --task-definition "$TASK_NAME_WITH_REVISION" --region "$AWS_REGION" 2>/dev/null)
  if [ $? -eq 0 ]; then
    TASK_DEFINITION_INFO=$(echo $TASK_DEFINITION_INFO | jq '.taskDefinition.containerDefinitions')
  else
    echo "ERROR! The revision number specifed does not exist"
    exit 2
  fi
  TASK_DEFINITION_COUNT=$(echo "$TASK_DEFINITION_INFO" | jq '. | length')
  for (( TASK_DEFINITION_INDEX=0; TASK_DEFINITION_INDEX<TASK_DEFINITION_COUNT; TASK_DEFINITION_INDEX++ )); do
    THIS_TASK_DEFINITION=$(echo "$TASK_DEFINITION_INFO" | jq '.['"$TASK_DEFINITION_INDEX"']')
    THIS_CPU_REQUIREMENT=$(echo "$THIS_TASK_DEFINITION" | jq '.cpu')
    CPU_REQUIREMENT=$(($CPU_REQUIREMENT + $THIS_CPU_REQUIREMENT))
    THIS_MEMORY_REQUIREMENT=$(echo "$THIS_TASK_DEFINITION" | jq '.memory')
    MEMORY_REQUIREMENT=$(($MEMORY_REQUIREMENT + $THIS_MEMORY_REQUIREMENT))
    THIS_PORT_MAPPINGS=$(echo "$THIS_TASK_DEFINITION" | jq '.portMappings')
    PORT_MAPPING_COUNT=$(echo "$THIS_PORT_MAPPINGS" | jq '. | length')
    for (( PORT_MAPPING_INDEX=0; PORT_MAPPING_INDEX<PORT_MAPPING_COUNT; PORT_MAPPING_INDEX++ )); do
      EXISTING_TASK_HOST_PORTS+=($(echo "$THIS_PORT_MAPPINGS" | jq '.['"$PORT_MAPPING_INDEX"'].hostPort'))
    done
  done
}

# For a new task definition, sum the cpu and memory requirements of the `docker run` commands provided
function calculateSumResourceRequirementsForNewTask() {
  for (( CONTAINER_DEFINITION_INDEX=0; CONTAINER_DEFINITION_INDEX<CONTAINER_DEFINITION_COUNT; CONTAINER_DEFINITION_INDEX++ )); do
    CPU_REQUIREMENT=$(($CPU_REQUIREMENT + ${CONTAINER_DEFINITIONS[$CONTAINER_DEFINITION_INDEX,cpu]}))
    MEMORY_REQUIREMENT=$(($CPU_REQUIREMENT + ${CONTAINER_DEFINITIONS[$CONTAINER_DEFINITION_INDEX,memory]}))
  done
}

# Total up the cpu and memory requirements for the task the user requested
function calculateSumResourceRequirementsForTask() {
  if [ "$CREATING_NEW_TASK_DEFINITION" == true ]; then
    calculateSumResourceRequirementsForNewTask
  else
    calculateSumResourceRequirementsForExistingTask
  fi
}

# Check if a given EC2 instance's remaining cpu and memory resources will allow a task definition to run
function checkIfInstanceSuitsTask() {
  if [ $THIS_INSTANCE_CPU_REMAINING -ge $CPU_REQUIREMENT ] && [ $THIS_INSTANCE_MEMORY_REMAINING -ge $MEMORY_REQUIREMENT ]; then
    INSTANCE_SUITS_TASK="$THIS_INSTANCE_ARN"
    break
  fi
}

# Create an EC2 instance and register it with the cluster
function createAndRegisterNewInstance() {
  if [ "$INSTANCE_SUITS_TASK" == false ]; then
    getMinimumSuitableInstanceType
    getNewUniqueInstanceName
    createNewInstanceOpenPortSpec
    COMMAND="./createEc2Instance.sh --name "$NEW_INSTANCE_NAME" --image "$AWS_EC2_AMI" --type "$MINIMUM_SUITABLE_INSTANCE_TYPE" --iam-role jenkins_instance --port 22 "$NEW_INSTANCE_OPEN_PORTS_SPEC" --startup-script installEcsAgentOnEc2Instance.sh"
    $($COMMAND >> /dev/null)
    exitIfScriptFailed
    findNewInstanceInformation
    waitUntilInstanceRegisteredInCluster
  fi
}

# If the cluster specified does not exist, create it
function createClusterIfDoesNotExist() {
  CLUSTER_EXISTS=$(aws ecs describe-clusters --clusters "$CLUSTER_NAME" --region "$AWS_REGION" | jq '.clusters | length')
  if [ "$CLUSTER_EXISTS" -ge 0 ]; then
    ./createEcsCluster.sh --name "$CLUSTER_NAME" --region "$AWS_REGION"
  fi
}

# Create a string recognized by the `createEc2Instance.sh` script which will open the ports necessary to run the task
function createNewInstanceOpenPortSpec() {
  NEW_INSTANCE_OPEN_PORTS_SPEC=""
  for PORT_MAPPING in "${PORT_MAPPINGS[@]}"; do
    NEW_INSTANCE_OPEN_PORTS_SPEC+="--port $(sed -e 's/:.*$//' <<< $PORT_MAPPING) "
  done
}

# Declare all constants for later use
function declareConstants() {
  AWS_EC2_AMI="ami-40142d25"
  CPU_COEF=1024
  MEMORY_COEF=926
  defineColorPalette
}

# Declare defaults for optional input values / flags
function declareInputDefaults() {
  AWS_REGION="us-east-2"
  OVERWRITE_ECR=false
  REVISION="hasnotbeenset"
}

# Define all colors used for output
function defineColorPalette() {
  COLOR_RED='\033[0;91m'
  COLOR_WHITE_BOLD='\033[1;97m'
  COLOR_NONE='\033[0m'
}

# Based on the user input and what resources are lying around in the cluster specified, check if we need to create a new EC2 instance
function determineIfCreatingNewEc2Instance() {
  CLUSTER_EXISTS=$(aws ecs describe-clusters --clusters "$CLUSTER_NAME" --region "$AWS_REGION" | jq '.clusters | length')
  if [ $CLUSTER_EXISTS -gt 0 ]; then 
    findExistingSuitableInstanceInCluster
    if [ "$INSTANCE_SUITS_TASK" == false ]; then
      CREATING_NEW_EC2_INSTANCE=true
    else
      CREATING_NEW_EC2_INSTANCE=false
    fi
  else
    CREATING_NEW_EC2_INSTANCE=true
  fi
}

# Based on the user input, check if we are creating a new task definition, using an existing one, or if the user input is invalid
function determineIfCreatingNewTaskDefinition() {
  if [ "${#DOCKER_RUN_COMMANDS}" -eq 0 ]; then
    CREATING_NEW_TASK_DEFINITION=false
    if [ "$REVISION" == "hasnotbeenset" ]; then
      REVISION="latest"
    fi
  elif [ "${#DOCKER_RUN_COMMANDS}" -ge 1 ] && [ "$REVISION" == "hasnotbeenset" ]; then
    CREATING_NEW_TASK_DEFINITION=true
  else
    echo "ERROR: Only one of the following flags should be used: One or more '--container <DOCKER RUN COMMAND>' flags to register a new task definition -OR- a single '--revision <NUMBER>' flag in order to run an existing task definition. Omitting both tags assumes you want to use an existing task defintion and the latest revision of that task"
    exit 2
  fi
}

# Determine whether the ECS task being launched requires a new task definition to be registered and/or a new EC2 instance to run on
function determineLaunchType() {
  determineIfCreatingNewTaskDefinition
  calculateSumResourceRequirementsForTask
  determineIfCreatingNewEc2Instance
  setLaunchType
}

# Exit if the `--overwrite-ecr` flag was not used and the `docker push` to ECR required to run the task would overwrite ECR
function exitIfEcrImageTagComboAlreadyExists() {
  REPO_EXISTS_IN_ECR=false
  ECR_REPOS=$(aws ecr describe-repositories --region "$AWS_REGION" | jq '.repositories')
  ECR_REPO_COUNT=$(echo "$ECR_REPOS" | jq '. | length')
  for (( ECR_REPO_INDEX=0; ECR_REPO_INDEX<ECR_REPO_COUNT; ECR_REPO_INDEX++ )); do
    THIS_ECR_REPO=$(echo "$ECR_REPOS" | jq '.['"$ECR_REPO_INDEX"']')
    THIS_ECR_REPO_NAME=$(sed -e 's/^"//' -e 's/"$//' <<< $(echo "$THIS_ECR_REPO" | jq '.repositoryName'))
    if [ "$THIS_ECR_REPO_NAME" == "$THIS_IMAGE_NAME" ]; then
      REPO_EXISTS_IN_ECR=true
      ECR_IMAGES=$(aws ecr list-images --repository-name "$THIS_ECR_REPO_NAME" --region "$AWS_REGION" | jq '.imageIds')
      ECR_IMAGE_COUNT=$(echo "$ECR_IMAGES" | jq '. | length')
      for (( ECR_IMAGE_INDEX=0; ECR_IMAGE_INDEX<ECR_IMAGE_COUNT; ECR_IMAGE_INDEX++ )); do
        ECR_IMAGE_TAG=$(sed -e 's/^"//' -e 's/"$//' <<< $(echo "$ECR_IMAGES" | jq '.['"$ECR_IMAGE_INDEX"'].imageTag'))
        if [ ! $ECR_IMAGE_TAG == null ]; then
          if [ "$ECR_IMAGE_TAG" == "$THIS_IMAGE_TAG" ]; then
            echo "ERROR: The image ""$THIS_IMAGE"" already exists in ECR. The task creation was abandoned because creating it would require overwriting the image in ECR. If you wish to use the image in ECR, run the image ecr/""$THIS_IMAGE"". If you want to use your local image, either retag it using 'docker tag ""$THIS_IMAGE"" ""$THIS_IMAGE_NAME"":<new-tag-here>' or re-run your command with the '--overwrite-ecr' flag"
            exit 2
          fi
        fi
      done
    fi
  done
}

# Exit this script if the last command ran failed
function exitIfScriptFailed() {
  if [ $? -eq 2 ]; then
    exit 2
  fi
}

# Check all the EC2 instances in the cluster specified to see if any of the
# instances will support the task definitions minimum resource requirements
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

# Having just created a new EC2 instance, query AWS for its ID and public IP
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

# Query a given EC2 instance for its remaining cpu and memory resources
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

# Based on the cpu and memory requirements of the task, find the smallest
# instance type in the T3 family of EC2 instances which is compatible
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

# Handle user input
function handleInput() {
  declareInputDefaults
  parseInputFlags "$@"
  notifyUserOfUnknownInputArgs
  parseAllDockerRunCommands
}

function launchTask() {
  if [ "$REVISION" == "hasnotbeenset" ] || [ "$REVISION" == "latest" ] ; then
    aws ecs run-task --cluster "$CLUSTER_NAME" --task-definition "$TASK_NAME" --region "$AWS_REGION"
  else
    aws ecs run-task --cluster "$CLUSTER_NAME" --task-definition "$TASK_NAME":"$REVISION" --region "$AWS_REGION"
  fi
}

# If the user provides input the script does not understand, show them which part is being ignored
function notifyUserOfUnknownInputArgs() {
  if [ ${#ARGS} -gt 0 ]; then
    echo -e "${COLOR_WHITE_BOLD}NOTICE: The following arguments were ignored: ${ARGS}"
    echo -e "${COLOR_NONE}"
  fi
}

# Parse all the `docker run` commands provided, if any
function parseAllDockerRunCommands() {
  declare -g -A CONTAINER_DEFINITIONS
  CONTAINER_DEFINITION_COUNT=0
  for DOCKER_RUN_COMMAND in "${DOCKER_RUN_COMMANDS[@]}"; do
    parseDockerRunCommand $DOCKER_RUN_COMMAND
    CONTAINER_DEFINITION_COUNT=$(($CONTAINER_DEFINITION_COUNT + 1))
  done
}

# Parse a single `docker run` command
function parseDockerRunCommand() {
  THIS_PORT_MAPPINGS=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --name) THIS_NAME="$2"; shift 2;;
      -p) THIS_PORT_MAPPINGS+=("$2"); shift 2;;
      --publish) THIS_PORT_MAPPINGS+=("$2"); shift 2;;
      -c) THIS_CPU=$(($2 * $CPU_COEF)); shift 2;;
      --cpu) THIS_CPU=$(($2 * $CPU_COEF)); shift 2;;
      -m) THIS_MEMORY=$(echo "scale=0; (($2 * $MEMORY_COEF) / 1)" | bc); shift 2;;
      --memory) THIS_MEMORY=$(echo "scale=0; (($2 * $MEMORY_COEF) / 1)" | bc); shift 2;;
      docker) shift 1;;
      run) shift 1;;
      -*) echo "unknown option: $1" >&2; exit 1;;
      *) ARGS+=("$1"); shift 1;;
    esac
  done
  for ARG in "${ARGS[@]}"; do
    if [ -n "$ARG" ]; then
      THIS_IMAGE=("$ARG")
    fi
  done
  CONTAINER_DEFINITIONS[$CONTAINER_DEFINITION_COUNT,name]="$THIS_NAME"
  CONTAINER_DEFINITIONS[$CONTAINER_DEFINITION_COUNT,image]="$THIS_IMAGE"
  CONTAINER_DEFINITIONS[$CONTAINER_DEFINITION_COUNT,cpu]="$THIS_CPU"
  CONTAINER_DEFINITIONS[$CONTAINER_DEFINITION_COUNT,memory]="$THIS_MEMORY"
  CONTAINER_DEFINITIONS[$CONTAINER_DEFINITION_COUNT,port-mappings]="${THIS_PORT_MAPPINGS[@]}"
}

# Divide the user input into variables
function parseInputFlags() {
  DOCKER_RUN_COMMANDS=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      # Required inputs
      --cluster) CLUSTER_NAME="$2"; shift 2;;
      --task) TASK_NAME="$2"; shift 2;;
      # Only one of the following inputs can be used (neither defaults to `--revision=latest`)
      --container) DOCKER_RUN_COMMANDS+=("$2"); shift 2;;
      --revision) REVISION=("$2"); shift 2;;
      # Optional inputs
      --overwrite-ecr) OVERWRITE_ECR=true; shift 1;;
      --region) AWS_REGION="$2"; shift 2;;
      # Optional inputs yet to be implemented
      --skip-output) NO_OUTPUT=true; shift 1;;
      -h) HELP_WANTED=true; shift 1;;
      --help) HELP_WANTED=true; shift 1;;
      -*) echo "unknown option: $1" >&2; exit 1;;
      *) ARGS+="$1 "; shift 1;;
    esac
  done
}

# Register a new task definition with ECS
function registerTaskDefinition() {
  validateDockerImages
  createTaskDefinitionJson
  aws ecs register-task-definition --cli-input-json "$TASK_DEFINITION" --region "$AWS_REGION" >> /dev/null
}

# Determine which "launch type" is required (based on the user input and the status of the cluster)
function setLaunchType() {
  if [ "$CREATING_NEW_TASK_DEFINITION" == true ] && [ "$CREATING_NEW_EC2_INSTANCE" == true ]; then
    LAUNCH_TYPE="new-everything"
  elif [ "$CREATING_NEW_TASK_DEFINITION" == true ] && [ "$CREATING_NEW_EC2_INSTANCE" == false ]; then
    LAUNCH_TYPE="new-task-definition"
  elif [ "$CREATING_NEW_TASK_DEFINITION" == false ] && [ "$CREATING_NEW_EC2_INSTANCE" == true ]; then
    LAUNCH_TYPE="new-instance"
  elif [ "$CREATING_NEW_TASK_DEFINITION" == false ] && [ "$CREATING_NEW_EC2_INSTANCE" == false ]; then
    LAUNCH_TYPE="existing-resources"
  else
    echo "ERROR: A valid launch type could not be determined"
    exit 2
  fi
}

# Separate the Docker image tag from the Docker image name for maximum scripting flexibility
function splitImageIntoParts() {
  if [[ "$THIS_IMAGE" =~ ^.*:.*$ ]]; then
    THIS_IMAGE_NAME="${THIS_IMAGE%:*}"
    THIS_IMAGE_TAG="${THIS_IMAGE#*:}"
  else
    THIS_IMAGE_NAME="$THIS_IMAGE"
    THIS_IMAGE_TAG="latest"
    THIS_IMAGE="$THIS_IMAGE_NAME"":""$THIS_IMAGE_TAG"
  fi
  USER_SPECIFIED_ECR=false
  if [[ "$THIS_IMAGE" =~ ^ecr/.* ]]; then
    USER_SPECIFIED_ECR=true
  fi
}

# Validate all Docker images specified in a task defintion or `docker run` command exist
function validateDockerImages() {
  $(aws ecr get-login --no-include-email --region us-east-2) >/dev/null 2>/dev/null
  IMAGE_INDEX=0
  for CONTAINER_DEFINITIONS in ${!CONTAINER_DEFINITIONS@}; do
    validateDockerImage
    IMAGE_INDEX=$((IMAGE_INDEX + 1))
  done
}

# Validate a Docker image specified in a task definition or `docker run` command exists
function validateDockerImage() {
  THIS_IMAGE="${CONTAINER_DEFINITIONS[$IMAGE_INDEX,image]}"
  splitImageIntoParts
  if [ "$USER_SPECIFIED_ECR" == true ]; then
    validateEcrDockerImage
  else
    validateLocalDockerOrDockerHubImage
  fi
}

# Validate a Docker image exists in ECR
function validateEcrDockerImage() {
  IMAGE_EXISTS_IN_ECR=false
  ECR_REPOS=$(aws ecr describe-repositories --region "$AWS_REGION" | jq '.repositories')
  ECR_REPO_COUNT=$(echo "$ECR_REPOS" | jq '. | length')
  THIS_IMAGE_NAME=$(echo -n "$THIS_IMAGE_NAME" | tail -c +5)
  for (( ECR_REPO_INDEX=0; ECR_REPO_INDEX<ECR_REPO_COUNT; ECR_REPO_INDEX++ )); do
    THIS_ECR_REPO=$(echo "$ECR_REPOS" | jq '.['"$ECR_REPO_INDEX"']')
    THIS_ECR_REPO_NAME=$(sed -e 's/^"//' -e 's/"$//' <<< $(echo "$THIS_ECR_REPO" | jq '.repositoryName'))
    if [ "$THIS_ECR_REPO_NAME" == "$THIS_IMAGE_NAME" ]; then
      REPO_EXISTS_IN_ECR=true
      ECR_IMAGES=$(aws ecr list-images --repository-name "$THIS_ECR_REPO_NAME" --region "$AWS_REGION" | jq '.imageIds')
      ECR_IMAGE_COUNT=$(echo "$ECR_IMAGES" | jq '. | length')
      for (( ECR_IMAGE_INDEX=0; ECR_IMAGE_INDEX<ECR_IMAGE_COUNT; ECR_IMAGE_INDEX++ )); do
        ECR_IMAGE_TAG=$(sed -e 's/^"//' -e 's/"$//' <<< $(echo "$ECR_IMAGES" | jq '.['"$ECR_IMAGE_INDEX"'].imageTag'))
        if [ ! $ECR_IMAGE_TAG == null ]; then
          if [ "$ECR_IMAGE_TAG" == "$THIS_IMAGE_TAG" ]; then
            IMAGE_EXISTS_IN_ECR=true
            THIS_ECR_REPO_URI=$(sed -e 's/^"//' -e 's/"$//' <<< $(echo "$THIS_ECR_REPO" | jq '.repositoryUri'))
            CONTAINER_DEFINITIONS[$IMAGE_INDEX,image]="$THIS_ECR_REPO_URI":"$THIS_IMAGE_TAG"
            break
          fi
        fi
      done
    fi
  done
  if [ "$IMAGE_EXISTS_IN_ECR" == false ]; then
    echo "ERROR: The image ""$THIS_IMAGE"" could not be found in ECR. Are you using the correct AWS account and region? Are you using the correct tag?"
    exit 2
  fi
}

# Validate a Docker image exists either locally or on Docker Hub
function validateLocalDockerOrDockerHubImage() {
  DOCKER_IMAGES_EMPTY_OUTPUT_SIZE=84
  IMAGE_EXISTS_LOCALLY=false
  IMAGE_EXISTS_ON_DOCKER_HUB=false
  LOCAL_DOCKER_IMAGES=$(docker images "$THIS_IMAGE")
  if [ ! "${#LOCAL_DOCKER_IMAGES}" -eq $DOCKER_IMAGES_EMPTY_OUTPUT_SIZE ]; then
    IMAGE_EXISTS_LOCALLY=true
  fi
  if [ "$IMAGE_EXISTS_LOCALLY" == true ]; then
    if [ "$OVERWRITE_ECR" == false ]; then
      exitIfEcrImageTagComboAlreadyExists
    fi
    if [ "$REPO_EXISTS_IN_ECR" == false ]; then
      ECR_REPOSITORY_URI=$(sed -e 's/^"//' -e 's/"$//' <<< $(aws ecr create-repository --repository-name "$THIS_IMAGE_NAME" --region "$AWS_REGION" | jq '.repository.repositoryUri'))
    else
      ECR_REPOSITORY_URI=$(sed -e 's/^"//' -e 's/"$//' <<< $(aws ecr describe-repositories --repository "$THIS_IMAGE_NAME" --region "$AWS_REGION" | jq '.repositories[0].repositoryUri'))
    fi
    THIS_IMAGE_ECR="$ECR_REPOSITORY_URI":"$THIS_IMAGE_TAG"
    docker tag "$THIS_IMAGE" "$THIS_IMAGE_ECR"
    docker push "$THIS_IMAGE_ECR" >> /dev/null
    CONTAINER_DEFINITIONS[$IMAGE_INDEX,image]="$THIS_IMAGE_ECR"
  else
    # TODO: Check if image exists on Docker Hub
    echo Image does not exist locally
  fi
}

# Stall execution until the newly created EC2 instance is registered in the specified ECS cluster
function waitUntilInstanceRegisteredInCluster() {
  while : ; do
    CLUSTER_INSTANCES=$(aws ecs list-container-instances --cluster "$CLUSTER_NAME" --region "$AWS_REGION" | jq '.containerInstanceArns')
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

declareConstants
handleInput "$@"
determineLaunchType
createClusterIfDoesNotExist
if [ "$LAUNCH_TYPE" == "new-everything" ]; then
  createAndRegisterNewInstance
  registerTaskDefinition
  launchTask
elif [ "$LAUNCH_TYPE" == "new-instance" ]; then
  createAndRegisterNewInstance
  launchTask
elif [ "$LAUNCH_TYPE" == "new-task-definition" ]; then
  registerTaskDefinition
  launchTask
elif [ "$LAUNCH_TYPE" == "existing-resources" ]; then
  launchTask
else
  echo "ERROR: A valid launch type could not be determined"
  exit 2
fi

# if launchType == new-everything {
# } else if launchType == new-instance {
# } else if launchType == new-task-definition {
#   openSecurityForContainerPorts
# } else if launchType == existing-resources {
#   openSecurityForContainerPorts
# }
