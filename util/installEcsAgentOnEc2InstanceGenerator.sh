#! /bin/bash

function createUserDataScript() {
	cat <<- EOF > util/installEcsAgentOnEc2Instance.sh
		#! /bin/bash
		
		CLUSTER_NAME=$CLUSTER_NAME
		
		$USER_DATA_SCRIPT
	EOF
  chmod 755 util/installEcsAgentOnEc2Instance.sh
}

function declareVariables() {
  CLUSTER_NAME="$1"
  USER_DATA_SCRIPT=$(cat ./util/installEcsAgentOnEc2InstanceTemplate.sh)
}

function deleteUserDataScript() {
  sudo rm util/installEcsAgentOnEc2Instance 2> /dev/null
}

declareVariables "$@"
deleteUserDataScript
createUserDataScript
