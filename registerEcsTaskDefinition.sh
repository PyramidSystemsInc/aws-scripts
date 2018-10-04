#! /bin/bash

function handleInput() {
  CPU_COEF=1024
  MEMORY_COEF=995
  TASK_NAME="$1"
  buildContainersArray "$2"
  AWS_REGION="$3"
  parseAllDockerRunCommands "${CONTAINERS[@]}"
}

function buildContainersArray() {
  CONTAINERS=()
  RAW_CONTAINER_DATA=($1)
  CONTAINER=""
  for TERM in "${RAW_CONTAINER_DATA[@]}"; do
    if [ "$TERM" == "docker" ]; then
      CONTAINERS+=("$CONTAINER")
      CONTAINER="$TERM"
    else
      CONTAINER="$CONTAINER"" $TERM"
    fi
  done
  CONTAINERS+=("$CONTAINER")
  unset 'CONTAINERS[0]'
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

function createTaskDefinitionJson() {
	TASK_DEFINITION=$(cat <<-EOF
		{
		  "family": "$TASK_NAME",
		  "containerDefinitions": [
	EOF
  )
  CONTAINER_COUNT="${#CONTAINERS[@]}"
  for (( CONTAINER_INDEX=0; CONTAINER_INDEX<CONTAINER_COUNT; CONTAINER_INDEX++ )); do
    THIS_NAME="${NAME[$CONTAINER_INDEX]}"
    THIS_IMAGE="${IMAGE[$CONTAINER_INDEX]}"
    THIS_CPU="${CPU[$CONTAINER_INDEX]}"
    THIS_MEMORY="${MEMORY[$CONTAINER_INDEX]}"
    if [ $CONTAINER_INDEX -eq 0 ]; then
			TASK_DEFINITION="$TASK_DEFINITION"$(cat <<-EOF

				    {
				      "name": "$THIS_NAME",
				      "image": "$THIS_IMAGE",
				      "cpu": $THIS_CPU,
				      "memory": $THIS_MEMORY,
				      "essential": true

			EOF
			)
    else
			TASK_DEFINITION="$TASK_DEFINITION"$(cat <<-EOF

				    },
				    {
				      "name": "$THIS_NAME",
				      "image": "$THIS_IMAGE",
				      "cpu": $THIS_CPU,
				      "memory": $THIS_MEMORY,
				      "essential": true

			EOF
			)
    fi
  done
	TASK_DEFINITION="$TASK_DEFINITION"$(cat <<-EOF

		    }
		  ]
		}
	EOF
  )
  echo $TASK_DEFINITION | jq '.'
}

function registerTaskDefinition() {
  aws ecs register-task-definition --cli-input-json "$TASK_DEFINITION" --region "$AWS_REGION" >> /dev/null
}

function validateDockerImages() {
  IMAGE_COUNT=${#IMAGE[@]}
  for (( IMAGE_INDEX=0; IMAGE_INDEX<IMAGE_COUNT; IMAGE_INDEX++ )); do
    validateDockerImage
  done
}

function validateDockerImage() {
  THIS_IMAGE="${IMAGE[$IMAGE_INDEX]}"
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
    exitIfEcrImageTagComboAlreadyExists
    if [ "$REPO_EXISTS_IN_ECR" == false ]; then
      $(aws ecr get-login --no-include-email --region "$AWS_REGION" >> /dev/null)
      ECR_REPOSITORY_URI=$(sed -e 's/^"//' -e 's/"$//' <<< $(aws ecr create-repository --repository-name "$THIS_IMAGE_NAME" --region "$AWS_REGION" | jq '.repository.repositoryUri'))
    else
      ECR_REPOSITORY_URI=$(sed -e 's/^"//' -e 's/"$//' <<< $(aws ecr describe-repositories --repository "$THIS_IMAGE_NAME" --region "$AWS_REGION" | jq '.repositories[0].repositoryUri'))
    fi
    THIS_IMAGE_ECR="$ECR_REPOSITORY_URI":"$THIS_IMAGE_TAG"
    docker tag "$THIS_IMAGE" "$THIS_IMAGE_ECR"
    docker push "$THIS_IMAGE_ECR" >> /dev/null
    IMAGE[$IMAGE_INDEX]="$THIS_IMAGE_ECR"
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
            echo "ERROR: The image ""$THIS_IMAGE"" already exists in ECR. The task creation was abandoned because creating it would require overwriting the image in ECR. If you wish to use the image in ecr, run the image ecr/""$THIS_IMAGE"". If you want to use your local image, retag it using 'docker tag ""$THIS_IMAGE"" ""$THIS_IMAGE_NAME"":<new-tag-here>'"
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
            IMAGE[$IMAGE_INDEX]="$THIS_ECR_REPO_URI":"$THIS_IMAGE_TAG"
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

handleInput "$@"
validateDockerImages
createTaskDefinitionJson
registerTaskDefinition
