#! /bin/bash
#set -x
#
# Copyright (c) 2012 Red Hat, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#           http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

# oVirt/RHEVM environment synchronization script
# required utilities: xmllint, curl

HEADER_CONTENT_TYPE="Content-Type: application/xml"
HEADER_ACCEPT="Accept: application/xml"
# communication file for request/response
COMM_FILE="/tmp/restapi_comm.xml"

# get number of rows returned by XPath expression
function getXPathCount {
    local xPath="count($1)"
    echo $(xmllint --xpath $xPath $COMM_FILE)
}

# get string value of node returned by XPath expression
function getXPathValue {
    local xPath="string($1)"
    echo $(xmllint --xpath $xPath $COMM_FILE)
}

function callGETService {
    local uri=$1
    local certAtt=""

    if [[ -n "$CA_CERT_PATH" ]]; then
        certAtt="--cacert $CA_CERT_PATH"
    fi

    #echo "Calling URI (GET): " ${uri}
    curl -X GET -H "${HEADER_ACCEPT}" -H "${HEADER_CONTENT_TYPE}" -u "${USER_NAME}:${USER_PASSW}" $certAtt "${ENGINE_URL}${uri}" --output "${COMM_FILE}" 2> /dev/null > "${COMM_FILE}"
}

function callPOSTService {
    local uri=$1
    local xml=$2
    local certAtt=""

    if [[ -n "$CA_CERT_PATH" ]]; then
        certAtt="--cacert $CA_CERT_PATH"
    fi

    #echo "Calling URI (POST): " ${uri}
    curl -X POST -H "${HEADER_ACCEPT}" -H "${HEADER_CONTENT_TYPE}" -u "${USER_NAME}:${USER_PASSW}" $certAtt "${ENGINE_URL}${uri}" -d "${xml}" 2> /dev/null > "${COMM_FILE}"
}

function callPUTService {
    local uri=$1
    local xml=$2
    local certAtt=""

    if [[ -n "$CA_CERT_PATH" ]]; then
        certAtt="--cacert $CA_CERT_PATH"
    fi

    #echo "Calling URI (PUT): " ${uri}
    curl -X PUT -H "${HEADER_ACCEPT}" -H "${HEADER_CONTENT_TYPE}" -u "${USER_NAME}:${USER_PASSW}" $certAtt "${ENGINE_URL}${uri}" -d "${xml}" 2> /dev/null > "${COMM_FILE}"
}

# wait till XPath returns non-zero number of rows from specified REST API GET service
function waitForStatus {
    local uri=$1
    local xPathStatusTest=$2
    local xPathStatusValue=$3
    local retries=$4
    local retryIntervalSec=$5

    local status="0"
    while [ ${retries} -ne 0 ]; do
        callGETService "${uri}"
        local c=`getXPathCount "${xPathStatusTest}"`
        local val=`getXPathValue "${xPathStatusValue}"`

        if [ ${c} -gt 0 ]; then
            #echo "Target status ${val} reached. Done."
            status="1"
            break;
        else
	    retries=$((retries-1))
            #echo "Waiting for ${retryIntervalSec} s...(${retries}, value=${val})"
            sleep ${retryIntervalSec}
        fi
    done;

    if [[ "$status" == "0" ]]; then
        #echo "Timeout, waiting interrupted."
	return 255
    fi
}

# Function to check multiple disk status during migration
function waitForDisk {
    local uri=$1
    local xPathStatusTest=$2
    local xPathStatusValue=$3

    local status="0"
    callGETService "${uri}"
    local c=`getXPathCount "${xPathStatusTest}"`
    local val=`getXPathValue "${xPathStatusValue}"`

    if [ ${c} -gt 0 ]; then
    	#echo "Target status ${val} reached. Done."
    	status="1"
    	return 0 
    else
        #echo "Waiting for ${retryIntervalSec} s...(${retries}, value=${val})"
    	return 1
    fi
}

# get all hosts
function getHosts {
    callGETService "/api/hosts;max=1000"
    local c=`getXPathCount "/hosts/host[@id]"`
    echo "Current host count: " ${c}
}

