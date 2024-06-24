#!/bin/bash

# The integration tests are designed to tests that Spark Jobs can be submitted and/or shell processes are
# working properly with restricted permission of the service account starting the process. For this reason,
# in the tests we spawn two pods:
#
# 1. Admin pod, that is used to create and delete service accounts
# 2. User pod, that is used to start and execute Spark Jobs
#
# The Admin pod is created once at the beginning of the tests and it is used to manage Spark service accounts
# throughtout the integration tests. On the other hand, the User pod(s) are created together with the creation
# of the Spark user (service accounts and secrets) at the beginning of each test, and they are destroyed at the
# end of the test.


NAMESPACE=tests

get_spark_version(){
  SPARK_VERSION=$(yq '(.version)' rockcraft.yaml)
  echo "$SPARK_VERSION"
}


spark_image(){
  echo "ghcr.io/canonical/test-charmed-spark:$(get_spark_version)"
}


validate_pi_value() {
  pi=$1

  if [ "${pi}" != "3.1" ]; then
      echo "ERROR: Computed Value of pi is $pi, Expected Value: 3.1. Aborting with exit code 1."
      exit 1
  fi
}

validate_metrics() {
  log=$1
  if [ $(grep -Ri "spark" $log | wc -l) -lt 2 ]; then
      exit 1
  fi
}

setup_user() {
  echo "setup_user() ${1} ${2}"

  USERNAME=$1
  NAMESPACE=$2

  kubectl -n $NAMESPACE exec testpod-admin -- env UU="$USERNAME" NN="$NAMESPACE" \
                /bin/bash -c 'spark-client.service-account-registry create --username $UU --namespace $NN'

  # Create the pod with the Spark service account
  yq ea ".spec.serviceAccountName = \"${USERNAME}\"" \
    ./tests/integration/resources/testpod.yaml | \
    kubectl -n tests apply -f -

  wait_for_pod testpod $NAMESPACE

  TEST_POD_TEMPLATE=$(cat tests/integration/resources/podTemplate.yaml)

  kubectl -n $NAMESPACE exec testpod -- /bin/bash -c 'cp -r /opt/spark/python /var/lib/spark/'
  kubectl -n $NAMESPACE exec testpod -- env PTEMPLATE="$TEST_POD_TEMPLATE" /bin/bash -c 'echo "$PTEMPLATE" > /etc/spark/conf/podTemplate.yaml'
}

setup_user_context() {
  setup_user spark $NAMESPACE
}

cleanup_user() {
  EXIT_CODE=$1
  USERNAME=$2
  NAMESPACE=$3

  kubectl -n $NAMESPACE delete pod testpod --wait=true

  kubectl -n $NAMESPACE exec testpod-admin -- env UU="$USERNAME" NN="$NAMESPACE" \
                  /bin/bash -c 'spark-client.service-account-registry delete --username $UU --namespace $NN'  

  OUTPUT=$(kubectl -n $NAMESPACE exec testpod-admin -- /bin/bash -c 'spark-client.service-account-registry list')

  EXISTS=$(echo -e "$OUTPUT" | grep "$NAMESPACE:$USERNAME" | wc -l)

  if [ "${EXISTS}" -ne "0" ]; then
      exit 2
  fi

  if [ "${EXIT_CODE}" -ne "0" ]; then
      exit 1
  fi
}

cleanup_user_success() {
  echo "cleanup_user_success()......"
  cleanup_user 0 spark $NAMESPACE
}

cleanup_user_failure() {
  echo "cleanup_user_failure()......"
  cleanup_user 1 spark $NAMESPACE
}

wait_for_pod() {

  POD=$1
  NAMESPACE=$2

  SLEEP_TIME=1
  for i in {1..5}
  do
    pod_status=$(kubectl -n ${NAMESPACE} get pod ${POD} | awk '{ print $3 }' | tail -n 1)
    echo $pod_status
    if [[ "${pod_status}" == "Running" ]]
    then
        echo "testpod is Running now!"
        break
    elif [[ "${i}" -le "5" ]]
    then
        echo "Waiting for the pod to come online..."
        sleep $SLEEP_TIME
    else
        echo "testpod did not come up. Test Failed!"
        exit 3
    fi
    SLEEP_TIME=$(expr $SLEEP_TIME \* 2);
  done
}

