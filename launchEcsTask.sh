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
  declare -g -A CONTAINER_DEFINITIONS
  CONTAINER_DEFINITION_MAX_INDEX=0
  for CONTAINER in "${CONTAINERS[@]}"; do
    parseDockerRunCommand $CONTAINER
    CONTAINER_DEFINITION_MAX_INDEX=$(($CONTAINER_DEFINITION_MAX_INDEX + 1))
  done
}

function parseDockerRunCommand() {
  ARGS=()
  THIS_NAME=""
  THIS_PORT_MAPPINGS=()
  THIS_CPU=""
  THIS_MEMORY=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --name) THIS_NAME=("$2"); shift 2;;
      -p) THIS_PORT_MAPPINGS+=("$2"); shift 2;;
      --publish) THIS_PORT_MAPPINGS+=("$2"); shift 2;;
      -c) THIS_CPU=($(($2 * $CPU_COEF))); shift 2;;
      --cpu) THIS_CPU=($(($2 * $CPU_COEF))); shift 2;;
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
  CONTAINER_DEFINITIONS[$CONTAINER_DEFINITION_MAX_INDEX,name]="$THIS_NAME"
  CONTAINER_DEFINITIONS[$CONTAINER_DEFINITION_MAX_INDEX,image]="${THIS_IMAGE}"
  CONTAINER_DEFINITIONS[$CONTAINER_DEFINITION_MAX_INDEX,cpu]="$THIS_CPU"
  CONTAINER_DEFINITIONS[$CONTAINER_DEFINITION_MAX_INDEX,memory]="$THIS_MEMORY"
  CONTAINER_DEFINITIONS[$CONTAINER_DEFINITION_MAX_INDEX,port-mappings]="${THIS_PORT_MAPPINGS[@]}"
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
  CPU_REQUIREMENT=$EXISTING_TASK_CPU_REQUIREMENT
  MEMORY_REQUIREMENT=$EXISTING_TASK_MEMORY_REQUIREMENT
  for (( CONTAINER_DEFINITIONS_INDEX=0; CONTAINER_DEFINITIONS_INDEX<CONTAINER_DEFINITION_MAX_INDEX; CONTAINER_DEFINITIONS_INDEX++ )); do
    echo ${CONTAINER_DEFINITIONS[$CONTAINER_DEFINITIONS_INDEX,cpu]}
    echo ${CONTAINER_DEFINITIONS[$CONTAINER_DEFINITIONS_INDEX,memory]}
    CPU_REQUIREMENT=$(($CPU_REQUIREMENT + ${CONTAINER_DEFINITIONS[$CONTAINER_DEFINITIONS_INDEX,cpu]}))
    MEMORY_REQUIREMENT=$(($CPU_REQUIREMENT + ${CONTAINER_DEFINITIONS[$CONTAINER_DEFINITIONS_INDEX,memory]}))
  done
#  for CPU_VALUE in "${CPU[@]}"; do
#    CPU_REQUIREMENT=$(($CPU_REQUIREMENT + $CPU_VALUE))
#  done
#  for MEMORY_VALUE in "${MEMORY[@]}"; do
#    MEMORY_REQUIREMENT=$(($MEMORY_REQUIREMENT + $MEMORY_VALUE))
#  done
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
    validateDockerImages
    createTaskDefinitionJson
    registerTaskDefinition
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
    EXISTING_TASK_CPU_REQUIREMENT+=($THIS_CONTAINER_CPU_REQUIREMENT)
    EXISTING_TASK_MEMORY_REQUIREMENT+=($THIS_CONTAINER_MEMORY_REQUIREMENT)
  done
}

function createNewInstanceOpenPortSpec() {
  NEW_INSTANCE_OPEN_PORTS_SPEC=""
  for PORT_MAPPING in "${PORT_MAPPINGS[@]}"; do
    NEW_INSTANCE_OPEN_PORTS_SPEC+="--port $(sed -e 's/:.*$//' <<< $PORT_MAPPING) "
  done
}