# create host if it doesn't exist
function createHost {
    local hostName=$1
    local hostAddress=$2
    local hostPassword=$3
    local clusterName=$4

    getHosts
    local hostCount=`getXPathCount "/hosts/host[name='${hostName}']"`
    getClusters
    local idCluster=`getXPathValue "/clusters/cluster[name='${clusterName}']/@id"`

    if [[ "${hostCount}" == "0" ]]; then
        echo "Host doesn't exist, creating: ${hostName}..."
        local xml="<host><name>${hostName}</name><address>${hostAddress}</address><root_password>${hostPassword}</root_password><cluster id='${idCluster}' href='/api/clusters/${idCluster}'/></host>"
        callPOSTService "/api/hosts" "${xml}"
        # show response
        cat $COMM_FILE
        # wait for host creation
        waitForStatus "/api/hosts" "/hosts/host[name='${hostName}']/status[state='up']" "/hosts/host[name='${hostName}']/status/state" 10
        echo "Host created."
    else
        echo "Host exists: ${hostName}"
    fi
}

# get all clusters
function getClusters {
    callGETService "/api/clusters"
    local c=`getXPathCount "/clusters/cluster[@id]"`
    echo "Current cluster count: " ${c}
}

# get all storage domains
function getStorages {
    callGETService "/api/storagedomains"
    local c=`getXPathCount "/storage_domains/storage_domain[@id]"`
    echo "Current storage domain count: " ${c}
}

# create storage domain if it doesn't exist
function createStorage {
    local type=$1
    local fsType=$2
    local name=$3
    local address=$4
    local path=$5
    local hostName=$6

    getStorages
    # test if storage exists, if so, do not continue
    local c=`getXPathCount "/storage_domains/storage_domain[name='${name}']"`

    if [[ "$c" == "0" ]]; then
        echo "Storage domain doesn't exist, creating: ${name}..."
        local xml="<storage_domain><name>$name</name><type>$type</type><storage><type>$fsType</type><address>$address</address><path>$path</path></storage><host><name>$hostName</name></host></storage_domain>"
        callPOSTService "/api/storagedomains" "${xml}"
        cat ${COMM_FILE}
        echo "Storage domain create request has been sent."
    else
        echo "Storage domain exists: ${name}"
    fi
}

# import storage domain if it doesn't exist (name is not specified)
function importStorage {
    local type=$1
    local fsType=$2
    local address=$3
    local path=$4
    local hostName=$5

    getStorages
    # test if storage exists, if so, do not continue
    local c=`getXPathCount "/storage_domains/storage_domain[type='${type}']"`

    if [[ "$c" == "0" ]]; then
        echo "Storage domain doesn't exist, importing type: ${type}..."
        local xml="<storage_domain><type>$type</type><storage><type>$fsType</type><address>$address</address><path>$path</path></storage><host><name>$hostName</name></host></storage_domain>"
        callPOSTService "/api/storagedomains" "${xml}"
        cat ${COMM_FILE}
        echo "Storage domain import request has been sent."
    else
        echo "Storage domain exists: ${name}"
    fi
}

function createNfsDataStorage {
    local name=$1
    local address=$2
    local path=$3
    local hostName=$4

    createStorage "data" "nfs" $name $address $path $hostName
}

function createNfsIsoStorage {
    local name=$1
    local address=$2
    local path=$3
    local hostName=$4

    createStorage "iso" "nfs" $name $address $path $hostName
}

function createNfsExportStorage {
    local name=$1
    local address=$2
    local path=$3
    local hostName=$4

    createStorage "export" "nfs" $name $address $path $hostName
}

function importNfsIsoStorage {
    local address=$1
    local path=$2
    local hostName=$3

    importStorage "iso" "nfs" $address $path $hostName
}

function importNfsExportStorage {
    local address=$1
    local path=$2
    local hostName=$3

    importStorage "export" "nfs" $address $path $hostName
}

# get DC
function getDataCenters {
    callGETService "/api/datacenters"
    local c=`getXPathCount "/data_centers/data_center[@id]"`
    echo "Current data center count: " ${c}
}