setup_admin_test_pod() {
  kubectl create ns $NAMESPACE

  echo "Creating admin test-pod"
  pwd
  ls
  ls ./tests/
  ls ./tests/integration/
  ls ./tests/integration/resources/
  echo "END of debug"
  cat ./tests/integration/resources/testpod.yaml
  # Create a pod with admin service account
  yq ea '.spec.containers[0].env[0].name = "KUBECONFIG" | .spec.containers[0].env[0].value = "/var/lib/spark/.kube/config" | .metadata.name = "testpod-admin"' \
    ./tests/integration/resources/testpod.yaml | \
    kubectl -n tests apply -f -

  wait_for_pod testpod-admin $NAMESPACE

  MY_KUBE_CONFIG=$(cat /home/${USER}/.kube/config)

  kubectl -n $NAMESPACE exec testpod-admin -- /bin/bash -c 'mkdir -p ~/.kube'
  kubectl -n $NAMESPACE exec testpod-admin -- env KCONFIG="$MY_KUBE_CONFIG" /bin/bash -c 'echo "$KCONFIG" > ~/.kube/config'
}

teardown_test_pod() {
  kubectl logs testpod-admin -n $NAMESPACE 
  kubectl logs testpod -n $NAMESPACE 
  kubectl logs -l spark-version=3.4.2 -n $NAMESPACE 
  kubectl -n $NAMESPACE delete pod testpod
  kubectl -n $NAMESPACE delete pod testpod-admin

  kubectl delete namespace $NAMESPACE
}

get_s3_access_key(){
  # Prints out S3 Access Key by reading it from K8s secret
  kubectl get secret -n minio-operator microk8s-user-1 -o jsonpath='{.data.CONSOLE_ACCESS_KEY}' | base64 -d
}

get_s3_secret_key(){
  # Prints out S3 Secret Key by reading it from K8s secret
  kubectl get secret -n minio-operator microk8s-user-1 -o jsonpath='{.data.CONSOLE_SECRET_KEY}' | base64 -d
}

get_s3_endpoint(){
  # Prints out the endpoint S3 bucket is exposed on.
  kubectl get service minio -n minio-operator -o jsonpath='{.spec.clusterIP}'
}

create_s3_bucket(){
  # Creates a S3 bucket with the given name.
  S3_ENDPOINT=$(get_s3_endpoint)
  BUCKET_NAME=$1
  aws s3api create-bucket --bucket "$BUCKET_NAME"
  echo "Created S3 bucket ${BUCKET_NAME}"
}

delete_s3_bucket(){
  # Deletes a S3 bucket with the given name.
  S3_ENDPOINT=$(get_s3_endpoint)
  BUCKET_NAME=$1
  aws s3 rb "s3://$BUCKET_NAME" --force
  echo "Deleted S3 bucket ${BUCKET_NAME}"
}

copy_file_to_s3_bucket(){
  # Copies a file from local to S3 bucket.
  # The bucket name and the path to file that is to be uploaded is to be provided as arguments
  BUCKET_NAME=$1
  FILE_PATH=$2

  # If file path is '/foo/bar/file.ext', the basename is 'file.ext'
  BASE_NAME=$(basename "$FILE_PATH")
  S3_ENDPOINT=$(get_s3_endpoint)

  # Copy the file to S3 bucket
  aws s3 cp $FILE_PATH s3://"$BUCKET_NAME"/"$BASE_NAME"
  echo "Copied file ${FILE_PATH} to S3 bucket ${BUCKET_NAME}"
}


