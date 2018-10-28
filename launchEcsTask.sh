#! /bin/bash

function startMonitoringProgress() {
  defineExpectedProgress
  PROGRESS_FILE=$(mktemp /tmp/monitor-progress.XXXXXXX)
  sudo chmod 775 "$PROGRESS_FILE"
  trap 'stopMonitoringProgress; exit' SIGINT; ./util/monitorProgress.sh "$PROGRESS_FILE" "$EXPECTED_PROGRESS" & MONITOR_PROGRESS_PID=$!
  echo "declare -A STEPS_COMPLETED" | sudo tee --append "$PROGRESS_FILE" >> /dev/null
}

function stopMonitoringProgress() {
  sleep 2
  STILL_MONITORING_PROGRESS=$(ps -a | grep $MONITOR_PROGRESS_PID)
  if [ ! "$STILL_MONITORING_PROGRESS" == "" ]; then
    kill $MONITOR_PROGRESS_PID >/dev/null 2>/dev/null
  fi
  if [ -f "$PROGRESS_FILE" ]; then
    rm -Rf "$PROGRESS_FILE"
  fi
}

# After parsing a `docker run` command, add to the container definitions associative array
function addParsedDockerRunToContainerDefinitions() {
  if [ -n "$THIS_NAME" ]; then
    CONTAINER_DEFINITIONS[$CONTAINER_DEFINITION_COUNT,name]="$THIS_NAME"
  else
    echo -e "${COLOR_RED}"
    echo "ERROR: Container name cannot be blank in 'docker run' command"
    echo -e "${COLOR_NONE}"
    exit 2
  fi
  if [ -n "$THIS_IMAGE" ]; then
    CONTAINER_DEFINITIONS[$CONTAINER_DEFINITION_COUNT,image]="$THIS_IMAGE"
  else
    echo -e "${COLOR_RED}"
    echo "ERROR: Container image cannot be blank in 'docker run' command"
    echo -e "${COLOR_NONE}"
    exit 2
  fi
  CONTAINER_DEFINITIONS[$CONTAINER_DEFINITION_COUNT,cpu]="$THIS_CPU"
  CONTAINER_DEFINITIONS[$CONTAINER_DEFINITION_COUNT,memory]="$THIS_MEMORY"
  CONTAINER_DEFINITIONS[$CONTAINER_DEFINITION_COUNT,port-mappings]="${THIS_PORT_MAPPINGS[@]}"
  CONTAINER_DEFINITIONS[$CONTAINER_DEFINITION_COUNT,environment-variables]="${THIS_ENVIRONMENT_VARS[@]}"
}

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
    echo -e "${COLOR_RED}"
    echo "ERROR: The revision number specifed does not exist"
    echo -e "${COLOR_NONE}"
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
    MEMORY_REQUIREMENT=$(($MEMORY_REQUIREMENT + ${CONTAINER_DEFINITIONS[$CONTAINER_DEFINITION_INDEX,memory]}))
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