function attachStorageToDataCenter {
    local dataCenterName=$1
    local storageName=$2

    getDataCenters
    local idDataCenter=`getXPathValue "/data_centers/data_center[name='${dataCenterName}']/@id"`
    echo "idDataCenter: " ${idDataCenter}

    callGETService "/api/datacenters/${idDataCenter}/storagedomains"

    local storagesAttachedCount=`getXPathCount "/storage_domains/storage_domain[name='${storageName}']/data_center[@id]"`
    local idStorage=`getXPathValue "/storage_domains/storage_domain[name='$storageName']/@id"`
    echo "storagesAttachedCount: " ${storagesAttachedCount}
    echo "idStorage: " ${idStorage}

    if [[ "${storagesAttachedCount}" == "0" ]]; then
        echo "Storage is not attached, attaching: ${storageName}..."
        local xml="<storage_domain><name>${storageName}</name></storage_domain>"
        callPOSTService "/api/datacenters/${idDataCenter}/storagedomains" "${xml}"
        cat ${COMM_FILE}
        echo "Storage domain attach request has been sent."
    else
        echo "Domain: ${storageName} already attached to data center: ${dataCenterName}"
    fi
}

# activate DC storage
function activateDataCenterStorage {
    local dataCenterName=$1
    local storageName=$2

    getDataCenters
    local idDataCenter=`getXPathValue "/data_centers/data_center[name='$dataCenterName']/@id"`
    getStorages
    local idStorageDomain=`getXPathValue "/storage_domains/storage_domain[name='$storageName']/@id"`
    local storageDomainUri="/api/datacenters/${idDataCenter}/storagedomains"

    # get status of storage domain
    callGETService "${storageDomainUri}"

    local xPathStatusTest="/storage_domains/storage_domain[@id='${idStorageDomain}']/status[state='active']"
    local xPathStatusValue="/storage_domains/storage_domain[@id='${idStorageDomain}']/status/state"

    local activeCount=`getXPathCount "${xPathStatusTest}"`

    if [[ "${activeCount}" == "0" ]]; then
        echo "Storage is not active, activating: ${storageName}..."
        local xml="<action/>"
        callPOSTService "/api/datacenters/${idDataCenter}/storagedomains/${idStorageDomain}/activate" "${xml}"
        sleep 10
        cat ${COMM_FILE}
        echo "Attach request sent."
      # wait till storage domain is active
      waitForStatus "${storageDomainUri}" "${xPathStatusTest}" "${xPathStatusValue}" 20
    else
        echo "Domain ${storageName} is already active."
    fi
}

# get VM
function getVirtualMachines {
    callGETService "/api/vms;max=1000"
    local c=`getXPathCount "/vms/vm"`
    echo "Current VM count: " ${c}
}

# search VM
function searchVirtualMachine {
    local vmName=$1
    callGETService "/api/vms/?search=$vmName"
}

# create VM
function createVirtualMachineFromTemplate {
    local vmName=$1
    local clusterName=$2
    local templateName=$3
    # bytes
    local memorySize=$4

    getVirtualMachines
    local c=`getXPathCount "/vms/vm[name='${vmName}']"`

    if [[ "$c" == "0" ]]; then
        echo "VM doesn't exist, creating: ${vmName}..."
        local xml="<vm><name>${vmName}</name><cluster><name>${clusterName}</name></cluster><template><name>${templateName}</name></template><memory>${memorySize}</memory><os type='other_linux'><boot dev='hd'/></os><type>server</type></vm>"
        callPOSTService "/api/vms" "${xml}"
        cat ${COMM_FILE}
        echo "VM created."
    else
        echo "VM exists: ${vmName}"
    fi
}

# create VM network
function createVirtualMachineNIC {
    local vmName=$1
    local networkName=$2

    getVirtualMachines
    local c=`getXPathCount "/vms/vm[name='${vmName}']"`

    if [[ "$c" == "0" ]]; then
        echo "VM doesn't exist: ${vmName}"
    else
        local idVM=`getXPathValue "/vms/vm[name='${vmName}']/@id"`

        callGETService "/api/vms/${idVM}/nics"
        local nicsCount=`getXPathCount "/nics/nic[@id]"`

        if [[ "$nicsCount" == "0" ]]; then
          echo "NIC doesn't exist, creating..."
          local xml="<nic><name>nic1</name><network><name>${networkName}</name></network></nic>"
          callPOSTService "/api/vms/${idVM}/nics" "${xml}"
          cat ${COMM_FILE}
          echo "NIC created."
        else
          echo "NIC exists."
      fi
    fi
}

