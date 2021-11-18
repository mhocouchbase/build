#!/bin/bash -ex

echo "Downloading source..."
curl -LO http://latestbuilds.service.couchbase.com/builds/latestbuilds/${PRODUCT}/${RELEASE}/${BLD_NUM}/${PRODUCT}-${VERSION}-${BLD_NUM}-source.tar.gz
echo "Extracting source..."
tar xzf ${PRODUCT}-${VERSION}-${BLD_NUM}-source.tar.gz
rm *-source.tar.gz

echo "Download dependent tools: maven and jdk"
#When set JDK_HOME to system installed, it didn't seem to work somehow.
#Download via cbdep so we have control over which version to use.

CBDEP_VESION=1.1.2
JDK_VERSION=11.0.9+11
MAVEN_VERSION=3.8.3

mkdir deps
mkdir dist

pushd deps
curl https://packages.couchbase.com/cbdep/${CBDEP_VESION}/cbdep-${CBDEP_VESION}-linux-x86_64 -o cbdep
chmod +x cbdep
./cbdep install openjdk ${JDK_VERSION} -d .
curl -LO https://dlcdn.apache.org/maven/maven-3/${MAVEN_VERSION}/binaries/apache-maven-${MAVEN_VERSION}-bin.tar.gz
tar -xzf apache-maven-${MAVEN_VERSION}-bin.tar.gz
export PATH=$(pwd)/apache-maven-${MAVEN_VERSION}/bin:$(pwd)/openjdk-${JDK_VERSION}/bin:$PATH
export JAVA_HOME=$(pwd)/openjdk-${JDK_VERSION}
popd

mvn -B install -DskipTests -Dpython.path=$(which python3) -f cbtaco/pom.xml

pushd dist
cp -rp ../cbtaco/cbas/cbas-jdbc-taco/target/cbas_jdbc.taco .
cp -rp ../cbtaco/couchbase-jdbc-driver/target/couchbase-jdbc-driver-*.jar .
tar -czf ${PRODUCT}-${VERSION}-${BLD_NUM}-linux_x86_64.tar.gz *
popd
