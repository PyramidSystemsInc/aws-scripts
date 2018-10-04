#! /bin/bash

declare -A AWS_T3_INSTANCE_SPEC0=(
  [name]='t3.nano'
  [cpu]=2048
  [memory]=497
)
declare -A AWS_T3_INSTANCE_SPEC1=(
  [name]='t3.micro'
  [cpu]=2048
  [memory]=995
)
declare -A AWS_T3_INSTANCE_SPEC2=(
  [name]='t3.small'
  [cpu]=2048
  [memory]=1990
)
declare -A AWS_T3_INSTANCE_SPEC3=(
  [name]='t3.medium'
  [cpu]=2048
  [memory]=3980
)
declare -A AWS_T3_INSTANCE_SPEC4=(
  [name]='t3.large'
  [cpu]=2048
  [memory]=7960
)
declare -A AWS_T3_INSTANCE_SPEC5=(
  [name]='t3.xlarge'
  [cpu]=4096
  [memory]=15920
)
declare -A AWS_T3_INSTANCE_SPEC6=(
  [name]='t3.2xlarge'
  [cpu]=8192
  [memory]=31840
)
declare -n AWS_T3_INSTANCE_SPEC
