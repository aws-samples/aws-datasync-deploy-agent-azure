#!/bin/bash
# Script to convert HyperV datasync image to Azure
# Runs on Amazon Linux 2 x86_64 only

set -e

while getopts ":d:l:r:v:g:n:s:" opt; do
  case $opt in
    d) deployment_type="$OPTARG"
    ;;
    l) location="$OPTARG"
    ;;
    r) resource_group="$OPTARG"
    ;;
    v) vm_name="$OPTARG"
    ;;
    g) vnet_rg="$OPTARG"
    ;;
    n) vnet_name="$OPTARG"
    ;;
    s) subnet_name="$OPTARG"
    ;;
    \?) echo "Invalid option -$OPTARG" >&2
    exit 1
    ;;
  esac

  case $OPTARG in
    -*) echo "Option $opt needs a valid argument"
    exit 1
    ;;
  esac
done

shift $((OPTIND -1))

# Check if deployment type is "new_vnet" or "existing_vnet"
if [ "$deployment_type" != "new_vnet" ] && [ "$deployment_type" != "existing_vnet" ]; then
    echo "Invalid value for deployment type (-d): $deployment_type. Deployment type must be 'new_vnet' or 'existing_vnet'."
    exit 1
fi

# Mandatory parameters deployment_type, location, resource_group and vm_name
if [ -z "$deployment_type" ] || [ -z "$location" ] || [ -z "$resource_group" ] || [ -z "$vm_name" ]; then
    echo "Required parameters are missing. Usage: -d [new_vnet|existing_vnet] -l [location] -r [resource_group] -v [vm_name] [-g [vnet_rg]] [-n [vnet_name]] [-s [subnet_name]]"
    exit 1
fi



# Check if deployment_type is existing_vnet, then vnet_rg, vnet_name, and subnet_name are mandatory
if [ "$deployment_type" == "existing_vnet" ] && { [ -z "$vnet_rg" ] || [ -z "$vnet_name" ] || [ -z "$subnet_name" ]; }; then
    echo "-g [vnet_rg] -n [vnet_name] -s [subnet_name] are mandatory when deployment_type [-d] is 'existing_vnet'."
    exit 1
fi

#if [ $# -ne 12 ]; then
#    echo "Missing -l or -r or -v or -g or -n or -s"
#    exit 1
#fi


# Exiting if not running on X86_64 architecture
arch=$(uname -m)||(arch)
if [ "$arch" != "x86_64" ]; then
    echo "This script runs only on x86_64 architecture"
    exit 1
fi

# Exiting if /tmp is not writable
if [ ! -w "/tmp" ]; then
  echo "Unable to write to /tmp. exiting"
  exit 1
fi

echo -e "\033[0;33mArgument deployment type is $deployment_type\033[0m"
echo -e "\033[0;33mArgument location is $location\033[0m"
echo -e "\033[0;33mArgument vm resource group is $resource_group\033[0m"
echo -e "\033[0;33mArgument vm name is $vm_name\033[0m"
echo -e "\033[0;33mArgument vnet resource group is $vnet_rg\033[0m"
echo -e "\033[0;33mArgument vnet name is $vnet_name\033[0m"
echo -e "\033[0;33mArgument subnet name is $subnet_name\033[0m"

AZCOPY_VERSION=v10

function download_and_install_dependencies () {
    echo -e "[azure-cli]
name=Azure CLI
baseurl=https://packages.microsoft.com/yumrepos/azure-cli
enabled=1
gpgcheck=1
gpgkey=https://packages.microsoft.com/keys/microsoft.asc" | tee /etc/yum.repos.d/azure-cli.repo > /dev/null
    yum -y -q install qemu-img jq unzip azure-cli && yum -y clean all && rm -rf /var/cache
    echo "\033[0;33mWarning azcopy will be downloaded from Internet but there is no integrity hash available.\033[0;33m"
    curl -Ls "https://aka.ms/downloadazcopy-$AZCOPY_VERSION-linux" -o /tmp/azcopy.tar.gz
    tar xzf /tmp/azcopy.tar.gz --directory /tmp || { echo "AzCopy download or extraction failed"; exit 1; }
    cp /tmp/azcopy_linux_amd64*/azcopy /usr/bin/azcopy
    chmod +x /usr/bin/azcopy
}

