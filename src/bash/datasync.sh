#!/bin/bash
# Script to convert HyperV datasync image to Azure
# Runs on Amazon Linux 2

set -e

while getopts ":l:r:v:" opt; do
  case $opt in
    l) location="$OPTARG"
    ;;
    r) resource_group="$OPTARG"
    ;;
    v) vm_name="$OPTARG"
    ;;
    \?) echo "Invalid option -$OPTARG" >&3
    exit 1
    ;;
  esac

  case $OPTARG in
    -*) echo "Option $opt needs a valid argument"
    exit 1
    ;;
  esac
done

if [ $# -ne 6 ]; then
    echo "Missing -l or -r or -v"
    exit 1
fi

echo -e "\033[0;33mArgument location is $location\033[0m"
echo -e "\033[0;33mArgument resource_group is $resource_group\033[0m"
echo -e "\033[0;33mArgument vm_name is $vm_name\033[0m"

AZCOPY_VERSION=v10

function download_and_install_dependencies () {
    echo -e "[azure-cli]
name=Azure CLI
baseurl=https://packages.microsoft.com/yumrepos/azure-cli
enabled=1
gpgcheck=1
gpgkey=https://packages.microsoft.com/keys/microsoft.asc" | tee /etc/yum.repos.d/azure-cli.repo > /dev/null
    yum -y -q install qemu-img jq unzip azure-cli
    curl -Ls https://aka.ms/downloadazcopy-$AZCOPY_VERSION-linux -o /tmp/azcopy.tar.gz
    tar xzf /tmp/azcopy.tar.gz --directory /tmp
    cp /tmp/azcopy_linux_amd64*/azcopy /usr/bin/azcopy
    chmod +x /usr/bin/azcopy
}

function download_datasync(){
    echo -e "\033[0;33mDownloading datasync agent for Hyper-V\033[0;33m"
    curl -s https://d8vjazrbkazun.cloudfront.net/AWS-DataSync-Agent-HyperV.zip -o /tmp/datasync.zip
}

function convert_datasync(){
    echo -e "\033[0;33mConverting datasync to vhd\033[0;33m"
    unzip /tmp/datasync.zip -d /tmp
    vhdxdisk=$(find aws-*)
    rawdisk=$(echo $vhdxdisk | sed 's/vhdx/raw/')
    vhddisk=$(echo $vhdxdisk | sed 's/vhdx/vhd/')

    qemu-img convert -f vhdx -O raw $vhdxdisk $rawdisk

    MB=$((1024*1024))
    size=$(qemu-img info -f raw --output json "$rawdisk" | jq -r '.["virtual-size"]')
    rounded_size=$(((($size+$MB-1)/$MB)*$MB))
    echo "Rounded Size = $rounded_size"
    qemu-img resize $rawdisk $rounded_size
    qemu-img convert -f raw -o subformat=fixed,force_size -O vpc $rawdisk $vhddisk

    rm $rawdisk
    disk_name=$(echo $vhddisk | sed 's/\.xfs\.gpt\.vhd//')
    upload_size=$(qemu-img info --output json "$vhddisk" | jq -r '.["virtual-size"]')
}

function check_resource_group(){
    group_exists=$(az group exists --resource-group $resource_group)
    if [ $group_exists = "false" ]; then
        az group create --location $location --resource-group $resource_group --only-show-errors
    fi
}

function upload_to_azure(){
    echo -e "\033[0;33mUploading to Azure\033[0;33m"
    az login --use-device-code
    check_resource_group
    az disk create -n $disk_name -g $resource_group -l $location --os-type Linux --upload-type Upload --upload-size-bytes $upload_size --sku standard_lrs --output none --only-show-errors
    sas_uri=$(az disk grant-access -n $disk_name -g $resource_group --access-level Write --duration-in-seconds 86400 | jq -r '.accessSas')
    azcopy copy $vhddisk $sas_uri --blob-type PageBlob
    az disk revoke-access -n $disk_name -g $resource_group
}

function create_azure_vm(){
    echo -e "\033[0;33mCreating Azure Virtual Machine for DataSync\033[0;33m"
    az vm create -g $resource_group -l $location --name $vm_name --size Standard_E4as_v4 --os-type linux --attach-os-disk $disk_name --public-ip-address "" --only-show-errors
}

function cleanup(){
    rm -f /tmp/datasync.zip
    rm -rf /tmp/aws-datasync-*
    rm -rf /tmp/azcopy*
}

pushd /tmp
cleanup
download_and_install_dependencies
download_datasync
convert_datasync
upload_to_azure
create_azure_vm
cleanup
popd