# Query the status of the cluster name provided to set the CLUSTER_ACTIVE variable
function checkIfClusterActive() {
  CLUSTER_ACTIVE=false
  CLUSTER_DESCRIPTION=$(aws ecs describe-clusters --clusters "$CLUSTER_NAME" --region "$AWS_REGION" | jq '.clusters')
  if [ $(echo "$CLUSTER_DESCRIPTION" | jq '.[0].status') == \"ACTIVE\" ]; then
    CLUSTER_ACTIVE=true
  fi
}

# Check if a given EC2 instance's remaining cpu and memory resources will allow a task definition to run
function checkIfInstanceSuitsTask() {
  if [ $THIS_INSTANCE_CPU_REMAINING -ge $CPU_REQUIREMENT ] && [ $THIS_INSTANCE_MEMORY_REMAINING -ge $MEMORY_REQUIREMENT ]; then
    INSTANCE_SUITS_TASK="$THIS_INSTANCE_ARN"
    break
  fi
}

function createUserDataScript() {
  ./util/installEcsAgentOnEc2InstanceGenerator.sh "$CLUSTER_NAME"
}

# Create an EC2 instance and register it with the cluster
function createAndRegisterNewInstance() {
  if [ "$INSTANCE_SUITS_TASK" == false ] || [ -z "$INSTANCE_SUITS_TASK"]; then
    getMinimumSuitableInstanceType
    getNewUniqueInstanceName
    createNewInstanceOpenPortSpec
    createUserDataScript
    COMMAND="./createEc2Instance.sh --name "$NEW_INSTANCE_NAME" --image "$AWS_EC2_AMI" --type "$MINIMUM_SUITABLE_INSTANCE_TYPE" --iam-role jenkins_instance --port 22 "$NEW_INSTANCE_OPEN_PORTS_SPEC" --startup-script util/installEcsAgentOnEc2Instance.sh"
    if [ "$USE_EXISTING_KEY_PAIR" == "true" ]; then
      COMMAND+=" --key-pair $EXISTING_KEY_PAIR"
    fi
    $($COMMAND >> /dev/null)
    exitIfScriptFailed
    echo "STEPS_COMPLETED[launch-ec2-instance]=true" | sudo tee --append "$PROGRESS_FILE" >> /dev/null
    findNewInstanceInformation
    waitUntilInstanceRegisteredInCluster
  fi
}

# If the cluster specified does not exist, create it
function createClusterIfDoesNotExist() {
  checkIfClusterActive
  if [ "$CLUSTER_ACTIVE" == false ]; then
    ./util/createEcsCluster.sh --name "$CLUSTER_NAME" --region "$AWS_REGION"
    echo "STEPS_COMPLETED[create-cluster]=true" | sudo tee --append "$PROGRESS_FILE" >> /dev/null
  fi
}

# Create a repository on ECR to house a local image
function createEcrRepository() {
  ECR_REPOSITORY_URI=$(sed -e 's/^"//' -e 's/"$//' <<< $(aws ecr create-repository --repository-name "$THIS_IMAGE_NAME" --region "$AWS_REGION" | jq '.repository.repositoryUri'))
}

# Create a string recognized by the `createEc2Instance.sh` script which will open the ports necessary to run the task
function createNewInstanceOpenPortSpec() {
  NEW_INSTANCE_OPEN_PORTS_SPEC=""
  for PORT_MAPPING in "${PORT_MAPPINGS[@]}"; do
    NEW_INSTANCE_OPEN_PORTS_SPEC+="--port $(sed -e 's/:.*$//' <<< $PORT_MAPPING) "
  done
  echo "STEPS_COMPLETED[create-port-spec]=true" | sudo tee --append "$PROGRESS_FILE" >> /dev/null
}

# Create a JSON structure for use in the AWS command `aws ecs register-task-definition`
function createTaskDefinitionJson() {
	TASK_DEFINITION=$(cat <<-EOF
		{
		  "family": "$TASK_NAME",
		  "containerDefinitions": [
	EOF
  )
  CONTAINER_INDEX=0
  while [ $CONTAINER_INDEX -lt $CONTAINER_COUNT ]; do
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

			      "name": "${CONTAINER_DEFINITIONS[$CONTAINER_INDEX,name]}",
			      "image": "${CONTAINER_DEFINITIONS[$CONTAINER_INDEX,image]}",
			      "cpu": ${CONTAINER_DEFINITIONS[$CONTAINER_INDEX,cpu]},
			      "memory": ${CONTAINER_DEFINITIONS[$CONTAINER_INDEX,memory]},
			      "essential": true,
			      "portMappings": [

		EOF
		)
    PORT_MAPPINGS=(${CONTAINER_DEFINITIONS[$CONTAINER_INDEX,port-mappings]})
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

			      ],
			      "environment": [

		EOF
		)
    ENVIRONMENT_VARIABLES=(${CONTAINER_DEFINITIONS[$CONTAINER_INDEX,environment-variables]})
    ENVIRONMENT_VARIABLES_INDEX=0
    for ENVIRONMENT_VARIABLE in "${ENVIRONMENT_VARIABLES[@]}"; do
      if [ $ENVIRONMENT_VARIABLES_INDEX -eq 0 ]; then
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
      VARIABLE_NAME=$(sed -e 's/=.*$//g' <<< $ENVIRONMENT_VARIABLE)
      VARIABLE_VALUE=$(sed -e 's/^.*=//g' <<< $ENVIRONMENT_VARIABLE)
			TASK_DEFINITION="$TASK_DEFINITION"$(cat <<-EOF

				          "name": "$VARIABLE_NAME",
				          "value": "$VARIABLE_VALUE"

			EOF
			)
      ENVIRONMENT_VARIABLES_INDEX=$(($ENVIRONMENT_VARIABLES_INDEX + 1))
    done
    if [ $ENVIRONMENT_VARIABLES_INDEX -ge 1 ]; then
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
  echo "STEPS_COMPLETED[create-task-json]=true" | sudo tee --append "$PROGRESS_FILE" >> /dev/null
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
  DEFAULT_CPU=1024 # 1 vCPU
  DEFAULT_MEMORY=463 # 0.5 GB
  OVERWRITE_ECR=false
  REVISION="hasnotbeenset"
}

# Define all colors used for output
function defineColorPalette() {
  COLOR_BLUE='\033[0;34m'
	COLOR_GREEN='\033[0;32m'
  COLOR_RED='\033[0;91m'
  COLOR_WHITE='\033[0;97m'
  COLOR_WHITE_BOLD='\033[1;97m'
  COLOR_NONE='\033[0m'
}

# Based on the user input and what resources are lying around in the cluster specified, check if we need to create a new EC2 instance
function determineIfCreatingNewEc2Instance() {
  checkIfClusterActive
  if [ "$CLUSTER_ACTIVE" == true ]; then
    findExistingSuitableInstanceInCluster
    if [ "$INSTANCE_SUITS_TASK" == false ] || [ -z "$INSTANCE_SUITS_TASK" ]; then
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
    echo -e "${COLOR_RED}"
    echo "ERROR: The combination of '--container' and '--revision' flags provided is invalid. Please retry your command modified to suit one of the following conditions:"
    echo -e "${COLOR_WHITE}    * One or more '--container <DOCKER RUN COMMAND>' flags to register a new task definition"
    echo "    * A single '--revision <NUMBER>' flag in order to run an existing task definition"
    echo "    * Omitting both tags to use the latest revision of an existing task defintion"
    echo -e "${COLOR_NONE}"
    exit 2
  fi
}

# Check if a Docker image exists locally
function determineIfDockerImageExistsLocally() {
  IMAGE_EXISTS_LOCALLY=false
  DOCKER_IMAGES_EMPTY_OUTPUT_SIZE=84
  LOCAL_DOCKER_IMAGES=$(docker images "$THIS_IMAGE")
  if [ ! "${#LOCAL_DOCKER_IMAGES}" -eq $DOCKER_IMAGES_EMPTY_OUTPUT_SIZE ]; then
    IMAGE_EXISTS_LOCALLY=true
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
function ensureNoEcrConflict() {
  if [ "$OVERWRITE_ECR" == false ]; then
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
              echo -e "${COLOR_RED}"
              echo "ERROR: Task creation was abandoned because it would require overwriting the ""$THIS_IMAGE"""
              echo "image in ECR. Please retry your command modified to suit one of the following conditions:"
              echo -e "${COLOR_WHITE}    * If you wish to use the image in ECR, specify your image using the ECR shortcut as follows: 'ecr/""$THIS_IMAGE""'"
              echo "    * If you want to use your local image, either:"
              echo "        * Retag it using 'docker tag ""$THIS_IMAGE"" ""$THIS_IMAGE_NAME"":<new-tag-here>' -OR-"
              echo "        * Retry your command with the '--overwrite-ecr' flag"
              echo -e "${COLOR_NONE}"
              exit 2
            fi
          fi
        done
      fi
    done
  fi
}

# Print an error and exit due to an invalid launch type
function exitDueToInvalidLaunchType() {
  echo -e "${COLOR_RED}"
  echo "ERROR: Something went wrong on our end. A valid launch type could not be determined. This means we could not decide if we need to create a new EC2 instance or a new ECS task definition"
  echo -e "${COLOR_BLUE}"
  echo "If running the same command again does not fix the problem, contact Jeff at jdiederiks@psi-it.com"
  echo -e "${COLOR_NONE}"
  exit 2
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
  FAILED_QUERY_COUNT=0
  while [ $FAILED_QUERY_COUNT -lt 3 ]; do
    EC2_INSTANCES=$(aws ec2 describe-instances --query 'Reservations[*].Instances[*].[State.Name,Tags[?Key==`Name`].Value,PublicIpAddress,InstanceId]' --region "$AWS_REGION")
    INSTANCE_COUNT=$(echo $EC2_INSTANCES | jq '. | length')
    for (( INSTANCE_INDEX=0; INSTANCE_INDEX<INSTANCE_COUNT; INSTANCE_INDEX++ )); do
      THIS_INSTANCE=$(echo $EC2_INSTANCES | jq '.['"$INSTANCE_INDEX"'][0]')
      THIS_INSTANCE_STATE=$(echo $THIS_INSTANCE | jq '.[0]')
      THIS_INSTANCE_NAME=$(sed -e 's/^"//' -e 's/"$//' <<< $(echo $THIS_INSTANCE | jq '.[1][0]'))
      if [ "$THIS_INSTANCE_STATE" == \"running\" ] && [ "$THIS_INSTANCE_NAME" == "$NEW_INSTANCE_NAME" ]; then
        THIS_INSTANCE_IP=$(sed -e 's/^"//' -e 's/"$//' <<< $(echo $THIS_INSTANCE | jq '.[2]'))
        THIS_INSTANCE_ID=$(sed -e 's/^"//' -e 's/"$//' <<< $(echo $THIS_INSTANCE | jq '.[3]'))
        break 2
      fi
    done
    FAILED_QUERY_COUNT=$(($FAILED_QUERY_COUNT + 1))
  done
  if [ -z "$THIS_INSTANCE_IP" ]; then
    echo "STEPS_COMPLETED[collect-new-instance-info]=false" | sudo tee --append "$PROGRESS_FILE" >> /dev/null
    echo -e "${COLOR_RED}"
    echo "ERROR: Something went wrong on our end. The (supposedly) newly created EC2 instance could not be found"
    echo -e "${COLOR_BLUE}"
    echo "If running the same command again does not fix the problem, contact Jeff at jdiederiks@psi-it.com"
    echo -e "${COLOR_NONE}"
    exit 2
  else
    NEW_INSTANCE_PUBLIC_IP=$THIS_INSTANCE_IP
    NEW_INSTANCE_ID=$THIS_INSTANCE_ID
    echo "STEPS_COMPLETED[collect-new-instance-info]=true" | sudo tee --append "$PROGRESS_FILE" >> /dev/null
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

# Get the URI of an ECR repository to substitute the ECR shortcut (i.e. ecr/imagename) for the full URI
function getEcrRepositoryUri() {
  ECR_REPOSITORY_URI=$(sed -e 's/^"//' -e 's/"$//' <<< $(aws ecr describe-repositories --repository "$THIS_IMAGE_NAME" --region "$AWS_REGION" | jq '.repositories[0].repositoryUri'))
}

# Based on the cpu and memory requirements of the task, find the smallest
# instance type in the T3 family of EC2 instances which is compatible
function getMinimumSuitableInstanceType() {
  . ./util/awsT3InstanceSpecs.sh
  MINIMUM_SUITABLE_INSTANCE_TYPE=false
  INSTANCE_SPEC_INDEX=0
  while [ $INSTANCE_SPEC_INDEX -lt $INSTANCE_SPEC_COUNT ]; do
    if [ ${AWS_T3_INSTANCE_SPECS[$INSTANCE_SPEC_INDEX,cpu]} -ge $CPU_REQUIREMENT ] && [ ${AWS_T3_INSTANCE_SPECS[$INSTANCE_SPEC_INDEX,memory]} -ge $MEMORY_REQUIREMENT ]; then
      MINIMUM_SUITABLE_INSTANCE_TYPE=${AWS_T3_INSTANCE_SPECS[$INSTANCE_SPEC_INDEX,name]}
      echo "STEPS_COMPLETED[determine-instance-type]=true" | sudo tee --append "$PROGRESS_FILE" >> /dev/null
      break
    fi
    ((INSTANCE_SPEC_INDEX++))
  done
}

# Get a unique name in the form of `ecs-<CLUSTER_NAME>-<UNIQUE_NUMBER>` which
# does not conflict with any existing EC2 key pair or EC2 security group names
function getNewUniqueInstanceName() {
  CLUSTER_STATUS=$(aws ecs describe-clusters --clusters "$CLUSTER_NAME" --region "$AWS_REGION" | jq '.clusters[0]')
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
  echo "STEPS_COMPLETED[create-instance-name]=true" | sudo tee --append "$PROGRESS_FILE" >> /dev/null
}

# Handle user input
function handleInput() {
  declareInputDefaults
  parseInputFlags "$@"
  showHelp
  notifyUserOfUnknownInputArgs
  parseAllDockerRunCommands
}

# Run an ECS task
function launchTask() {
  if [ "$REVISION" == "hasnotbeenset" ] || [ "$REVISION" == "latest" ] ; then
    ECS_LAUNCH_STATUS=$(aws ecs run-task --cluster "$CLUSTER_NAME" --task-definition "$TASK_NAME" --region "$AWS_REGION")
  else
    ECS_LAUNCH_STATUS=$(aws ecs run-task --cluster "$CLUSTER_NAME" --task-definition "$TASK_NAME":"$REVISION" --region "$AWS_REGION")
  fi
  echo "STEPS_COMPLETED[launch-task]=true" | sudo tee --append "$PROGRESS_FILE" >> /dev/null
}

# Perform a `docker login` to ECR
function loginToEcr() {
  $(aws ecr get-login --no-include-email --region "$AWS_REGION") >/dev/null 2>/dev/null
}

# If the user provides input the script does not understand, show them which part is being ignored
function notifyUserOfUnknownInputArgs() {
  if [ ${#ARGS} -gt 0 ]; then
    echo -e "${COLOR_WHITE_BOLD}NOTICE: The following arguments were ignored: ${ARGS}"
    echo -e "${COLOR_NONE}"
  fi
}

# Hop around various AWS commands before finding the security group of
# the container instance's corresponding EC2 instance of the ECS task
function huntDownSecurityGroupOfTask() {
  CONTAINER_INSTANCE_ARN_OF_TASK=$(echo "$ECS_LAUNCH_STATUS" | jq '.tasks[0].containerInstanceArn')
  CONTAINER_INSTANCE_ID_OF_TASK=$(sed -e 's/^.*\///' -e 's/"$//' <<< $(echo "$CONTAINER_INSTANCE_ARN_OF_TASK"))
  EC2_ID_OF_TASK=$(sed -e 's/^"//' -e 's/"$//' <<< $(aws ecs describe-container-instances --cluster "$CLUSTER_NAME" --container-instances "$CONTAINER_INSTANCE_ID_OF_TASK" --region "$AWS_REGION" | jq '.containerInstances[0].ec2InstanceId'))
  CONTAINER_INSTANCE_TASK_COUNT=$(aws ecs describe-container-instances --cluster "$CLUSTER_NAME" --container-instances "$CONTAINER_INSTANCE_ID_OF_TASK" --region "$AWS_REGION" | jq '.containerInstances[0].runningTasksCount')
  SECURITY_GROUP_OF_TASK=$(sed -e 's/^"//' -e 's/"$//' <<< $(aws ec2 describe-instances --instance-ids "$EC2_ID_OF_TASK" --region "$AWS_REGION" | jq '.Reservations[0].Instances[0].NetworkInterfaces[0].Groups[0].GroupId'))
  echo "STEPS_COMPLETED[find-security-group]=true" | sudo tee --append "$PROGRESS_FILE" >> /dev/null
}

# If a container instance is about to run a new task and has no tasks currently
# running on it, revoke all the ingress port rules on the matching security group
function revokeAllSecurityRules() {
  if [ $CONTAINER_INSTANCE_TASK_COUNT -eq 0 ]; then
    SECURITY_GROUP_PORTS_ALLOWED=$(aws ec2 describe-security-groups --group-ids "$SECURITY_GROUP_OF_TASK" --region "$AWS_REGION" | jq '.SecurityGroups[0].IpPermissions')
    PORT_ALLOWED_COUNT=$(echo "$SECURITY_GROUP_PORTS_ALLOWED" | jq '. | length')
    for (( PORT_ALLOWED_INDEX=0; PORT_ALLOWED_INDEX<PORT_ALLOWED_COUNT; PORT_ALLOWED_INDEX++ )); do
      PORT_ALLOWED=$(echo "$SECURITY_GROUP_PORTS_ALLOWED" | jq '.['"$PORT_ALLOWED_INDEX"']')
      FROM_PORT=$(echo "$PORT_ALLOWED" | jq '.FromPort')
      TO_PORT=$(echo "$PORT_ALLOWED" | jq '.ToPort')
      for (( PORT_INDEX=FROM_PORT; PORT_INDEX<=TO_PORT; PORT_INDEX++ )); do
        aws ec2 revoke-security-group-ingress --group-id "$SECURITY_GROUP_OF_TASK" --protocol tcp --port $PORT_INDEX --cidr 0.0.0.0/0 --region "$AWS_REGION"
      done
    done
  fi
  echo "STEPS_COMPLETED[revoke-port-permissions]=true" | sudo tee --append "$PROGRESS_FILE" >> /dev/null
}

# Authorize the necessary ports for an ECS task
function authorizeNecessarySecurityRulesForTask() {
  if [ "${#EXISTING_TASK_HOST_PORTS[@]}" -gt 0 ]; then
    for PORT in "${EXISTING_TASK_HOST_PORTS[@]}"; do
      aws ec2 authorize-security-group-ingress --group-id "$SECURITY_GROUP_OF_TASK" --protocol tcp --port "$PORT" --cidr 0.0.0.0/0 --region "$AWS_REGION" 2>/dev/null
    done
  else
    for PORT_MAPPING in "${PORT_MAPPINGS[@]}"; do
      PORT_TO_AUTHORIZE=$(sed -e 's/:.*//' <<< $(echo "$PORT_MAPPING"))
      aws ec2 authorize-security-group-ingress --group-id "$SECURITY_GROUP_OF_TASK" --protocol tcp --port "$PORT_TO_AUTHORIZE" --cidr 0.0.0.0/0 --region "$AWS_REGION" 2>/dev/null
    done
  fi
  echo "STEPS_COMPLETED[authorize-port-permissions]=true" | sudo tee --append "$PROGRESS_FILE" >> /dev/null
}

# Change the ingress port security rules for an existing container instance to match the requirements of the task running on it
function editSecurityRulesForContainerPorts() {
  huntDownSecurityGroupOfTask
  revokeAllSecurityRules
  authorizeNecessarySecurityRulesForTask
}

# Parse all the `docker run` commands provided, if any
function parseAllDockerRunCommands() {
  declare -g -A CONTAINER_DEFINITIONS
  CONTAINER_DEFINITION_COUNT=0
  for DOCKER_RUN_COMMAND in "${DOCKER_RUN_COMMANDS[@]}"; do
    parseDockerRunCommand $DOCKER_RUN_COMMAND
    addParsedDockerRunToContainerDefinitions
    CONTAINER_DEFINITION_COUNT=$(($CONTAINER_DEFINITION_COUNT + 1))
  done
}

# Parse a single `docker run` command
function parseDockerRunCommand() {
  THIS_ARGS=()
  THIS_NAME=''
  THIS_IMAGE=()
  THIS_ENVIRONMENT_VARS=()
  THIS_CPU=$DEFAULT_CPU
  THIS_MEMORY=$DEFAULT_MEMORY
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
      -e) THIS_ENVIRONMENT_VARS+=("$2"); shift 2;;
      --env) THIS_ENVIRONMENT_VARS+=("$2"); shift 2;;
      docker) shift 1;;
      run) shift 1;;
      -*) echo "unknown option: $1" >&2; exit 1;;
      *) THIS_ARGS+=("$1"); shift 1;;
    esac
  done
  for THIS_ARG in "${THIS_ARGS[@]}"; do
    if [ -n "$THIS_ARG" ]; then
      THIS_IMAGE=("$THIS_ARG")
    fi
  done
}

# Divide the user input into variables
function parseInputFlags() {
  CONTAINER_COUNT=0
  DOCKER_RUN_COMMANDS=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      # Required inputs
      --cluster) CLUSTER_NAME="$2"; shift 2;;
      -t) TASK_NAME="$2"; shift 2;;
      --task) TASK_NAME="$2"; shift 2;;
      # Only one of the following inputs can be used (neither defaults to `--revision=latest`)
      -c) CONTAINER_COUNT=$(($CONTAINER_COUNT + 1)); DOCKER_RUN_COMMANDS+=("$2"); shift 2;;
      --container) CONTAINER_COUNT=$(($CONTAINER_COUNT + 1)); DOCKER_RUN_COMMANDS+=("$2"); shift 2;;
      --revision) REVISION=("$2"); shift 2;;
      # Optional inputs
      -h) HELP_WANTED=true; shift 1;;
      --help) HELP_WANTED=true; shift 1;;
      -k) USE_EXISTING_KEY_PAIR=true; EXISTING_KEY_PAIR="$2"; shift 2;;
      --key-pair) USE_EXISTING_KEY_PAIR=true; EXISTING_KEY_PAIR="$2"; shift 2;;
      -o) OVERWRITE_ECR=true; shift 1;;
      --overwrite-ecr) OVERWRITE_ECR=true; shift 1;;
      -r) AWS_REGION="$2"; shift 2;;
      --region) AWS_REGION="$2"; shift 2;;
      # Optional inputs yet to be implemented
      -s) NO_OUTPUT=true; shift 1;;
      --skip-output) NO_OUTPUT=true; shift 1;;
      -*) echo "unknown option: $1" >&2; exit 1;;
      *) ARGS+="$1 "; shift 1;;
    esac
  done
}

