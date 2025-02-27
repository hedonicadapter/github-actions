#!/bin/bash
set -e

#  NOTE: Positional parameters (man måste träffa rätt med ordningen när man kallar på scriptet)
# getopts eller något som enablear flags hade vart att föredra
ACTION=$1
DIR=$2
ENVIRONMENT=$3
SUFFIX=$4
OPA_BLAST_RADIUS=$5

#  NOTE: env variabler som sätts av Makefilen för TFs backend
RG_LOCATION_SHORT=${RG_LOCATION_SHORT:-we}
RG_LOCATION_LONG=${RG_LOCATION_LONG:-westeurope}

BACKEND_KEY="${BACKEND_KEY:-${ENVIRONMENT}.terraform.tfstate}"
# oflexibla namn, kan vara problem med krav för naming conventions
#  TODO: följer vi CAF/WAF naming conventions?
BACKEND_RG="${BACKEND_RG:-rg-${ENVIRONMENT}-${RG_LOCATION_SHORT}-${SUFFIX}}"
BACKEND_KV="${BACKEND_KV:-kv-${ENVIRONMENT}-${RG_LOCATION_SHORT}-${SUFFIX}}"
 #  INFO: sops är en encryption/decryption grej
BACKEND_KV_KEY="${BACKEND_KV_KEY:-sops}"
BACKEND_NAME="${BACKEND_NAME:-sa${ENVIRONMENT}${RG_LOCATION_SHORT}${SUFFIX}}"
CONTAINER_NAME="${CONTAINER_NAME:-tfstate-${DIR}}"

#  TODO: kolla hur helm är kopplat till allt
export HELM_CACHE_HOME=/tmp/${DIR}/.helm_cache

if [ -z "${OPA_BLAST_RADIUS}" ]; then
  OPA_BLAST_RADIUS=50
fi

#  NOTE: Alla make targets förutom "teardown" kör "setup"-targeten innan en av dessa, och "setup" kör init()

#  NOTE: 
prepare () {
  #  WARNING: az login med ett konto i rätt tenant och sub är prerequisite
  AZ_ACCOUNT_TYPE="$(az account show --query user.type --output tsv)"
  if [[ "${AZ_ACCOUNT_TYPE}" = "servicePrincipal" ]]; then
    export AZURE_SERVICE_PRINCIPAL_APP_ID="$(az account show --query user.name --output tsv)"
    export AZURE_SERVICE_PRINCIPAL_OBJECT_ID="$(az ad sp show --id $AZURE_SERVICE_PRINCIPAL_APP_ID --query id --output tsv)"
  fi

  #  TODO: varför exportar vi?
  export AZURE_SUBSCRIPTION_ID=$(az account show --output tsv --query id)
  export AZURE_TENANT_ID=$(az account show --output tsv --query tenantId)
  export AZURE_RESOURCE_GROUP_NAME="${BACKEND_RG}"
  export AZURE_RESOURCE_GROUP_LOCATION="${RG_LOCATION_LONG}"
  export AZURE_STORAGE_ACCOUNT_NAME="${BACKEND_NAME}"
  export AZURE_STORAGE_ACCOUNT_CONTAINER="${CONTAINER_NAME}"
  export AZURE_KEYVAULT_NAME="${BACKEND_KV}"
  export AZURE_KEYVAULT_KEY_NAME="${BACKEND_KV_KEY}"
  export AZURE_RESOURCE_LOCKS="${AZURE_RESOURCE_LOCKS:-true}"
  export AZURE_EXCLUDE_CLI_CREDENTIAL="${AZURE_EXCLUDE_CLI_CREDENTIAL:-false}"
  export AZURE_EXCLUDE_ENVIRONMENT_CREDENTIAL="${AZURE_EXCLUDE_ENVIRONMENT_CREDENTIAL:-true}"
  export AZURE_EXCLUDE_MSI_CREDENTIAL="${AZURE_EXCLUDE_MSI_CREDENTIAL:-true}"
  #  INFO: tf-prepare, go-binary
  #  NOTE: azure är det enda kommandot som finns
  #  NOTE: skapar resurser kanske för tfstate? kunde gjorts med terraform?
  tf-prepare azure
}

