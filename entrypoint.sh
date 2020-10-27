#!/bin/bash
set -e
set -x

function main() {
  sanitize "${INPUT_ACCESS_KEY_ID}" "access_key_id"
  sanitize "${INPUT_SECRET_ACCESS_KEY}" "secret_access_key"
  sanitize "${INPUT_REGION}" "region"
  sanitize "${INPUT_ACCOUNT_ID}" "account_id"
  sanitize "${INPUT_REPO}" "repo"

  ACCOUNT_URL="$INPUT_ACCOUNT_ID.dkr.ecr.$INPUT_REGION.amazonaws.com"

  aws_configure
  assume_role
  login
  run_pre_build_script $INPUT_PREBUILD_SCRIPT
  docker_build $INPUT_TAGS $ACCOUNT_URL
  create_ecr_repo $INPUT_CREATE_REPO
  docker_push_to_ecr $INPUT_TAGS $ACCOUNT_URL
}

function sanitize() {
  if [ -z "${1}" ]; then
    >&2 echo "Unable to find the ${2}. Did you set with.${2}?"
    exit 1
  fi
}

function aws_configure() {
  export AWS_ACCESS_KEY_ID=$INPUT_ACCESS_KEY_ID
  export AWS_SECRET_ACCESS_KEY=$INPUT_SECRET_ACCESS_KEY
  export AWS_DEFAULT_REGION=$INPUT_REGION
}

function login() {
  echo "== START LOGIN"
  LOGIN_COMMAND=$(aws ecr get-login --no-include-email --region $AWS_DEFAULT_REGION)
  $LOGIN_COMMAND
  echo "== FINISHED LOGIN"
}

function assume_role() {
  if [ "${INPUT_ASSUME_ROLE}" != "" ]; then
    sanitize "${INPUT_ASSUME_ROLE}" "assume_role"
    echo "== START ASSUME ROLE"
    ROLE="arn:aws:iam::${INPUT_ACCOUNT_ID}:role/${INPUT_ASSUME_ROLE}"
    CREDENTIALS=$(aws sts assume-role --role-arn ${ROLE} --role-session-name ecrpush --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' --output text)
    read id key token <<< ${CREDENTIALS}
    export AWS_ACCESS_KEY_ID="${id}"
    export AWS_SECRET_ACCESS_KEY="${key}"
    export AWS_SESSION_TOKEN="${token}"
    echo "== FINISHED ASSUME ROLE"
  fi
}

function create_ecr_repo() {
  if [ "${1}" = true ]; then
    echo "== START CREATE REPO"
    aws ecr describe-repositories --region $AWS_DEFAULT_REGION --repository-names $INPUT_REPO > /dev/null 2>&1 || \
      aws ecr create-repository --region $AWS_DEFAULT_REGION --repository-name $INPUT_REPO
    echo "== FINISHED CREATE REPO"
  fi
}

function run_pre_build_script() {
  if [ ! -z "${1}" ]; then
    echo "== START PREBUILD SCRIPT"
    chmod a+x $1
    $1
    echo "== FINISHED PREBUILD SCRIPT"
  fi
}

function docker_build() {
  echo "== START DOCKERIZE"
  local TAG=$1
  local docker_tag_args=""
  local DOCKER_TAGS=$(echo "$TAG" | tr "," "\n")
  for tag in $DOCKER_TAGS; do
    docker_tag_args="$docker_tag_args -t $2/$INPUT_REPO:$tag"
  done
  
  ref_cache="$GITHUB_REF-build-cache"
  cache_tags=($ref-cache latest-build-cache)

  for tag in "${cache_tags[@]}"
  do
    unset error
    cache_repo="$2/$INPUT_REPO:$tag"
    docker pull $cache_repo || error=true

    if [ -z "$error" ]
    then
      export cache_tag=$tag
      break
    fi
  done
  
  cache_repo=$2/$INPUT_REPO:$cache_tag
  
  echo "Using cache repo: $cache_repo"
  
  echo "Copying cache dirs from the cache repo"
  mkdir -p /cache
  id=$(docker create $cache_repo)
  docker cp $id:/usr/local/cargo/registry /cache/registry
  docker cp $id:/usr/local/cargo/git /cache/git
  docker cp $id:/app/target /cache/target
  docker rm -v $id
  
  mkdir -p /cache/registry
  mkdir -p /cache/git
  mkdir -p /cache/target
  
  ls -l /cache

  docker build --cache-from $cache_repo --target cargo-builder $INPUT_EXTRA_BUILD_ARGS -f $INPUT_DOCKERFILE -t $cache_repo $INPUT_PATH
  docker build --cache-from $cache_repo $INPUT_EXTRA_BUILD_ARGS -f $INPUT_DOCKERFILE $docker_tag_args $INPUT_PATH
  echo "== FINISHED DOCKERIZE"
}

function docker_push_to_ecr() {
  echo "== START PUSH TO ECR"
  local TAG=$1
  local DOCKER_TAGS=$(echo "$TAG" | tr "," "\n")
  for tag in $DOCKER_TAGS; do
    docker push $2/$INPUT_REPO:latest-build-cache
    docker push $2/$INPUT_REPO:$tag
    echo ::set-output name=image::$2/$INPUT_REPO:$tag
  done
  echo "== FINISHED PUSH TO ECR"
}

main