# Push a local Docker image to ECR then reference the new ECR URI in the container definitions
function pushToEcr() {
  THIS_IMAGE_ECR="$ECR_REPOSITORY_URI":"$THIS_IMAGE_TAG"
  docker tag "$THIS_IMAGE" "$THIS_IMAGE_ECR"
  docker push "$THIS_IMAGE_ECR" >> /dev/null
  CONTAINER_DEFINITIONS[$IMAGE_INDEX,image]="$THIS_IMAGE_ECR"
}

# Register a new task definition with ECS
function registerTaskDefinition() {
  validateDockerImages
  createTaskDefinitionJson
  aws ecs register-task-definition --cli-input-json "$TASK_DEFINITION" --region "$AWS_REGION" >> /dev/null
  echo "STEPS_COMPLETED[register-task-definition]=true" | sudo tee --append "$PROGRESS_FILE" >> /dev/null
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
    exitDueToInvalidLaunchType
  fi
}

function showHelp() {
	if [ "$HELP_WANTED" == "true" ]; then
    echo -e ""
    echo -e "Usage: ./launchEcsTask.sh --cluster <CLUSTER_NAME> --task <TASK_NAME> [OPTIONS]"
    echo -e ""
    echo -e "Run a task on AWS ECS using the familiar syntax of Docker run commands"
    echo -e ""
    echo -e "Options:"
    echo -e "      --cluster <string>                   Name of the ECS cluster you want to run your task on. If it does not exist, it"
    echo -e "                                             will be created ${COLOR_GREEN}(required)${COLOR_NONE}"
    echo -e "  -c, --container \"<docker_run_command>\"   Run command for a new container in ECS. Multiple container flags can be"
    echo -e "                                             provided. Cannot be used along with the revision flag. A shortcut exists for"
    echo -e "                                             referencing images from ECR. By prepending 'ecr/' to your image name, the"
    echo -e "                                             'ecr' will expand at runtime to the full ECR URI. For more information on"
    echo -e "                                             usage, run 'docker run --help'"
    echo -e "  -h, --help                               Shows this block of text. Specifying the help flag will abort creation of AWS"
    echo -e "                                             resources"
    echo -e "  -o, --overwrite-ecr                      By default, this script will not allow you to overwrite ECR Docker images. If"
    echo -e "                                             you are running a local image, it must be pushed to ECR before it can be"
    echo -e "                                             run. Therefore, if you want to use a local image and that image exists in"
    echo -e "                                             ECR, you must add this flag to show you intended to overwrite the ECR image"
    echo -e "  -r, --region <string>                    AWS region where you want your ECS task to run. Defaults to 'us-east-2'"
    echo -e "      --revision <number>                  Version number of an existing ECS task. By omitting the revision flag, it is"
    echo -e "                                             assumed you want to run the latest version of the task. Cannot be used along"
    echo -e "                                             with the container flag"
    echo -e "  -s, --skip-output                        Suppress all output including errors"
    echo -e "  -t, --task <string>                      Name of the task you want to run. If it does not exist, it will be created"
    echo -e "                                             ${COLOR_GREEN}(required)${COLOR_NONE}"
    echo -e ""
    echo -e "Examples:"
    echo -e "$ ./launchEcsTask.sh --cluster sample --task important-thing --skip-output"
    echo -e "    * Running the latest revision of an existing task"
    echo -e "    * Command will give zero output"
    echo -e ""
    echo -e "$ ./launchEcsTask.sh --cluster cluster --task task --revision 7 --region us-east-1"
    echo -e "    * Running a specific revision of an existing task in the Northern Virginia AWS region"
    echo -e ""
    echo -e "$ ./launchEcsTask.sh --cluster project-name --task selenium \\"
    echo -e "    --container \"docker run -p 4444:4444 --name selenium-hub selenium/hub:3.14.0-gallium\""
    echo -e "    * Running a new task with one container"
    echo -e ""
    echo -e "$ ./launchEcsTask.sh --cluster dev --task whole-application -c \"docker run --name front -p 443:443 ecr/web\" \\"
    echo -e "    -c \"docker run --name middle -p 8081:8081 ecr/services\" -c \"docker run --name back -p 5432:5432 mongo:dev\" \\"
    echo -e "    --overwrite-ecr"
    echo -e "    * Running a new task with three containers"
    echo -e "    * Two containers use existing images in ECR"
    echo -e "    * If 'mongo:dev' exists in ECR, it will be overwritten"
    echo -e ""
    echo -e "Having trouble?"
    echo -e "  Please send any questions or issues to jdiederiks@psi-it.com"
    echo -e ""
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
  loginToEcr
  IMAGE_INDEX=0
  while [ $IMAGE_INDEX -lt $CONTAINER_COUNT ]; do
    validateDockerImage
    IMAGE_INDEX=$((IMAGE_INDEX + 1))
  done
  echo "STEPS_COMPLETED[validate-docker-images]=true" | sudo tee --append "$PROGRESS_FILE" >> /dev/null
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
    echo -e "${COLOR_RED}"
    echo "ERROR: The image ""$THIS_IMAGE"" could not be found in ECR. Here are a few possible remedies:"
    echo -e "${COLOR_WHITE}    * This script defaults to the AWS region 'us-east-2'. Is that the region intended? If not, was a region specified?"
    echo "    * Are the AWS credentials located at '~/.aws/credentials' the correct set of credentials?"
    echo "    * Does the image tag exist in ECR of the specified AWS region?"
    echo "    * Was a local image intended, but the ECR shortcut (i.e. ecr/imagename) used instead?"
    echo -e "${COLOR_NONE}"
    exit 2
  fi
}

