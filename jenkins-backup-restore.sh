#!/bin/bash
set +x
script_usage() {
    cat << EOF
Usage:
     help                    Displays this help
     location                [REQUIRED] Azure location (e.g. westeurope)
     environment             [REQUIRED] Platform environment (e.g oc, devoc)
     operation               [REQUIRED] Operation to perform (eg. backup, reset)
     restorefile             [OPTIONAL] It is mandatory when you are selecting restore operation)
     username                [OPTIONAL] It is mandatory when you are selecting restore operation)
     token                   [OPTIONAL] It is mandatory when you are selecting restore operation)
EOF
}

parse_arguments() {
  for ARGUMENT in "$@"
  do
    KEY=$(echo $ARGUMENT | cut -f1 -d=)
    VALUE=$(echo $ARGUMENT | cut -f2 -d=)
    case "$KEY" in
            help)
                script_usage
                exit 0
                ;;
            location)
                location=${VALUE} 
                ;;
            environment)
                environment=${VALUE} 
                ;;
            operation)
                operation=${VALUE} 
                ;;
            restorefile)
                restorefile=${VALUE} 
                ;;
            username)
                username=${VALUE} 
                ;;
            token)
                token=${VALUE} 
                ;;
            *)
            echo "Invalid arguments supplied. Supported arguments location,environment,operation,restorefile"
            exit $?
            ;;
    esac
  done

  if [ ! "$location" -o ! "$environment" ]; then
    script_usage
    rc=1
    exit ${rc}
  fi
  
  if [ "$operation" == "Restore" -a ! "$restorefile" -a ! "$username" -a ! "$token" ]; then
   echo -e 'While selecting restore operation, it is mandatory to select the restorefile, username and token\n';
   exit 1
  fi

  if [ "$environment" == "oc" ]; then
    namespace='default'
    host='https://jenkins-shell-ai.rds-beagile.com'
  elif [ "$environment" == "devoc" ]; then
    namespace='platform'
    host='https://jenkins-shell-ai.theagilehub.net'
  else
    echo -e 'Incorrect value for environment supplied'
    script_usage
    exit 1
  fi
  
}

# Declare the required variables
declare_variables() {   
  CUR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  export keybase_dir=${keybase_dir:-"/keybase/team/shellai_devops"}
  secrets_file=${keybase_dir}/jenkins/$location/$environment/jenkins-backup.conf
  export access_key=$(grep "access_key" $secrets_file | cut -d ' ' -f 2)
  export storage_acc_name=$(grep "storage_account_name" $secrets_file | cut -d ' ' -f 2)
  export container_name=$(grep "container_name" $secrets_file | cut -d ' ' -f 2)
  DATA_FILE="/keybase/team/shellai_devops/principals/data.yaml"
  echo "login to az subscription ${location}-${environment}"
  client_id=$(cat ${DATA_FILE} | shyaml get-value "${location}.${environment}.client_id" "")
  echo "client_id" $client_id
  client_certificate_pem_path=$(cat ${DATA_FILE} | shyaml get-value "${location}.${environment}.client_certificate_path_pem" "")
  subscription_id=$(cat ${DATA_FILE} | shyaml get-value "${location}.${environment}.subscription_id" "")
  tenant_id=$(cat ${DATA_FILE} | shyaml get-value "${location}.${environment}.tenant_id" "")
  backup_file="$environment-jenkins-backup-`date '+%Y_%m_%d_%H_%M_%S'`.tar.gz"
}

install_prereqs() {
    pip install pyyaml --disable-pip-version-check
    pip install shyaml 
}

backup_jenkins(){
  kubectl config use-context "shellai-${location}-${environment}" 
  jenkins_pod=$(kubectl get po -n $namespace | grep jenkins | awk '{print $1}')
  kubectl exec $jenkins_pod -n $namespace -- /bin/bash -c "cd /var/tmp ; \
          tar -cvzf $environment-jenkins-backup.tar.gz /var/jenkins_home/ > /dev/null;"
  kubectl cp $namespace/$jenkins_pod:/var/tmp /var/tmp
  echo "Uploading $backup_file to $storage_acc_name/$container_name"
  az storage blob upload --account-name $storage_acc_name --account-key $access_key --container-name $container_name --file /var/tmp/$environment*.gz --name $backup_file
  kubectl exec $jenkins_pod -n $namespace -- /bin/bash -c "cd /var/tmp ; \
          rm -f *.gz ;"  
}

restore_jenkins() {
  echo "downloading $restorefile from Azure blob storage"
  az storage blob download --account-name $storage_acc_name --account-key $access_key --container-name $container_name --name "$restorefile" --file /tmp/$restorefile
  
  kubectl config use-context "shellai-${location}-${environment}"
  jenkins_pod=$(kubectl get pods -n $namespace | grep jenkins | awk '{print $1}')
  echo "$jenkins_pod"
  echo "copying file to $jenkins_pod "
  kubectl cp /tmp/$restorefile $jenkins_pod:/ -n $namespace
  
  echo "taking backup of existing home dir and extracting the $restorefile "
  kubectl exec "$jenkins_pod" -n $namespace -- /bin/bash -c "cd / ; ls -lrt ; \
              cd /var ; cp -rf jenkins_home jenkins_home_`date '+%Y_%m_%d_%H_%M_%S'` ; cd / ; tar -xzvf "$restorefile" ;"
  
  echo "Sleeping 20 seconds"
  sleep 20
  
  echo "Restarting Jenkins $environment"
  curl -s -k -X POST --user $username:$token $host/restart
  
  code=503
  until [[ $code -eq 200 ]]
  do
    code=`curl -s -k -X GET -o /dev/null --connect-timeout 6 --max-time 7 --user $username:$token  -w "%{http_code}\\n" $host`
    echo "Jenkins $environment is still restarting"
    sleep 1
  done  
    
  echo "Jenkins $environment is started successfully"
  echo "Removing the tar.gz file from $jenkins_pod"
  kubectl exec $jenkins_pod -n $namespace -- /bin/bash -c "cd / ; rm -f *.gz ;"
  
  echo "Removing the backup of existing home dir from $jenkins_pod"
  kubectl exec $jenkins_pod -n $namespace -- /bin/bash -c "cd /var ; rm -rf jenkins_home_* ;"
  
  echo "Jenkins $environment restoration is completed successfully"
}

main() {
    source "$(dirname "${BASH_SOURCE[0]}")/source.sh"
    trap script_trap_err ERR
    trap script_trap_exit EXIT
    parse_arguments "$@"
    install_prereqs
    declare_variables
    az login --service-principal -u $client_id -p $client_certificate_pem_path --tenant $tenant_id
    az account set --subscription $subscription_id
    if [ "$operation" == "Backup" ]; then
        backup_jenkins
    fi
    if [ "$operation" == "Restore" ]; then
        restore_jenkins
    fi
}

# Make it rain
main "$@"