#  INFO: terraform init och sedan terraform workspace select ${ENVIRONMENT}
#  körs av make setup
init () {
  terraform init -input=false -backend-config="key=${BACKEND_KEY}" -backend-config="resource_group_name=${BACKEND_RG}" -backend-config="storage_account_name=${BACKEND_NAME}" -backend-config="container_name=${CONTAINER_NAME}" -backend-config="snapshot=true"
  select_workspace
}

#  INFO: 
# kör init(), sedan terraform plan med OPA-policies och encryptar outputen med SOPS
#
# använder flera variabel-källor:
#  - variables/${ENVIRONMENT}.tfvars
#  - variables/common.tfvars
#  - ../global.tfvars
plan () {
  rm -f .terraform/plans/${ENVIRONMENT}
  init
  mkdir -p .terraform/plans
  terraform plan -input=false -var-file="variables/${ENVIRONMENT}.tfvars" -var-file="variables/common.tfvars" -var-file="../global.tfvars" -out=".terraform/plans/${ENVIRONMENT}"
  terraform show -json .terraform/plans/${ENVIRONMENT} > .terraform/plans/${ENVIRONMENT}.json 

  #  INFO: /opt/opa-policies är skapat av docker/Dockerfile:87
  cat /opt/opa-policies/data.json | jq ".blast_radius = ${OPA_BLAST_RADIUS}" > /tmp/opa-data.json

  #  INFO: validerar opa policies
  opa test /opt/opa-policies -v

  OPA_AUTHZ=$(opa eval --format pretty --data /tmp/opa-data.json --data /opt/opa-policies/terraform.rego --input .terraform/plans/${ENVIRONMENT}.json "data.terraform.analysis.authz")
  OPA_SCORE=$(opa eval --format pretty --data /tmp/opa-data.json --data /opt/opa-policies/terraform.rego --input .terraform/plans/${ENVIRONMENT}.json "data.terraform.analysis.score")
  if [[ "${OPA_AUTHZ}" == "true" ]]; then
    echo "INFO: OPA Authorization: true (score: ${OPA_SCORE} / blast_radius: ${OPA_BLAST_RADIUS})"
    rm -rf .terraform/plans/${ENVIRONMENT}.json
  else
    echo "ERROR: OPA Authorization: false (score: ${OPA_SCORE} / blast_radius: ${OPA_BLAST_RADIUS})"
    rm -rf .terraform/plans/${ENVIRONMENT}.json
    rm -rf .terraform/plans/${ENVIRONMENT}
    exit 1
  fi

  #  TODO: key vault skapad av azure.go?
  SOPS_KEY_ID="$(az keyvault key show --name ${BACKEND_KV_KEY} --vault-name ${BACKEND_KV} --query key.kid --output tsv)"
  sops --encrypt --azure-kv ${SOPS_KEY_ID} .terraform/plans/${ENVIRONMENT} > .terraform/plans/${ENVIRONMENT}.enc
  rm -rf .terraform/plans/${ENVIRONMENT}
}

#  INFO: 
# kör init(), decryptar en terraform plan output, och kör apply på den
apply () {
  init
  SOPS_KEY_ID="$(az keyvault key show --name ${BACKEND_KV_KEY} --vault-name ${BACKEND_KV} --query key.kid --output tsv)"
  sops --decrypt --azure-kv ${SOPS_KEY_ID} .terraform/plans/${ENVIRONMENT}.enc > .terraform/plans/${ENVIRONMENT}
  rm -rf .terraform/plans/${ENVIRONMENT}.enc
  set +e
  terraform apply ".terraform/plans/${ENVIRONMENT}"
  EXIT_CODE=$? #  INFO: capture exit code of last command
  set -e
  rm -rf .terraform/plans/${ENVIRONMENT}
  exit $EXIT_CODE
}

