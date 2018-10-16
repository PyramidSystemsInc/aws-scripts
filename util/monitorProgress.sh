#! /bin/bash

function handleInput() {
  PROGRESS_FILE="$1"
  EXPECTED_PROGRESS=$2
  GOAL_COUNT=$(echo "$EXPECTED_PROGRESS" | jq '. | length')
  GOAL_INDEX=0
}

function monitorNewGoal() {
  THIS_GOAL=$(echo "$EXPECTED_PROGRESS" | jq '.['"$GOAL_INDEX"']')
  GOAL_TITLE=$(sed -e 's/^"//' -e 's/"$//' <<< $(echo "$THIS_GOAL" | jq '.goal'))
  STEP_COUNT=$(echo "$THIS_GOAL" | jq '.steps | length')
  STEPS=()
  for (( STEP_INDEX=0; STEP_INDEX<STEP_COUNT; STEP_INDEX++ )); do
    STEPS+=("$(sed -e 's/^"//' -e 's/"$//' <<< $(echo "$THIS_GOAL" | jq '.steps['"$STEP_INDEX"']'))")
  done
  echo -e ""
  ELLIPSIS=""
  for (( LINE_INDEX=0; LINE_INDEX<STEP_COUNT; LINE_INDEX++ )) do
    echo -e ""
  done
  while : ; do
    STEPS_COMPLETED=()
    . "$PROGRESS_FILE"
    ELLIPSIS+="."
    LINE_COUNT=$(($STEP_COUNT + 1))
    echo -en "\e[${LINE_COUNT}A"
    # CHECK HERE IF ALL STEPS IN THIS GOAL ARE COMPLETED
    ALL_STEPS_COMPLETED=true
    ALL_STEPS_SUCCESSFUL=true
    for (( STEP_INDEX=0; STEP_INDEX<STEP_COUNT; STEP_INDEX++ )); do
      THIS_STEP=$(sed -e 's/^"//' -e 's/"$//' <<< $(echo "$THIS_GOAL" | jq '.steps['"$STEP_INDEX"'].variable'))
      if [ "${STEPS_COMPLETED["$THIS_STEP"]}" != "true" ]; then
        ALL_STEPS_SUCCESSFUL=false
      fi
      if [ -z "${STEPS_COMPLETED["$THIS_STEP"]}" ]; then
        ALL_STEPS_COMPLETED=false
      fi
    done
    if [ "$ALL_STEPS_COMPLETED" == "true" ]; then
      if [ "$ALL_STEPS_SUCCESSFUL" == "true" ]; then
        echo -e "${COLOR_GREEN_BOLD}[ ${CHECK_MARK} DONE ]${COLOR_WHITE_BOLD} ($((GOAL_INDEX + 1))/$GOAL_COUNT) $GOAL_TITLE          "
      else
        echo -e "${COLOR_RED_BOLD}[ SKIPPED ]${COLOR_WHITE_BOLD} ($((GOAL_INDEX + 1))/$GOAL_COUNT) $GOAL_TITLE           "
      fi
    else
      if [ ${#ELLIPSIS} -gt 3 ]; then
        echo -e "${COLOR_BLUE_BOLD}[ IN PROGRESS ]${COLOR_WHITE_BOLD} ($((GOAL_INDEX + 1))/$GOAL_COUNT) $GOAL_TITLE   "
        ELLIPSIS=""
      else
        echo -e "${COLOR_BLUE_BOLD}[ IN PROGRESS ]${COLOR_WHITE_BOLD} ($((GOAL_INDEX + 1))/$GOAL_COUNT) $GOAL_TITLE$ELLIPSIS"
      fi
    fi
    for STEP in "${STEPS[@]}"; do
      STEP_LABEL=$(sed -e 's/^"//' -e 's/"$//' <<< $(echo "$STEP" | jq '.label'))
      STEP_VARIABLE=$(sed -e 's/^"//' -e 's/"$//' <<< $(echo "$STEP" | jq '.variable'))
      echo -e "    ${COLOR_NONE}- [$([ -n "${STEPS_COMPLETED[$STEP_VARIABLE]}" ] && "${STEPS_COMPLETED[$STEP_VARIABLE]}" == "true" && echo "X" || echo " ")] "$STEP_LABEL""
    done
    sleep 0.75
    if [ "$ALL_STEPS_COMPLETED" == "true" ]; then
      break
    fi
  done
  ((GOAL_INDEX++))
  echo -e ""
}

# Define all colors used for output
function defineColorPalette() {
  COLOR_RED_BOLD='\033[1;91m'
  COLOR_GREEN_BOLD='\033[1;32m'
  COLOR_BLUE_BOLD='\033[1;34m'
  COLOR_WHITE_BOLD='\033[1;97m'
  COLOR_NONE='\033[0m'
}

# Define special characters
function defineSpecialCharacters() {
  CHECK_MARK='\xE2\x9C\x94'
}

function defineConstants() {
  defineColorPalette
  defineSpecialCharacters
}

echo -e ""
defineConstants
handleInput "$@"
while [ "$GOAL_INDEX" -lt "$GOAL_COUNT" ]; do
  monitorNewGoal
done