# create VM storage
function createVirtualMachineDisk {
    local vmName=$1
    local diskSize=$2
    local storageName=$3

    getVirtualMachines
    local c=`getXPathCount "/vms/vm[name='${vmName}']"`

    if [[ "$c" == "0" ]]; then
        echo "VM doesn't exist: ${vmName}"
    else
        local idVM=`getXPathValue "/vms/vm[name='${vmName}']/@id"`

        callGETService "/api/vms/${idVM}/disks"
        local diskCount=`getXPathCount "/disks/disk[@id]"`

        if [[ "$diskCount" == "0" ]]; then
          echo "Disk doesn't exist, creating..."
          getStorages
        local idStorageDomain=`getXPathValue "/storage_domains/storage_domain[name='${storageName}']/@id"`
        echo "idStorageDomain: " ${idStorageDomain}
          local xml="<disk><storage_domains><storage_domain id='${idStorageDomain}'/></storage_domains><size>${diskSize}</size><type>system</type><interface>virtio</interface><format>cow</format><bootable>true</bootable></disk>"
          callPOSTService "/api/vms/${idVM}/disks" "${xml}"
          cat ${COMM_FILE}
          echo "Disk created."
        else
          echo "Disk exists."
      fi
    fi
}

# Move VM Disk
function moveVirtualMachineDisk {
	local vmNames=$1

	searchVirtualMachine "${vmNames}"
	local vms=$(getXPathCount "/vms/vm/@id")
	if [ ${vms} -eq 0 ]; then
		echo "VM doesn't exist: ${vmNames}"
	else
		declare -a disks_in_move
		for vm in $(xmllint --xpath "/vms/vm/@id" ${COMM_FILE} |sed -e "s/ /_/g;s/id\=\"//g;s/\"/ /g;s/_//g")
		do
        		callGETService "/api/vms/${vm}"
			local vmName=$(getXPathValue "/vm/name")
			local vmID=${vm}
			local vmEnv=$(echo ${vmName} |awk -F"." '{print $2}')
        		callGETService "/api/vms/${vmID}/disks"
			local d=$(getXPathCount "/disks/disk")
			for i in $(seq 1 $d)
			do
				if [ "$(getXPathValue "/disks/disk[${i}]/bootable")" == "true" ]; then
					local osDisk=$(getXPathValue "/disks/disk[${i}]/name")
					local osDiskID=$(getXPathValue "/disks/disk[${i}]/@id")
					local osDiskStorageID=$(getXPathValue "/disks/disk[${i}]/storage_domains/storage_domain/@id")
				else
					local dataDisk[${i}]=$(getXPathValue "/disks/disk[${i}]/name")
					local dataDiskID[${i}]=$(getXPathValue "/disks/disk[${i}]/@id")
					local dataDiskSize[${i}]=$(getXPathValue "/disks/disk[${i}]/provisioned_size")
					local dataDiskStorageID[${i}]=$(getXPathValue "/disks/disk[${i}]/storage_domains/storage_domain/@id")
				fi
			done
			
			callGETService "/api/storagedomains/?search=*-os-domain-${vmEnv}"
			local osStorageID=$(getXPathValue "/storage_domains/storage_domain/@id")
			local osStorage=$(getXPathValue "/storage_domains/storage_domain/name")
			callGETService "/api/storagedomains/?search=*-data-domain-${vmEnv}"
			local dataStorageID=$(getXPathValue "/storage_domains/storage_domain/@id")

			# move osDisk
			if [ -n "${osDisk}" -a -n "${osStorageID}" ]; then
				if [ "${osStorageID}" != "${osDiskStorageID}" ]; then
					echo "Moving ${osDisk} to ${osStorage}..."
					local xml="<action><storage_domain id='${osStorageID}'/></action>"
					callPOSTService "/api/disks/${osDiskID}/move" "${xml}"

					if [ ${#disks_in_move[*]} -ne 0 ]; then
						disks_in_move=("${disks_in_move[@]}" "${osDiskID}")
					else
						disks_in_move=("${osDiskID}")
					fi

					if [ ${#disks_in_move[*]} -eq 3 ]; then
						local retries=100
						local retryIntervalSec=6
						# wait until disk is moved
						echo "Waiting for a disk finish migration..."
						while [ ${retries} -gt 0 ]; do
							for i in $(seq 0 $((${#disks_in_move[*]}-1)))
							do
								waitForDisk "/api/disks/${disks_in_move[${i}]}" "/disk/status[state='ok']" "/disk/status/state"
								if [ $? -eq 0 ]; then
									local diskName=$(getXPathValue "/disk/name")
									echo "Disk ${diskName} is done."
									unset disks_in_move[${i}]
									disks_in_move=("${disks_in_move[@]}")
									break 2
								elif [ $? -eq 1 ]; then
									sleep 2
								fi
							done
							retries=$((retries - 1))
						done
						if [ ${retries} -eq 0 ]; then
							echo "ERROR: Timed out after 10 minutes"
							break
						fi
					else
						continue
					fi
				else
					echo "${osDisk} is already on ${osStorage}"
				fi
			fi
#			$(( provisioned_size / 1024 /1024 /1024))
		done
		while [ ${#disks_in_move[*]} -gt 0 ]; do
			local retries=100
			local retryIntervalSec=6
			# wait until disk is moved
			while [ ${retries} -gt 0 ]; do
				for i in $(seq 0 $((${#disks_in_move[*]}-1)))
				do
					waitForDisk "/api/disks/${disks_in_move[${i}]}" "/disk/status[state='ok']" "/disk/status/state"
					if [ $? -eq 0 ]; then
						local diskName=$(getXPathValue "/disk/name")
						echo "Disk ${diskName} is done."
						unset disks_in_move[${i}]
						disks_in_move=("${disks_in_move[@]}")
						break
					elif [ $? -eq 1 ]; then
						sleep 2
					fi
				done
				retries=$((retries - 1))
			done
			if [ ${retries} -eq 0 ]; then
				echo "ERROR: Timed out after 10 minutes"
				break
			fi
		done
	fi
}

# create VM iso drive
function createVirtualMachineCDROM {
    local vmName=$1
    local isoImageName=$2

    getVirtualMachines
    local c=`getXPathCount "/vms/vm[name='${vmName}']"`

    if [[ "$c" == "0" ]]; then
        echo "VM doesn't exist: ${vmName}"
    else
        local idVM=`getXPathValue "/vms/vm[name='${vmName}']/@id"`

        callGETService "/api/vms/${idVM}/cdroms"
        local diskCount=`getXPathCount "/cdroms/cdrom[@id]/file[@id]"`

        if [[ "$diskCount" == "0" ]]; then
          echo "CD-ROM doesn't exist, creating..."
          local xml="<cdrom><file id='${isoImageName}'/></cdrom>"
          callPOSTService "/api/vms/${idVM}/cdroms" "${xml}"
          cat ${COMM_FILE}
          echo "CD-ROM created."
        else
          echo "CD-ROM exists."
      fi
    fi
}

function showList {
	local xPath=$1

	local c=`getXPathCount "${xPath}"`

	for i in $(seq 1 ${c})
	do
		local val=`getXPathValue "(${xPath})[$i]"`
		echo ${val}
	done

	echo "Count: ${c}"
}

function showHostList {
	getHosts
	showList "/hosts/host/name"
}

function showVMList {
	getVirtualMachines
	showList "/vms/vm/name"
}

function getVMPools {
    callGETService "/api/vmpools"
    local c=`getXPathCount "/vmpools/vmpool"`
    echo "Current VM pools count: " ${c}
}

function updateVMPoolSize {
	local vmPoolName=$1
    local vmPoolSize=$2

	getVMPools
    local c=`getXPathCount "/vmpools/vmpool[name='${vmPoolName}']"`

    if [[ "$c" == "0" ]]; then
    	echo "VM Pool doesn't exist: ${vmPoolName}"
	else
		local idVMPool=`getXPathValue "/vmpools/vmpool[name='${vmPoolName}']/@id"`
		local xml="<vmpool><name>${vmPoolName}</name><size>${vmPoolSize}</size></vmpool>"

        callPUTService "/api/vmpools/${idVMPool}" "${xml}"
        cat ${COMM_FILE}
        echo "VMPool ${vmPoolName} updated."
    fi
}

