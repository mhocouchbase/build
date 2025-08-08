#!/bin/bash -ex
#
#    run by jenkins sync_gateway jobs for version 1.3.0 and newer:
#
#    with required paramters:
#
#          distro    version    bld_num    edition    REPO_SHA
#
#    e.g.: centos    0.0.0      0000       community    REPO_SHA
#          macosx    1.1.0      1234       enterprise   REPO_SHA
#
#    and optional parameters:
#
#        TEST_OPTIONS       `-race 4 -cpu`
#        GO_REL             1.5.3 (Currently supports 1.4.1, 1.5.2, 1.5.3)
#
#    This script supports building branches 1.3.0 and newer that uses repo manifest.
#    It will purely perform these 2 tasks:
#        - build the executable
#        - package the final binary installer
#
#    ErrorCode:
#        11 = Incorrect input parameters
#        22 = Unsupported DISTRO
#        33 = Unsupported OS
#        44 = Unsupported GO version
#        55 = Build sync_gateway failed
#        66 = Unit test failed
#

function usage {
    echo "Incorrect parameters..."
    echo -e "\nUsage:  ${0}   branch_name  distro  version  bld_num  edition  commit_sha  [ GO_REL ] \n\n"
}

function install_dependencies {
    #Get latest cbdep
    curl -L ${CBDEP_URL} -o cbdep
    chmod +x cbdep

    CBDEPS_DIR=${HOME}/cbdeps
    mkdir -p ${CBDEPS_DIR}

    #install golang
    if [[ ! -d ${CBDEPS_DIR}/go${GO_REL} ]]; then
        ./cbdep install golang ${GO_REL} -d ${CBDEPS_DIR}
    fi
    export GOROOT=${CBDEPS_DIR}/go${GO_REL}
    export PATH=${GOROOT}/bin:$PATH

    #install python and pyinstaller
    if [[ -f "${SGW_DIR}/uv.lock" ]]; then
      PYTHON_VERSION=$(grep -oE 'python = "[^"]+"' "${SGW_DIR}/uv.lock" | sed -E 's/.*"==?([0-9]+(\.[0-9]+){1,2})\.?\*?"/\1/')
    fi
    # Default to 3.9 if not set
    PYTHON_VERSION="${PYTHON_VERSION:-3.9}"

    uv venv --python ${PYTHON_VERSION} ./mypyenv
    source ./mypyenv/bin/activate
    python -m ensurepip --upgrade --default-pip
    pip install pyinstaller

    go version
    python --version
    pyinstaller --version
}

function check_result {
    local type="$1"
    local check="$2"
    local failure_description="$3"
    local error_code="${4:-55}"

    case "${check_type}" in
        "file")
            if [[ -e "${check}" ]]; then
                echo "Found ${description}"
                return 0
            else
                echo "FAIL! ${failure_description}: ${check}"
                exit ${error_code}
            fi
            ;;
        "exit_code")
            if [ ${check} -eq "0" ]; then
                return 0
            else
                echo "FAIL! ${failure_description} = ${check}"
                exit ${error_code}
            fi
            ;;
    esac
}

function go_test {
    echo ======== full test suite ==================================== `date`
    echo ........................ running sync_gateway test.sh

    pushd ${SGW_DIR}
    GOMAXPROCS=${GO_TEST_CPU} go test ${GO_EDITION_OPTION} ./...
    test_result=$?
    check_result "exit_code" ${test_result} "sync-gateway Unit test return code" 66

    echo ======== test with race detector ============================= `date`
    echo ........................ running sync_gateway test.sh
    GOMAXPROCS=${GO_TEST_CPU} go test ${TEST_OPTIONS} ${GO_EDITION_OPTION} ./...
    test_result_race=$?
    check_result "exit_code" ${test_result_race} "sync_gateway Unit test with -race return code" 66
    
    popd
}

function setup_build_environment {
    TARGET_DIR=${WORKSPACE}/${VERSION}/${EDITION}
    BIN_DIR=${WORKSPACE}/${VERSION}/${EDITION}/godeps/bin
    LIC_DIR=${TARGET_DIR}/product-texts/mobile/sync_gateway/license
    
    # older sgw manifest maps sgw repo to godeps/src/github.com/couchbase/sync_gateway
    # and it is not a go module
    # newer sgw manifest maps sgw repo to sync_gateway and it is a go module
    if [[ -d ${TARGET_DIR}/sync_gateway ]]; then
        SGW_DIR=${TARGET_DIR}/sync_gateway
    else
        export GO111MODULE=off
        SGW_DIR=${TARGET_DIR}/godeps/src/github.com/couchbase/sync_gateway
    fi
    
    # Enable go options for enterprise build
    GO_EDITION_OPTION=''
    if [[ $EDITION =~ enterprise ]]; then
        GO_EDITION_OPTION='-tags cb_sg_enterprise'
    fi
    export GOPATH=`pwd`/godeps
    export GOPROXY=http://goproxy.build.couchbase.com,https://proxy.golang.org
    export GOPRIVATE=github.com/couchbaselabs/go-fleecedelta
    export CGO_ENABLED=1
}