# Validate that an image specified by the user exists on Docker Hub
function validateDockerHubImageExists() {
  SEARCH_RESULT_IMAGE_NAME_INDEX=5
  DOCKER_SEARCH_RESULTS=($(docker search "$THIS_IMAGE_NAME" --limit 1))
  if [ ! "${DOCKER_SEARCH_RESULTS[$SEARCH_RESULT_IMAGE_NAME_INDEX]}" == "$THIS_IMAGE_NAME" ]; then
    echo -e "${COLOR_RED}"
    echo "ERROR: The specified Docker image does not exist locally or on Docker Hub. Does the image need to be built first?"
    echo -e "${COLOR_NONE}"
    exit 2
  fi
}

# Validate a Docker image exists either locally or on Docker Hub
function validateLocalDockerOrDockerHubImage() {
  determineIfDockerImageExistsLocally
  if [ "$IMAGE_EXISTS_LOCALLY" == true ]; then
    ensureNoEcrConflict
    if [ "$REPO_EXISTS_IN_ECR" == false ]; then
      createEcrRepository
    else
      getEcrRepositoryUri
    fi
    pushToEcr
  else
    validateDockerHubImageExists
  fi
}

# Stall execution until the newly created EC2 instance is registered in the specified ECS cluster
function waitUntilInstanceRegisteredInCluster() {
  while : ; do
    CLUSTER_INSTANCES=$(aws ecs list-container-instances --cluster "$CLUSTER_NAME" --region "$AWS_REGION" | jq '.containerInstanceArns')
    CLUSTER_INSTANCE_COUNT=$(echo $CLUSTER_INSTANCES | jq '. | length')
    for (( CLUSTER_INSTANCE_INDEX=0; CLUSTER_INSTANCE_INDEX<CLUSTER_INSTANCE_COUNT; CLUSTER_INSTANCE_INDEX++ )); do
      CLUSTER_INSTANCE_ID=$(sed -e 's/^.*\///' -e 's/"$//' <<< $(echo "$CLUSTER_INSTANCES" | jq '.['"$CLUSTER_INSTANCE_INDEX"']'))
      CLUSTER_EC2_INSTANCE_ID=$(sed -e 's/^"//' -e 's/"$//' <<< $(aws ecs describe-container-instances --cluster "$CLUSTER_NAME" --container-instances "$CLUSTER_INSTANCE_ID" --region "$AWS_REGION" | jq '.containerInstances[0].ec2InstanceId'))
      if [ "$CLUSTER_EC2_INSTANCE_ID" == "$NEW_INSTANCE_ID" ]; then
        echo "STEPS_COMPLETED[wait-until-instance-in-cluster]=true" | sudo tee --append "$PROGRESS_FILE" >> /dev/null
        break 2
      fi
    done
    sleep 2
  done
}