function createTaskDefinitionJson() {
	TASK_DEFINITION=$(cat <<-EOF
		{
		  "family": "$TASK_NAME",
		  "containerDefinitions": [
	EOF
  )
  CONTAINER_INDEX=0
  for CONTAINER_DEFINITIONS in ${!CONTAINER_DEFINITIONS@}; do
    if [ $CONTAINER_INDEX -eq 0 ]; then
			TASK_DEFINITION="$TASK_DEFINITION"$(cat <<-EOF

				    {

			EOF
			)
    else
			TASK_DEFINITION="$TASK_DEFINITION"$(cat <<-EOF

				    },
				    {

			EOF
			)
    fi
		TASK_DEFINITION="$TASK_DEFINITION"$(cat <<-EOF

			      "name": "${CONTAINER_DEFINITIONS[0,name]}",
			      "image": "${CONTAINER_DEFINITIONS[0,image]}",
			      "cpu": ${CONTAINER_DEFINITIONS[0,cpu]},
			      "memory": ${CONTAINER_DEFINITIONS[0,memory]},
			      "essential": true,
			      "portMappings": [

		EOF
		)
    PORT_MAPPINGS=(${CONTAINER_DEFINITIONS[0,port-mappings]})
    PORT_MAPPINGS_INDEX=0
    for PORT_MAPPING in "${PORT_MAPPINGS[@]}"; do
      if [ $PORT_MAPPINGS_INDEX -eq 0 ]; then
				TASK_DEFINITION="$TASK_DEFINITION"$(cat <<-EOF

					        {

				EOF
				)
      else
				TASK_DEFINITION="$TASK_DEFINITION"$(cat <<-EOF

					        },
					        {

				EOF
				)
      fi
      HOST_PORT=$(sed -e 's/:.*$//g' <<< $PORT_MAPPING)
      CONTAINER_PORT=$(sed -e 's/^.*://g' <<< $PORT_MAPPING)
			TASK_DEFINITION="$TASK_DEFINITION"$(cat <<-EOF

				          "hostPort": $HOST_PORT,
				          "containerPort": $CONTAINER_PORT,
				          "protocol": "tcp"

			EOF
			)
      PORT_MAPPINGS_INDEX=$(($PORT_MAPPINGS_INDEX + 1))
    done
    if [ $PORT_MAPPINGS_INDEX -ge 1 ]; then
			TASK_DEFINITION="$TASK_DEFINITION"$(cat <<-EOF

					        }

			EOF
			)
    fi
		TASK_DEFINITION="$TASK_DEFINITION"$(cat <<-EOF

			      ]

		EOF
		)
    CONTAINER_INDEX=$(($CONTAINER_INDEX + 1))
  done
	TASK_DEFINITION="$TASK_DEFINITION"$(cat <<-EOF

		    }
		  ]
		}
	EOF
  )
  echo "$TASK_DEFINITION"
  exit 2
}

function registerTaskDefinition() {
  aws ecs register-task-definition --cli-input-json "$TASK_DEFINITION" --region "$AWS_REGION" >> /dev/null
}

function validateDockerImages() {
  $(aws ecr get-login --no-include-email --region us-east-2) >/dev/null 2>/dev/null
  IMAGE_INDEX=0
  for CONTAINER_DEFINITIONS in ${!CONTAINER_DEFINITIONS@}; do
    validateDockerImage
    IMAGE_INDEX=$((IMAGE_INDEX + 1))
  done
}

function validateDockerImage() {
  THIS_IMAGE="${CONTAINER_DEFINITIONS[$IMAGE_INDEX,image]}"
  splitImageIntoParts
  if [ "$USER_SPECIFIED_ECR" == true ]; then
    validateEcrDockerImage
  else
    validateLocalDockerOrDockerHubImage
  fi
}

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

declareConstants
handleInput "$@"
defineColorPalette
createClusterIfItDoesNotExist
calculateSumResourceRequirementsForTask
findExistingSuitableInstanceInCluster
#editSuitableInstanceOpenPorts
getMinimumSuitableInstanceType
createAndRegisterNewInstanceIfNeeded
registerEcsTaskDefinitionIfNeeded
launchTask