function go_build {
    declare -a TEMPLATE_FILES=("${SGW_DIR}/rest/api.go" "${SGW_DIR}/base/version.go")

    echo ======== insert ${PRODUCT_NAME} build meta-data ==============
    for TF in ${TEMPLATE_FILES[@]}; do
        cat ${TF} | sed -e "s,@PRODUCT_NAME@,${PRODUCT_NAME},g" \
                  | sed -e "s,@PRODUCT_VERSION@,${VERSION}-${BLD_NUM},g" \
                  | sed -e "s,@COMMIT_SHA@,${REPO_SHA},g"      > ${TF}.new
        mv  ${TF}      ${TF}.orig
        mv  ${TF}.new  ${TF}
    done

    echo ======== building ${PRODUCT_NAME} ===============================
    pushd ${SGW_DIR}
    rm -rf bin pkg
    mkdir -p bin pkg
    go install ${GO_EDITION_OPTION} ./...
    popd

    # move sync_gateway binary to the correct location
    check_result "file" "${BIN_DIR}/${EXEC}" "Build sync_gateway binary result" 55
    mv -f ${BIN_DIR}/${EXEC} ${SGW_DIR}/bin
    echo ".............................. ${PRODUCT_NAME} Success! Output is: ${SGW_DIR}/bin/${EXEC}"

    # restore build meta-data
    for TF in ${TEMPLATE_FILES[@]}; do
        mv  ${TF}.orig ${TF}
    done

    echo ======== build sgcollect_info ===============================
    COLLECTINFO_DIR=${SGW_DIR}/tools
    COLLECTINFO_DIST=${COLLECTINFO_DIR}/dist/${COLLECTINFO_NAME}

    pushd ${COLLECTINFO_DIR}
    pyinstaller --onefile ${COLLECTINFO_NAME}
    check_result "file" "${COLLECTINFO_DIST}" "Build ${COLLECTINFO_NAME} result" 55
    popd
}

function make_metrics_metadata {
    if [ ! -d ${SGW_DIR}/tools/stats-definition-exporter ]
      then
        return
    fi

    echo ======== creating metrics_metadata deliverable ==================
    pushd ${SGW_DIR}

    go run ./tools/stats-definition-exporter --no-file | jq . --sort-keys > metrics_metadata.json
    tar czf ${WORKSPACE}/metrics_metadata_${VERSION}-${BLD_NUM}.tar.gz metrics_metadata.json
    rm metrics_metadata.json
    popd
}

