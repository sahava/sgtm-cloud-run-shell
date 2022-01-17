#!/bin/bash

IMG_URL="gcr.io/cloud-tagging-10302018/gtm-cloud-image:stable"
WISH_TO_CONTINUE="Do you wish to continue? (y/N): "
WELCOME_TEXT=\
"Please input the following information to set up your tagging server. For more
information about the configuration, input '?'. To use the recommended setting
or your current setting, leave blank."
SERVICE_PREFIX_HELP=\
"  Provide a name for the Cloud Run service you wish to use for this deployment.
  The name will be suffixed with -prod and -debug for production and debug services,
  respectively."
CONTAINER_CONFIG_HELP=\
"  The Container Config string links your Cloud Run service to your GTM Server container.
  You can find the Container Config string in the GTM UI by going to Container Settings."
POLICY_SCRIPT_HELP=\
"  The policy script URL is an optional URL that specifies the policies that
  govern custom template permissions. A value of '' means that there is no
  policy script URL. Enter 'None' to clear the URL.
  For more information, see: https://developers.google.com/tag-manager/templates/policies"
MIN_INSTANCES_HELP=\
"  The minimum number of instances running the container at any given time.
  Set to 0 to have Cloud Run scale in automatically based on demand."
MAX_INSTANCES_HELP=\
"  The maximum number of instances Cloud Run will scale up to, if necessary.
  Note that with traffic spikes it's possible for the maximum number of instances
  to be exceeded temporarily."
MEMORY_LIMIT_HELP=\
"  Enter the memory limit for each instance. If you specify higher than 4Gi, you will
  need to allocate a minimum of 2 CPUs, and if you want to allocate 4 CPUs, you will
  need to set a memory limit of at least 2Gi (CPU limits will be prompted from you next)."
CPU_LIMIT_HELP=\
"  Enter the number of CPUs to use for each instance. Options are 1, 2, and 4. If you set
  the memory limit to higher than 4Gi, you must allocate at least 2 CPUs. If you want to
  allocate 4 CPUs, the memory limit must be at least 2Gi."
SAME_SETTINGS=\
"  Your configured settings are the same as the current deployment."
CONFIG_ENV_PATH=".spec.template.spec.containers[0].env[]"
CONFIG_MEMORY_PATH=".spec.template.spec.containers[0].resources.limits.memory"
CONFIG_CPU_PATH=".spec.template.spec.containers[0].resources.limits.cpu"
CONFIG_MAX_SCALE_PATH='.spec.template.metadata.annotations."autoscaling.knative.dev/maxScale"'
CONFIG_MIN_SCALE_PATH='.spec.template.metadata.annotations."autoscaling.knative.dev/minScale"'
REGION_PATH='.metadata.labels."cloud.googleapis.com/location"'
CPU_LIMIT_REGEX="^[124]$"
MEMORY_LIMIT_REGEX="^[1-9]+[0-9]*[MG][Bi]$"
POSITIVE_INT_REGEX="^[1-9]+[0-9]*$"
POSITIVE_INT_OR_ZERO_REGEX="^([1-9]+[0-9]*|0)$"
trap "exit" INT
set -e

generate_suggested() {
  echo "$([[ -z "$1" || "$1" == 'null' ]] && echo "$2" || echo "Current: $1")"
}

get_config() {
  echo "$(gcloud run services describe ${service_prefix}-prod --format=json)"
}

prompt_service_prefix() {
  while [[ -z "${service_prefix}" || "${service_prefix}" == '?' ]]; do
    recommended="gtm-server"
    suggested="$(\
      generate_suggested "${cur_service_prefix}" "Recommended: ${recommended}")"
    printf "Service Name (${suggested}): "
    read service_prefix

    if [[ "${service_prefix}" == '?' ]]; then
      echo "${SERVICE_PREFIX_HELP}"
    elif [[ -z "${service_prefix}" ]]; then
      if [[ ! -z "${cur_service_prefix}" ]]; then
        service_prefix="${cur_service_prefix}"
      else
        service_prefix="${recommended}"
      fi
    fi
  done
}

prompt_existing_service() {
  while true; do
    printf "Fetch existing service configuration (you will be prompted for the Region next)? (y/N): "
    read confirmation
    confirmation="$(echo "${confirmation}" | tr '[:upper:]' '[:lower:]')"
    if [[ -z "${confirmation}" || "${confirmation}" == 'n' ]]; then
      break
    fi
    if [[ "${confirmation}" == "y" ]]; then
      config=$(get_config)
      if [[ ! -z ${config} ]]; then
        cur_container_config="$(echo "${config}" | jq -r ${CONFIG_ENV_PATH}' | select(.name | contains("CONTAINER_CONFIG")).value')"
        cur_policy_script_url="$(echo "${config}" | jq -r ${CONFIG_ENV_PATH}' | select(.name | contains("POLICY_SCRIPT_URL")).value')"
        cur_memory_limit="$(echo "${config}" | jq -r ${CONFIG_MEMORY_PATH})"
        cur_cpu_limit="$(echo "${config}" | jq -r ${CONFIG_CPU_PATH})"
        cur_min_instances="$(echo "${config}" | jq -r ${CONFIG_MIN_SCALE_PATH})"
        cur_max_instances="$(echo "${config}" | jq -r ${CONFIG_MAX_SCALE_PATH})"
        cur_region="$(echo "${config}" | jq -r ${REGION_PATH})"
        if [[ "${cur_min_instances}" == 'null' ]]; then
          cur_min_instances=0
        fi
        break
      else
        service_prefix=''
        prompt_service_prefix
      fi
    fi
  done
}

