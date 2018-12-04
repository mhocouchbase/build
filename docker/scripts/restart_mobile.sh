#!/bin/bash

# These are currently all hosted on mega

echo @@@@@@@@@@@@@@@@@@@@@@
echo @ Recreating slaves
echo @@@@@@@@@@@@@@@@@@@@@@
../buildslaves/centos-65/sgw_jenkins/restart.sh # port 2320
../buildslaves/centos-70/sgw_jenkins/restart.sh # port 2322
../buildslaves/ubuntu-14.04/sgw_jenkins/restart.sh # port 2321
../buildslaves/ubuntu-14.04/android/restart.sh  # port 2300
./restart_jenkinsdocker.py ceejatec/ubuntu-1604-couchbase-build:latest      zz-mobile-lightweight 2423 mobile.jenkins.couchbase.com
./restart_jenkinsdocker.py ceejatec/centos-72-litecore-build:20170710       mobile-litecore-linux 6501 mobile.jenkins.couchbase.com
./restart_jenkinsdocker.py --no-workspace ceejatec/ubuntu1604-mobile-lite-android:20180604 mobile-lite-android    6502 mobile.jenkins.couchbase.com
./restart_jenkinsdocker.py --no-workspace ceejatec/ubuntu1604-mobile-lite-android:20180604 mobile-lite-android-02 6503 mobile.jenkins.couchbase.com
./restart_jenkinsdocker.py --no-workspace couchbasebuild/ubuntu1604-sgw-build:20181204 mobile-sgw-ubuntu16.04 2323 mobile.jenkins.couchbase.com