# Create the configuration variable needed for the monitorProgress.sh script
function defineExpectedProgress() {
EXPECTED_PROGRESS=$(cat <<-EOF
[

EOF
)
  checkIfClusterActive
  if [ "$CLUSTER_ACTIVE" == false ]; then
EXPECTED_PROGRESS="$EXPECTED_PROGRESS"$(cat <<-EOF

  {
    "goal": "Creating ECS Cluster",
    "steps": [
      {
        "label": "Creating cluster",
        "variable": "create-cluster"
      }
    ]
  },

EOF
)
  fi
  if [ "$LAUNCH_TYPE" == "new-everything" ] || [ "$LAUNCH_TYPE" == "new-instance" ]; then
EXPECTED_PROGRESS="$EXPECTED_PROGRESS"$(cat <<-EOF

  {
    "goal": "Creating and Registering New EC2 Instance",
    "steps": [
      {
        "label": "Finding the smallest suitable T3 instance type",
        "variable": "determine-instance-type"
      },
      {
        "label": "Creating unique instance name",
        "variable": "create-instance-name"
      },
      {
        "label": "Creating specifications for ports to be opened",
        "variable": "create-port-spec"
      },
      {
        "label": "Launching new EC2 instance",
        "variable": "launch-ec2-instance"
      },
      {
        "label": "Collecting information about the new instance",
        "variable": "collect-new-instance-info"
      },
      {
        "label": "Waiting until the new instance registers with the cluster",
        "variable": "wait-until-instance-in-cluster"
      }
    ]
  },

EOF
)
  fi
  if [ "$LAUNCH_TYPE" == "new-everything" ] || [ "$LAUNCH_TYPE" == "new-task-definition" ]; then
EXPECTED_PROGRESS="$EXPECTED_PROGRESS"$(cat <<-EOF

  {
    "goal": "Registering New Task Definition",
    "steps": [
      {
        "label": "Validating Docker images provided are valid",
        "variable": "validate-docker-images"
      },
      {
        "label": "Creating task definition JSON structure",
        "variable": "create-task-json"
      },
      {
        "label": "Registering task definition",
        "variable": "register-task-definition"
      }
    ]
  },

EOF
)
  fi
EXPECTED_PROGRESS="$EXPECTED_PROGRESS"$(cat <<-EOF

  {
    "goal": "Launching ECS Task",
    "steps": [
      {
        "label": "Launching task",
        "variable": "launch-task"
      }
    ]
  },
  {
    "goal": "Editing Security Rules",
    "steps": [
      {
        "label": "Finding the security group of the container instance",
        "variable": "find-security-group"
      },
      {
        "label": "Revoking all port permissions",
        "variable": "revoke-port-permissions"
      },
      {
        "label": "Authorizing necessary port permissions",
        "variable": "authorize-port-permissions"
      }
    ]
  }
]
EOF
)
}

declareConstants
handleInput "$@"
determineLaunchType
# startMonitoringProgress
createClusterIfDoesNotExist
if [ "$LAUNCH_TYPE" == "new-everything" ]; then
  createAndRegisterNewInstance
  registerTaskDefinition
elif [ "$LAUNCH_TYPE" == "new-instance" ]; then
  createAndRegisterNewInstance
elif [ "$LAUNCH_TYPE" == "new-task-definition" ]; then
  registerTaskDefinition
elif [ "$LAUNCH_TYPE" == "existing-resources" ]; then
  :
else
  exitDueToInvalidLaunchType
fi
launchTask
editSecurityRulesForContainerPorts
# stopMonitoringProgress