prompt_container_config() {
  while [[ -z "${container_config}" || "${container_config}" == '?' ]]; do
    suggested="$(generate_suggested "${cur_container_config}" "Required")"
    printf "Container Config (${suggested}): "
    read container_config
    if [[ -z "${container_config}" ]]; then
      container_config="${cur_container_config}"
    fi

    if [[ "${container_config}" == '?' ]]; then
      echo "${CONTAINER_CONFIG_HELP}"
    elif [[ -z "${container_config}" || "${container_config}" == 'null' ]]; then
      echo "  Container config cannot be empty."
    fi
  done
}

prompt_policy_script_url() {
  while true; do
    suggested="$(generate_suggested "${cur_policy_script_url}" "Optional")"
    printf "Policy Script URL (${suggested}): "
    read policy_script_url

    if [[ "${policy_script_url}" =~ ^[Nn][Oo][Nn][Ee]$ ]]; then
      policy_script_url="''"
    elif [[ "${policy_script_url}" == '""' ]]; then
      policy_script_url="''"
    fi

    if [[ "$policy_script_url" == '?' ]]; then
      echo "${POLICY_SCRIPT_HELP}"
    elif [[ -z "${policy_script_url}" ]]; then
      if [[ ! -z "${cur_policy_script_url}" && "${cur_policy_script_url}" != 'null' ]]; then
        policy_script_url="${cur_policy_script_url}"
      else
        policy_script_url="''"
      fi
      break
    else
      break
    fi
  done
}

prompt_memory() {
  while [[ ! "${memory_limit}" =~ ${MEMORY_LIMIT_REGEX} || \
    "${memory_limit}" == '?' || -z "${memory_limit}" ]]; do
    recommended="512Mi"
    suggested="$(\
      generate_suggested "${cur_memory_limit}" "Recommended: ${recommended}")"
    printf "Memory Per Instance (${suggested}): "
    read memory_limit
    if [[ "${memory_limit}" == '?' ]]; then
      echo "${MEMORY_LIMIT_HELP}"
    elif [[ -z "${memory_limit}" ]]; then
      if [[ ! -z "${cur_memory_limit}" ]]; then
        memory_limit="${cur_memory_limit}"
      else
        memory_limit="${recommended}"
      fi
    elif [[ ! "${memory_limit}" =~ ${MEMORY_LIMIT_REGEX} ]]; then
      echo " Enter a valid memory unit, e.g. 512Mi"
    fi
  done
}

prompt_cpu_limit() {
  while [[ ! "${cpu_limit}" =~ ${CPU_LIMIT_REGEX} || \
    "${cpu_limit}" == '?' || "${cpu_limit}" -le 0 ]]; do
    recommended="1"
    suggested="$(\
      generate_suggested "${cur_cpu_limit}" "Recommended: ${recommended}")"
    printf "CPU Allocation Per Instance (${suggested}): "
    read cpu_limit
    if [[ "${cpu_limit}" == '?' ]]; then
      echo "${CPU_LIMIT_HELP}"
    elif [[ -z "${cpu_limit}" ]]; then
      if [[ ! -z "${cur_cpu_limit}" && "${cur_cpu_limit}" != 'null' ]]; then
        cpu_limit="${cur_cpu_limit}"
      else
        cpu_limit="${recommended}"
      fi
    elif [[ ! "${cpu_limit}" =~ ${CPU_LIMIT_REGEX} ]]; then
      echo "  You can assign 1, 2, or 4 virtual CPUs per instance"
    fi
  done
}

prompt_min_instances() {
  while [[ ! "${min_instances}" =~ ${POSITIVE_INT_OR_ZERO_REGEX} || \
    "${min_instances}" == '?' ]]; do
    recommended="3"
    suggested="$(\
      generate_suggested "${cur_min_instances}" "Recommended: ${recommended}")"
    printf "Minimum Number of Servers (${suggested}): "
    read min_instances
    if [[ "${min_instances}" == '?' ]]; then
      echo "${MIN_INSTANCES_HELP}"
    elif [[ -z "${min_instances}" ]]; then
      if [[ ! -z "${cur_min_instances}" && "${cur_min_instances}" != 'null' ]]; then
        min_instances="${cur_min_instances}"
      else
        min_instances="${recommended}"
      fi
    elif [[ ! "${min_instances}" =~ ${POSITIVE_INT_OR_ZERO_REGEX} ]]; then
      echo "  The input must be a positive integer or 0."
    fi
  done
}