function download_datasync(){
    echo -e "\033[0;33mDownloading datasync agent for Hyper-V. There is no integrity hash available\033[0;33m"
    curl -s https://d8vjazrbkazun.cloudfront.net/AWS-DataSync-Agent-HyperV.zip -o /tmp/datasync.zip
}

function convert_datasync(){
    echo -e "\033[0;33mConverting datasync to vhd\033[0;33m"
    unzip /tmp/datasync.zip -d /tmp || { echo "AWS DataSync Agent download or extraction failed"; exit 1; }
    vhdxdisk=$(find aws-*)
    rawdisk=${vhdxdisk//vhdx/raw}
    vhddisk=${vhdxdisk//vhdx/vhd}

    qemu-img convert -f vhdx -O raw "$vhdxdisk" "$rawdisk"

    MB=$((1024*1024))
    size=$(qemu-img info -f raw --output json "$rawdisk" | jq -r '.["virtual-size"]')
    rounded_size=$((((size+MB-1)/MB)*MB))
    echo "Rounded Size = $rounded_size"
    qemu-img resize "$rawdisk" "$rounded_size"
    qemu-img convert -f raw -o subformat=fixed,force_size -O vpc "$rawdisk" "$vhddisk"

    rm "$rawdisk"
    disk_name=${vhddisk//\.xfs\.gpt\.vhd}
    upload_size=$(qemu-img info --output json "$vhddisk" | jq -r '.["virtual-size"]')
}

function check_resource_group(){
    group_exists=$(az group exists --resource-group "$resource_group")
    if [ "$group_exists" = "false" ]; then
        az group create --location "$location" --resource-group "$resource_group" --only-show-errors || { echo "An error occurred while creating the resource group"; exit 1; }
    fi
}

function upload_to_azure(){
    echo -e "\033[0;33mUploading to Azure\033[0;33m"
    az login --use-device-code
    check_resource_group
    # shellcheck disable=SC2086
    # az disk create does not accept a string for upload-size-bytes
    az disk create -n "$disk_name" -g "$resource_group" -l "$location" --os-type Linux --upload-type Upload --upload-size-bytes $upload_size --sku standard_lrs --output none --only-show-errors || { echo "An error occured while creating the Azure Disk"; exit 1; }
    sas_uri=$(az disk grant-access -n "$disk_name" -g "$resource_group" --access-level Write --duration-in-seconds 86400 | jq -r '.accessSas') || { echo "An error occurred while granting SAS access"; exit 1; }
    azcopy copy "$vhddisk" "$sas_uri" --blob-type PageBlob || { echo "An error occurred while uploading the Azure Disk"; exit 1; }
    az disk revoke-access -n "$disk_name" -g "$resource_group" || { echo "An error occurred while revoking SAS access"; exit 1; }
}

function create_azure_vm(){
    echo -e "\033[0;33mCreating Azure Virtual Machine for DataSync with a new vnet\033[0;33m"
    az vm create -g "$resource_group" -l "$location" --name "$vm_name" --size Standard_E4as_v5 --os-type linux --attach-os-disk "$disk_name" --public-ip-address "" --only-show-errors || { echo "An error occured while creating the Azure VM"; exit 1; }
}

function create_azure_vm_existing_vnet(){
    echo -e "\033[0;33mCreating Azure Virtual Machine for DataSync with an existing vnet\033[0;33m"
    az vm create -g "$resource_group" -l "$location" --name "$vm_name" --size Standard_E4as_v4 --os-type linux --attach-os-disk "$disk_name" --subnet "$(az network vnet subnet show --resource-group $vnet_rg --vnet-name $vnet_name --name $subnet_name -o tsv --query id)" --public-ip-address "" --only-show-errors || { echo "An error occured while creating the Azure VM"; exit 1; }
}

function cleanup(){
    rm -f /tmp/datasync.zip
    rm -rf /tmp/aws-datasync-*
    rm -rf /tmp/azcopy*
    az logout || true
    echo -e "\033[0m"
}

pushd /tmp
cleanup
download_and_install_dependencies
download_datasync
convert_datasync
upload_to_azure
popd

if [ "$deployment_type" == "new_vnet" ]; then
    echo "Deployment type is new_vnet"
    create_azure_vm
elif [ "$deployment_type" == "existing_vnet" ]; then
    echo "Deployment type is existing_vnet"
    create_azure_vm_existing_vnet
fi
cleanup
