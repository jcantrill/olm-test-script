#!/usr/bin/env bash
if [ "${DEBUG:-}" = "true" ]; then
	set -x
fi

TEST_NAMESPACE=${TEST_NAMESPACE:-olm-test}

# Get the manifests dir where the package and version dir are.
MANIFEST_DIR=${MANIFEST_DIR:-$(realpath deploy/manifests)}

# Version that your testing. folder where CRDs and CSV exist must match.
VERSION=${VERSION:-4.1}

# indent is used to indent the yaml created from manifest directory correctly
indent() {
  INDENT="      "
  sed "s/^/$INDENT/" | sed "s/^${INDENT}\($1\)/${INDENT:0:-2}- \1/"
}

# TODO: RIPPED from the upstream kube test shell library. Everyone will need
# this. What do we do? -- Thanks pmorie
readonly reset=$(tput sgr0)
readonly  bold=$(tput bold)
readonly black=$(tput setaf 0)
readonly   red=$(tput setaf 1)
readonly green=$(tput setaf 2)

test::object_assert() {
  local tries=$1
  local object=$2
  local request=$3
  local expected=$4
  local args=${5:-}

  for j in $(seq 1 ${tries}); do
    res=$(eval oc get ${args} ${object} -o jsonpath=\"${request}\")
    echo $res
    if [[ "${res}" =~ ^$expected$ ]]; then
      echo -n "${green}"
      echo "Successful get ${object} ${request}: ${res}"
      echo -n "${reset}"
      return 0
    fi
    echo "Waiting for Get ${object} ${request} ${args}: expected: ${expected}, got: ${res}"
    sleep $((${j}-1))
  done
  echo "${bold}${red}"
  echo "FAIL!"
  echo "Get ${object} ${request}"
  echo "  Expected: ${expected}"
  echo "  Got:      ${res}"
  echo "${reset}${red}"
  caller
  echo "${reset}"
  return 1
}

# Name of the configmap that we will create
CONFIGMAP_NAME=${CONFIGMAP_NAME:-openshift-olm-test}

CRD=$(sed '/^#!.*$/d' $MANIFEST_DIR/$VERSION/*crd.yaml | grep -v -- "---" | indent apiVersion)
CSV=$(sed '/^#!.*$/d' $MANIFEST_DIR/$VERSION/*version.yaml | grep -v -- "---" |  indent apiVersion)
PKG=$(sed '/^#!.*$/d' $MANIFEST_DIR/*package.yaml | indent packageName)

cat > /tmp/configmap.yaml <<EOF | sed 's/^  *$//'
kind: ConfigMap
apiVersion: v1
metadata:
  name: $CONFIGMAP_NAME
data:
  customResourceDefinitions: |-
$CRD
  clusterServiceVersions: |-
$CSV
  packages: |-
$PKG
EOF

CSV_CHANNEL=$(sed -nr 's,.*name: (.*),\1,p' $MANIFEST_DIR/*package.yaml)
CURRENT_CSV=$(sed -nr 's,.*currentCSV: (.*),\1,p' $MANIFEST_DIR/*package.yaml)
CSV_NAME=$(echo ${CURRENT_CSV} | cut -d. -f1)

oc create -n $TEST_NAMESPACE -f /tmp/configmap.yaml
oc create -n $TEST_NAMESPACE -f catalogsource.yaml
oc create -n $TEST_NAMESPACE -f operatorgroup.yaml
oc process -f subscription.yaml -p CSV_NAME=${CSV_NAME} -p STARTING_CSV=${CURRENT_CSV} -p CHANNEL=${CSV_CHANNEL} | oc create -n $TEST_NAMESPACE -f -

test::object_assert 100 subscriptions.operators.coreos.com/olm-testing "{.status.state}" AtLatestKnown "-n $TEST_NAMESPACE"
# Need to change to match the name of the CSV with version.
test::object_assert 50 clusterserviceversions.operators.coreos.com/${CURRENT_CSV} "{.status.phase}" Succeeded "-n $TEST_NAMESPACE"