run_test_gpu_example_in_pod(){
  # Test Iceberg integration in Charmed Spark Rock

  # First create S3 bucket named 'spark'
  create_s3_bucket spark

  # Copy 'test-iceberg.py' script to 'spark' bucket
  copy_file_to_s3_bucket spark ./tests/integration/resources/test-gpu-simple.py

  NAMESPACE="tests"
  USERNAME="spark"
#  IMAGE="test-image"
  # Number of driver pods that exist in the namespace already.
  PREVIOUS_DRIVER_PODS_COUNT=$(kubectl get pods --sort-by=.metadata.creationTimestamp -n ${NAMESPACE} | grep driver | wc -l)

  # Submit the job from inside 'testpod'
  kubectl -n $NAMESPACE exec testpod -- \
      env \
        UU="$USERNAME" \
        NN="$NAMESPACE" \
        ACCESS_KEY="$(get_s3_access_key)" \
        SECRET_KEY="$(get_s3_secret_key)" \
        S3_ENDPOINT="$(get_s3_endpoint)" \
      /bin/bash -c '\
        spark-client.spark-submit \
        --username $UU \
        --namespace $NN \
        --conf spark.executor.instances=1 \
        --conf spark.executor.resource.gpu.amount=1 \
        --conf spark.executor.memory=4G \
        --conf spark.executor.cores=1 \
        --conf spark.task.cpus=1 \
        --conf spark.task.resource.gpu.amount=1 \
        --conf spark.rapids.memory.pinnedPool.size=1G \
        --conf spark.executor.memoryOverhead=1G \
        --conf spark.sql.files.maxPartitionBytes=512m \
        --conf spark.sql.shuffle.partitions=10 \
        --conf spark.plugins=com.nvidia.spark.SQLPlugin \
        --conf spark.executor.resource.gpu.discoveryScript=/opt/getGpusResources.sh \
        --conf spark.executor.resource.gpu.vendor=nvidia.com \
        --conf spark.kubernetes.container.image=ghcr.io/welpaolo/charmed-spark@sha256:d8273bd904bb5f74234bc0756d520115b5668e2ac4f2b65a677bfb1c27e882da \
        --driver-memory 2G \
        --conf spark.kubernetes.executor.podTemplateFile=gpu_executor_template.yaml \
        --conf spark.kubernetes.executor.deleteOnTermination=false \
          s3a://spark/test-gpu-simple.py'

  # Delete 'spark' bucket
  delete_s3_bucket spark

  # Number of driver pods after the job is completed.
  DRIVER_PODS_COUNT=$(kubectl get pods --sort-by=.metadata.creationTimestamp -n ${NAMESPACE} | grep driver | wc -l)

  # If the number of driver pods is same as before, job has not been run at all!
  if [[ "${PREVIOUS_DRIVER_PODS_COUNT}" == "${DRIVER_PODS_COUNT}" ]]
  then
    echo "ERROR: Sample job has not run!"
    exit 1
  fi

  # Find the ID of the driver pod that ran the job.
  # tail -n 1       => Filter out the last line
  # cut -d' ' -f1   => Split by spaces and pick the first part
  DRIVER_POD_ID=$(kubectl get pods --sort-by=.metadata.creationTimestamp -n ${NAMESPACE} | grep driver | tail -n 1 | cut -d' ' -f1)

  # Filter out the output log line
  OUTPUT_LOG_LINE=$(kubectl logs ${DRIVER_POD_ID} -n ${NAMESPACE} | grep 'GpuFilter' )

  # Fetch out the number of rows inserted
  # rev             => Reverse the string
  # cut -d' ' -f1   => Split by spaces and pick the first part
  # rev             => Reverse the string back
  NUM_ROWS=$(wc -l  $OUTPUT_LOG_LINE)

  if [ "${NUM_ROWS}" == 0 ]; then
      echo "ERROR: No GPU enable workflow found. Aborting with exit code 1."
      exit 1
  fi

}

test_test_gpu_example_in_pod() {
  run_test_gpu_example_in_pod $NAMESPACE spark
}

cleanup_user_failure_in_pod() {
  teardown_test_pod
  cleanup_user_failure
}

set +x

echo -e "##################################"
echo -e "SETUP TEST POD"
echo -e "##################################"

setup_admin_test_pod

echo -e "##################################"
echo -e "RUN EXAMPLE THAT USES ICEBERG LIBRARIES"
echo -e "##################################"

(setup_user_context && test_test_gpu_example_in_pod && cleanup_user_success) || cleanup_user_failure_in_pod

echo -e "##################################"
echo -e "TEARDOWN TEST POD"
echo -e "##################################"

teardown_test_pod

echo -e "##################################"
echo -e "END OF THE TEST"
echo -e "##################################"

set -x