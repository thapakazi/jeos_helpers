self_init(){
    # if some how, we forgot to set these vars, failsafe with defautls
    export USERDATA_TMPDIR=${USERDATA_TMPDIR:-/tmp/userdata}
} && self_init
# Name: this function's sole purpose is to pull ssh key for user
# Usage:
#   $ su - user -c ' utils_pull_private_key '
#   like: export PRIVATE_KEY_PATH_IN_S3=mybucketname/path/to/my/private_key && su - user -c 'utils_pull_private_key'
#      if your key is in other bucket and other path
utils_pull_private_key (){
    source $USERDATA_TMPDIR/.secrets
    SSH_DIR="$HOME/.ssh" && mkdir -p $SSH_DIR
    PRIVATE_KEY_IN_LOCAL="${SSH_DIR}/id_rsa"

    REGION="${REGION:-my-region-1}"
    PRIVATE_KEY_PATH_IN_S3="${PRIVATE_KEY_PATH_IN_S3:-my_s3bucket/autoscaling/id_rsa}"

    # asuming awscli is already in JEOS
    aws s3 cp s3://${PRIVATE_KEY_PATH_IN_S3} ${PRIVATE_KEY_IN_LOCAL} --region ${REGION}
    chmod 400 ${PRIVATE_KEY_IN_LOCAL}

    # if you reached this far
    echo "#SECURITY :: PLEASE CLEAN UP THE FILE $PRIVATE_KEY_IN_LOCAL"
    echo "#SECURITY :: rm -rf $PRIVATE_KEY_IN_LOCAL"
}


utils_install_dependent_galaxy_roles(){
    # we need to install these roles 
    DEPENDENT_ROLES=( williamyeh.prometheus franklinkim.newrelic )
    ansible-galaxy install "${DEPENDENT_ROLES[@]}"
}

# override 
bootstrap(){
    BOOTSTRAP_BRANCH="${BOOTSTRAP_BRANCH:-master}"
    BOOTSTRAP_PLAYBOOK="${BOOTSTRAP_PLAYBOOK:-devel.yml}"
    VAULT_PASS_FILE="$HOME/.vault_pass" # this is supposed to be present in JeOS

    BOOTSTRAP_GITHUB_URL="github.com:cloudfactory/scale"
    BOOTSTRAP_TMP_PULL_DIR="$USERDATA_TMPDIR/scale"

    [ -z "$SKIP_BOOTSTRAP" ] \
	&& ansible-pull -C $BOOTSTRAP_BRANCH \
			--full -d ${BOOTSTRAP_TMP_PULL_DIR} \
			-i 'localhost' -U git@${BOOTSTRAP_GITHUB_URL}.git \
			--accept-host-key $BOOTSTRAP_PLAYBOOK -vvvv \
			--vault-password-file=${VAULT_PASS_FILE} # ||  curl http://169.254.169.254/latest/user-data | bash -xv
}

deployment(){

    # get the keys first
    su - deploy -c 'utils_pull_private_key '

    #safely assuming, bootstrap layers above successfully completed.
    for file in  /etc/profile.d/cloudfactory_utils*; do source $file; done

    # get the tag: project and run play accordingly
    DEPLOYMENT_TMP_PULL_DIR="$USERDATA_TMPDIR/ops-automata" && rm -rf $DEPLOYMENT_TMP_PULL_DIR
    DEPLOYMENT_GITHUB_URL="github.com:cloudfactory/ops-automata"
    PROJECT_TO_DEPLOY=$(cloudfactory_get_value_for_tag project) #clientplatform

    DEPLOYMENT_PLAYBOOK="${PROJECT_TO_DEPLOY}.yml"
    EC2SPIN_ROLE=${EC2SPIN_ROLE:-worker}
    SKIP_TAGS=${DEPLOMENT_SKIP_TAGS:-"ec2spin,ansicap,runit_unicorn"}

    DEBUG_FLAG=${DEBUG_FLAG:-'-vvvv'}
    ansible-pull -C $PROJECT_TO_DEPLOY --full -d ${DEPLOYMENT_TMP_PULL_DIR} \
		 -U git@${DEPLOYMENT_GITHUB_URL}.git -i spinner.ini \
		 --accept-host-key $DEPLOYMENT_PLAYBOOK  \
		 --skip-tags=${SKIP_TAGS} -e EC2SPIN_ROLE=${EC2SPIN_ROLE} ${DEBUG_FLAG}
}

post_cleanup(){
    echo "Post cleanup actions: removing the ${PRIVATE_KEY_IN_LOCAL}"
    # improve it later, i know hardcoding sucks
    rm -rf ~/.ssh/id_rsa ~deploy/.ssh/id_rsa
    
    # rm /var/lib/cloud/instance/{sem/config_scripts_user,boot-finished}
}


utils_export_home(){
    [ "$(/usr/bin/id -u)" = "0" ] && export HOME=/root || export HOME="/home/$(whoami)"
}


# this is a temporary helper script to finalise autoscaling scripts
utils_ansicap_with_sidekiq_supervise(){
    BOOTSTRAP_BRANCH="${BOOTSTRAP_BRANCH:-master}"
    BOOTSTRAP_PLAYBOOK="${BOOTSTRAP_PLAYBOOK:-code-deploy.yml}"

    BOOTSTRAP_GITHUB_URL="github.com:cloudfactory/scale"
    BOOTSTRAP_TMP_PULL_DIR="$USERDATA_TMPDIR/scale"

    # we might need it somewhere while doing bundle install
    utils_pull_private_key
    [ -z "$SKIP_ANSICAP" ] \
	&& ansible-pull -C $BOOTSTRAP_BRANCH \
			--full -d ${BOOTSTRAP_TMP_PULL_DIR} \
			-i 'localhost' -U git@${BOOTSTRAP_GITHUB_URL}.git \
			--accept-host-key $BOOTSTRAP_PLAYBOOK -vvvv
}

utils_notify_slack(){
    # check if slacktee is present, else get it
    SLACKTEE_BIN='/usr/local/bin/slacktee'
    SLACKTEE_CONFIG='/etc/slacktee.conf'
    SLACKTEE_GITHUB='https://github.com/course-hero/slacktee'
    SLACKTEE_CLONE_LOCAL=$USERDATA_TMPDIR/slacktee
    SLACKTEE_CONFIG_IN_S3="${SLACKTEE_CONFIG_IN_S3:-my_s3bucket/autoscaling/.slacktee}"
    # check if config's present, else configure
    [ -f $SLACKTEE_BIN ] \
	|| { git clone $SLACKTEE_GITHUB $SLACKTEE_CLONE_LOCAL \
		 && cp $SLACKTEE_CLONE_LOCAL/slacktee.sh $SLACKTEE_BIN \
		 && chmod +x $SLACKTEE_BIN
	}

    [ -f $SLACKTEE_CONFIG ] \
	|| { \
	     aws s3 cp s3://$SLACKTEE_CONFIG_IN_S3 $SLACKTEE_CONFIG \
		 && echo "$(date) first time: just pulled the configs, sending test msg from $(hostnamectl --static)"| $SLACKTEE_BIN
	}
    # send msg to #dump
    echo "$@"|$SLACKTEE_BIN -c "#dump"  # explicitly hardcoding the room name

}

utils_notify_and_post_cleanup(){
    post_cleanup
    utils_notify_slack "From: $(hostnamectl --static): $(date): **** $(tail -n 20 $USERDATA_TMPDIR/pull.log)"
}