prompt_max_instances() {
  while [[ ! "${max_instances}" =~ ${POSITIVE_INT_REGEX} || \
    "${max_instances}" == '?' || \
    "${min_instances}" -gt "${max_instances}" ]]; do
    recommended="6"
    suggested="$(\
      generate_suggested "${cur_max_instances}" "Recommended: ${recommended}")"
    printf "Maximum Number of Servers (${suggested}): "
    read max_instances
    if [[ "${max_instances}" == '?' ]]; then
      echo "${MAX_INSTANCES_HELP}"
    elif [[ -z "${max_instances}" ]]; then
      if [[ ! -z "${cur_max_instances}" && "${cur_max_instances}" != 'null' ]]; then
        max_instances="${cur_max_instances}"
      else
        max_instances="${recommended}"
      fi
    elif [[ ! "${max_instances}" =~ ${POSITIVE_INT_REGEX} ]]; then
      echo "  The input must be a positive integer."
    elif [[ "${min_instances}" -gt "${max_instances}" ]]; then
      echo "  The input must be equal or greater than the minimum number of servers."
    fi
  done
}

prompt_continue_default_no() {
  while true; do
    printf "$1"
    read confirmation
    confirmation="$(echo "${confirmation}" | tr '[:upper:]' '[:lower:]')"
    if [[ -z "${confirmation}" || "${confirmation}" == 'n' ]]; then
      exit 0
    fi
    if [[ "${confirmation}" == "y" ]]; then
      break
    fi
  done
}

deploy_production_server() {
  if [[ "${policy_script_url}" == "''" ]]; then
    policy_script_url=""
  fi
  echo "Deploying the production service to ${service_prefix}-prod, press any key to begin..."
  read -n 1 -s
  prod_url=$(gcloud run deploy ${service_prefix}-prod --image=${IMG_URL}\
    --cpu=${cpu_limit} --allow-unauthenticated --min-instances=${min_instances}\
    --max-instances=${max_instances} --memory=${memory_limit} --region=${cur_region}\
    --set-env-vars POLICY_SCRIPT_URL=${policy_script_url}\
    --set-env-vars CONTAINER_CONFIG=${container_config}\
    --set-env-vars PREVIEW_SERVER_URL=${debug_url} --format=json | jq -r '.status.url')
}

deploy_debug_server() {
  echo "Deploying the debug service to ${service_prefix}-debug, press any key to begin..."
  read -n 1 -s
  debug_url=$(gcloud run deploy ${service_prefix}-debug --image=${IMG_URL}\
    --cpu=1 --allow-unauthenticated --min-instances=1 --region=${cur_region}\
    --max-instances=1 --memory=256Mi --set-env-vars RUN_AS_PREVIEW_SERVER=true\
    --set-env-vars CONTAINER_CONFIG=${container_config} --format=json | jq -r '.status.url')
  deploy_production_server
}

echo "${WELCOME_TEXT}"
prompt_service_prefix
prompt_existing_service
prompt_container_config
prompt_policy_script_url
prompt_memory
prompt_cpu_limit
prompt_min_instances
prompt_max_instances

echo ""
echo "Your configured settings are"
echo "Service Name: ${service_prefix}"
echo "Container Config: ${container_config}"
echo "Policy Script URL: ${policy_script_url}"
echo "Memory Per Instance: ${memory_limit}"
echo "CPU Allocation Per Instance: ${cpu_limit}"
echo "Minimum Number of Servers: ${min_instances}"
echo "Maximum Number of Servers: ${max_instances}"
if [[ ! -z ${cur_region} ]]; then
  echo "Region: ${cur_region}"
fi

prompt_continue_default_no "${WISH_TO_CONTINUE}"

if [[ "${container_config}" == "${cur_container_config}" &&
  "${policy_script_url}" == "${cur_policy_script_url}" &&
  "${memory_limit}" == "${cur_memory_limit}" &&
  "${cpu_limit}" == "${cur_cpu_limit}" &&
  "${min_instances}" == "${cur_min_instances}" &&
  "${max_instances}" == "${cur_max_instances}" ]]; then
  same_deployment_settings="true"
else
  same_deployment_settings="false"
fi

if [[ "${same_deployment_settings}" == "true" ]]; then
  echo ""
  echo "${SAME_SETTINGS}"
  prompt_continue_default_no "${WISH_TO_CONTINUE}"
fi

echo "As you wish."

deploy_debug_server

echo ""
echo "Your server deployment is complete."
echo ""
echo "Production server test:"
printf "${prod_url}/healthy"
echo ""
exit 0
