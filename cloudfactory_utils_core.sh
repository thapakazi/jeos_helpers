#!/bin/bash

# CloudFactory Bash Utilities: Core Utility Functions
# Version 30.10.2017
# i.e. 30th Oct 2017
# comment: moved from the bootstrap to jeos core

export EC2_SELF_METAS='/tmp/ec2-selfmeta'
export CUSTOM_TAGS_FILE='/tmp/.custom_tags'
export EC2_TAGS_FILE_ALL='/tmp/ec2-tags'
export INSTNANCE_COUNTER_VALUE='/tmp/.ec2_instance_counter'
    
cloudfactory_generate_ec2metadata(){         
    until ec2metadata > ${EC2_SELF_METAS}; do :; done
}

cloudfactory_get_meta(){
    meta_of="${1:-instance-id}"
    [ -f ${EC2_SELF_METAS} ] || cloudfactory_generate_ec2metadata
    [ -f ${EC2_SELF_METAS} ] && awk  -F': ' /${meta_of}/'{print $2}' ${EC2_SELF_METAS}
}

cloudfactory_get_instance_region(){
    curl -s http://169.254.169.254/latest/dynamic/instance-identity/document| awk -F\" '/region/{print $4}'
}

cloudfactory_populate_ec2_tags_raw(){
    # getting values if they are blank still
    [ -z "${REGION}" ] && REGION=${cloudfactory_get_instance_region:-us-west-1}
    [ -z "${INSTANCE_ID}" ] && INSTANCE_ID=$(cloudfactory_get_meta "instance-id")

    until aws ec2 describe-tags --filters \
              "Name=resource-id,Values=$INSTANCE_ID" \
              --region=$REGION --output=text > ${EC2_TAGS_FILE_ALL}; do :; done
    
}

# EXTENSION: write a usage function 
cloudfactory_get_value_for_tag(){
    [ -f "${EC2_TAGS_FILE_ALL}" ] || cloudfactory_populate_ec2_tags_raw
    tag=${1:-queues}
    grep -w "$tag" "${EC2_TAGS_FILE_ALL}" | awk '{print $NF}'
}

cloudfactory_tags_to_env(){
    export QUEUES=$(cloudfactory_get_value_for_tag  "queues")
    export ROLE=$(cloudfactory_get_value_for_tag "role")
    export ENV=$(cloudfactory_get_value_for_tag "env")
    export PROJECT=$(cloudfactory_get_value_for_tag "project")
    export NAME=$(cloudfactory_get_value_for_tag "Name")

    export INSTANCE_ID=$(cloudfactory_get_meta "instance-id")
    export LOCAL_IPV4=$(cloudfactory_get_meta "local-ipv4")
    export PUBLIC_HOSTNAME=$(cloudfactory_get_meta "public-hostname")
    export REGION=$(cloudfactory_get_instance_region)
    export ZONE=${REGION}.ec2.cloudfactory.internal

}

cloudfactory_tags_to_env_refresh(){
    rm ${EC2_TAGS_FILE_ALL} && cloudfactory_tags_to_env
}

utils_check_if_user_is_root(){
    if [ "$(id -u)" != "0" ]; then
        echo "This script must be run as root" 1>&2
        exit 1
    fi
}

utils_generate_random_number(){
    INSTANCE_RANDOM_RANGE=1000
    INSTANCE_RANDOM_BASE=100

    RANDOM_NUM=$(( ( RANDOM % INSTANCE_RANDOM_RANGE )  + INSTANCE_RANDOM_BASE ))
    echo ${RANDOM_NUM}
}

# this one uses the cache, if random number is alrady generated.
utils_get_random_number(){
    utils_check_if_user_is_root
    [ -f "${INSTNANCE_COUNTER_VALUE}" ] && cat ${INSTNANCE_COUNTER_VALUE} && return 0
    utils_generate_random_number | tee ${INSTNANCE_COUNTER_VALUE}
}

cloudfactory_get_all_tags_with_dynamic_Name(){
    # random instance index
    export NEXT_COUNT=$(utils_get_random_number)
    cloudfactory_tags_to_env
    export NAME=${ROLE}${NEXT_COUNT}${NAME_TAIL_STRING}
}

cloudfactory_save_to_etc_environment(){
    SYSMTEM_WIDE_ENVIRONMENT_FILE=/etc/environment
    SYSMTEM_WIDE_ENVIRONMENT_BACKUP_FILE="/etc/environment_$(date +%Y-%m-%d-%H-%M-%S)"

    echo "saving old envs to  $SYSMTEM_WIDE_ENVIRONMENT_BACKUP_FILE, if you need it later"
    mv ${SYSMTEM_WIDE_ENVIRONMENT_FILE} $SYSMTEM_WIDE_ENVIRONMENT_BACKUP_FILE && :> $SYSMTEM_WIDE_ENVIRONMENT_FILE
    echo "PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/games:/usr/local/games'" | tee ${SYSMTEM_WIDE_ENVIRONMENT_FILE}
    echo "LC_ALL=en_US.UTF-8" | tee -a ${SYSMTEM_WIDE_ENVIRONMENT_FILE}
    echo "LANG=en_US.UTF-8" | tee -a ${SYSMTEM_WIDE_ENVIRONMENT_FILE}

    echo "RAILS_ENV=$(cloudfactory_get_value_for_tag 'env')"| tee -a ${SYSMTEM_WIDE_ENVIRONMENT_FILE}
    echo "RACK_ENV=$(cloudfactory_get_value_for_tag 'env')"| tee -a ${SYSMTEM_WIDE_ENVIRONMENT_FILE}

    cloudfactory_tags_to_env
    echo "MACHINE_NAME=${NAME}"| tee -a ${SYSMTEM_WIDE_ENVIRONMENT_FILE}
    echo "ROLE=${ROLE}"| tee -a ${SYSMTEM_WIDE_ENVIRONMENT_FILE}
    echo "ENV=${ENV}"| tee -a ${SYSMTEM_WIDE_ENVIRONMENT_FILE}
    echo "PROJECT=${PROJECT}"| tee -a ${SYSMTEM_WIDE_ENVIRONMENT_FILE}
    [ -z "${QUEUES}" ] || echo "queues=${QUEUES}"| tee -a ${SYSMTEM_WIDE_ENVIRONMENT_FILE} 
}

utils_check_if_dynamic_tags_set_True(){
    cloudfactory_populate_ec2_tags_raw
    dynamic_tags=$(cloudfactory_get_value_for_tag "dynamic_tags")
    [ ! -z "$dynamic_tags" -a "$dynamic_tags" = "True" ] && return 0
    return 1
}

# this is where we export our basic (generic) env variables like HOME, PATH...
utils_export_basic_env(){
    [ "$(/usr/bin/id -u)" = "0" ] && export HOME=/root || export HOME="/home/$(whoami)"
    # please add more
}