#  INFO: 
# kör init(), promptar för confirmation och sedan terraform destroy
destroy () {
  init
  echo "-------"
  echo "You are about to run terraform destroy on ${DIR} in ${ENVIRONMENT}"
  echo "-------"

  echo -n "Please confirm by writing \"${DIR}/${ENVIRONMENT}\": "
  read VERIFICATION_INPUT

  if [[ "${VERIFICATION_INPUT}" == "${DIR}/${ENVIRONMENT}" ]]; then
    terraform destroy -var-file="variables/${ENVIRONMENT}.tfvars" -var-file="variables/common.tfvars" -var-file="../global.tfvars"
  else
    echo "Wrong input detected (${VERIFICATION_INPUT}). Exiting..."
    exit 1
  fi
}

#  INFO: for deleting stuff in terraform state using regex
state_remove () {
  init
  TF_STATE_OBJECTS=$(terraform state list)

  echo "-------"
  echo "You are about to run terraform state rm on ${DIR} in ${ENVIRONMENT}"
  echo "-------"

  echo -n "Please confirm by writing \"${DIR}/${ENVIRONMENT}\": "
  read VERIFICATION_INPUT

  if [[ "${VERIFICATION_INPUT}" == "${DIR}/${ENVIRONMENT}" ]]; then
    #  WARNING: unclear prompt
    #  INFO: is asking for regex to match state objects to delete
    echo -n "Please enter what to grep regex arguments (default: grep -E \".*\"): "
    read GREP_ARGUMENT

    #  INFO: set default value to regex matching any string
    GREP_ARGUMENT=${GREP_ARGUMENT:-.*} 

    TF_STATE_TO_REMOVE=$(echo "${TF_STATE_OBJECTS}" | grep -E "${GREP_ARGUMENT}")
    TF_STATE_TO_REMOVE_COUNT=$(echo "${TF_STATE_TO_REMOVE}" | wc -l)

    echo "You are about to remove the following objects from the terraform state: "
    echo ""
    echo "-------"
    echo "${TF_STATE_TO_REMOVE}"
    echo "-------"
    echo ""

    echo -n "Please confirm the number of objects that will be removed (${TF_STATE_TO_REMOVE_COUNT}): "
    read VERIFICATION_INPUT_COUNT
    if [[ ${VERIFICATION_INPUT_COUNT} -eq ${TF_STATE_TO_REMOVE_COUNT} ]]; then
      for TF_STATE_OBJECT in ${TF_STATE_TO_REMOVE}; do
        terraform state rm ${TF_STATE_OBJECT}
      done
    else
      echo "Wrong input detected (${VERIFICATION_INPUT_COUNT}). Exiting..."
      exit 1
    fi
  else
    echo "Wrong input detected (${VERIFICATION_INPUT}). Exiting..."
    exit 1
  fi
}

#  FIX: should format any tf file recursively
#  FIX: should be run before plan and apply maybe
validate () {
  init
  terraform validate
  terraform fmt .
  terraform fmt variables/
  tflint --config="/work/.tflint.d/.tflint.hcl" --var-file="variables/${ENVIRONMENT}.tfvars" --var-file="variables/common.tfvars" --var-file="../global.tfvars" .
  tfsec .
}

#  INFO: Select terraform environment based on $ENVIRONMENT
select_workspace() {
  #  INFO: Silent erroring för att kunna upserta en workspace
  #  set +e (disablear set -e) och stderr redir till /dev/null
  set +e
  terraform workspace select ${ENVIRONMENT} 2> /dev/null
  if [ $? -ne 0 ]; then
    terraform workspace new ${ENVIRONMENT}
    terraform workspace select ${ENVIRONMENT}
  fi
  set -e
}

cd /tmp/$DIR

case $ACTION in

  init )
    init
    ;;

  plan )
    plan
    ;;

  apply )
    apply
    ;;

  destroy )
    destroy
    ;;

  prepare )
    prepare
    ;;

  state-remove )
    state_remove
    ;;

  validate )
    validate
    ;;
esac