function package_sync_gateway {
    PREFIX=/opt/couchbase-sync-gateway
    PREFIXP=./opt/couchbase-sync-gateway

    BLD_DIR=${SGW_DIR}/build
    STAGING=${BLD_DIR}/opt/couchbase-sync-gateway


    if [[ -e ${PREFIX}  ]] ; then sudo rm -rf ${PREFIX}  ; fi
    if [[ -e ${STAGING} ]] ; then      rm -rf ${STAGING} ; fi

    export RPM_ROOT_DIR=${BLD_DIR}/build/rpm/couchbase-sync-gateway_${VERSION}-${BLD_NUM}/rpmbuild/

    echo ======== sync sync_gateway ===================
    if [[ ! -d ${STAGING}/bin/      ]] ; then mkdir -p ${STAGING}/bin/      ; fi
    if [[ ! -d ${STAGING}/tools/    ]] ; then mkdir -p ${STAGING}/tools/    ; fi
    if [[ ! -d ${STAGING}/examples/ ]] ; then mkdir -p ${STAGING}/examples/ ; fi
    if [[ ! -d ${STAGING}/service/  ]] ; then mkdir -p ${STAGING}/service/  ; fi

    echo ======== Prep STAGING for packaging =============================
    cp    ${COLLECTINFO_DIST}                  ${STAGING}/tools/

    if [[ -f ${BLD_DIR}/notices.txt ]]; then
        cp    ${BLD_DIR}/notices.txt               ${STAGING}
    fi
    cp    ${BLD_DIR}/README.txt                ${STAGING}
    echo  ${VERSION}-${BLD_NUM}            >   ${STAGING}/VERSION.txt
    cp    ${LIC_DIR}/LICENSE_${EDITION}.txt    ${STAGING}/LICENSE.txt
    cp -r ${SGW_DIR}/examples                  ${STAGING}
    cp    ${SGW_DIR}/service/README.md         ${STAGING}/service
    cp -r ${SGW_DIR}/service/script_templates  ${STAGING}/service

    echo ======== sync_gateway package =============================
    cp    ${SGW_DIR}/bin/${EXEC}                ${STAGING}/bin/
    cp    ${SGW_DIR}/service/sync_gateway_*  ${STAGING}/service

    echo cd ${BLD_DIR}' => ' ./${PKGR} ${PREFIX} ${PREFIXP} ${VERSION}-${BLD_NUM} ${REPO_SHA} ${PLATFORM} ${ARCHP}
    pushd ${BLD_DIR}
    if [[ $DISTRO == "linux" ]]; then
        docker run --rm --pull=always --volumes-from $(uname -n) --workdir `pwd` --user 1000:1000 \
            couchbasebuild/server-deb-sidecar:latest \
            ruby package-deb.rb ${PREFIX} ${PREFIXP} ${VERSION}-${BLD_NUM} ${REPO_SHA} Linux-x86_64 amd64
        rm -rf ./opt/couchbase-sync-gateway/*.deb
        ruby package-rpm.rb ${PREFIX} ${PREFIXP} ${VERSION}-${BLD_NUM} ${REPO_SHA} Linux-x86_64 x86_64
    fi

    echo  ======= prep upload sync_gateway =========
    if [[ $DISTRO == "macosx" ]]; then
        tar -xzf ${STAGING}/${PKG_NAME}
        zip -r -X ${NEW_PKG_NAME} couchbase-sync-gateway
        rm -rf couchbase-sync-gateway
        mv ${NEW_PKG_NAME} ${WORKSPACE}/${NEW_PKG_NAME}
    else
        cp ${STAGING}/${PKG_NAME} ${WORKSPACE}/${NEW_PKG_NAME}
    fi
    popd
}

#main
if [[ "$#" -le 5 ]] ; then usage ; exit 11 ; fi

# enable nocasematch
shopt -s nocasematch

DISTRO=${1}

VERSION=${2}

BLD_NUM=${3}

EDITION=${4}

REPO_SHA=${5}

if [[ $6 ]] ; then  echo "setting TEST_OPTIONS to $6"   ; TEST_OPTIONS=$6   ; else TEST_OPTIONS="None"  ; fi
if [[ $7 ]] ; then  echo "setting GO_REL to $7"         ; GO_REL=$7         ; else GO_REL=1.5.3         ; fi

#if python is not defined, use system default #this is to allow SGW 2.7.x to continue use python 2.7
if [[ $8 ]] ; then  echo "setting MINIFORGE_VERSION to $8"         ; MINIFORGE_VERSION=$8; fi

OS=`uname -s`
ARCH=`uname -m`

export DISTRO ; export VERSION ; export BLD_NUM ; export EDITION
export OS ; export ARCH
export GOOS ; export EXEC

PRODUCT_NAME="Couchbase Sync Gateway"

EXEC=sync_gateway
COLLECTINFO_NAME=sgcollect_info

if [[ $DISTRO == "linux" ]]
then
    GOOS=linux
    PKGR=package-rpm.rb
    PKGTYPE=rpm
    PLATFORM=${OS}-${ARCH}
    PKG_NAME=couchbase-sync-gateway_${VERSION}-${BLD_NUM}_${ARCH}.${PKGTYPE}
    NEW_PKG_NAME=couchbase-sync-gateway-${EDITION}_${VERSION}-${BLD_NUM}_${ARCH}.${PKGTYPE}
    CBDEP_URL="https://packages.couchbase.com/cbdep/cbdep-linux-${ARCH}"
    export LC_ALL="en_US.utf8"
    GO_TEST_CPU=$(echo "$(nproc) / 2 - 1" | bc)
elif [[ $DISTRO == "macosx" ]]
then
    GOOS=darwin
    PKGR=package-mac.rb
    PLATFORM=${DISTRO}-${ARCH}
    PKG_NAME=couchbase-sync-gateway_${VERSION}-${BLD_NUM}_${DISTRO}-${ARCH}.tar.gz
    NEW_PKG_NAME=couchbase-sync-gateway-${EDITION}_${VERSION}-${BLD_NUM}_${ARCH}_unsigned.zip
    CBDEP_URL="https://packages.couchbase.com/cbdep/cbdep-darwin-${ARCH}"
    GO_TEST_CPU=$(echo "$(sysctl -n hw.logicalcpu) -1" | bc)
else
    echo -e "\nunsupported DISTRO:  $DISTRO\n"
    exit 22
fi

#install dependent tools, i.e. golang, python
install_dependencies

# disable nocasematch
shopt -u nocasematch

env | sort -u
echo ============================================== `date`

# build sync_gateway
setup_build_environment
go_build

# Only need to build this once per overall build. Choose 'macosx' as
# the distro since we'll always build that
if [ "${DISTRO}-${ARCH}-${EDITION}" = "macosx-arm64-enterprise" ]
  then
    make_metrics_metadata
fi

# package sync_gateway
package_sync_gateway

set +e
go_test
