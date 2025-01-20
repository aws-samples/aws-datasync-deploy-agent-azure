#!/bin/bash
# Script to convert HyperV datasync image to Azure
# Runs on Amazon Linux 2 x86_64 only

set -euo pipefail

# Color definitions for logs
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
GREEN='\033[0;32m'
RED='\033[0;31m'
RESET='\033[0m'

# Log warning messages
function log_warning() {
    echo -e "${YELLOW}[WARNING] $1${RESET}"
}

# Log error messages
function log_error() {
    echo -e "${RED}[ERROR] $1${RESET}"
}

# Log informational messages
function log_info() {
    echo -e "${CYAN}[INFO] $1${RESET}"
}

# Log success messages
function log_success() {
    echo -e "${GREEN}[SUCCESS] $1${RESET}"
}

# Display help information
function show_help() {
    echo -e "${CYAN}AWS DataSync Deployment for Azure${RESET}"
    echo -e "For more details, visit: ${GREEN}https://github.com/aws-samples/aws-datasync-deploy-agent-azure${RESET}"
    echo
    echo -e "${CYAN}Usage:${RESET} $0 [options]"
    echo
    echo -e "${CYAN}Options:${RESET}"
    echo "  -d <deployment_type>  Deployment type ('new_vnet' or 'existing_vnet')"
    echo "  -l <location>         Azure region (e.g., 'eastus', 'westus')"
    echo "  -r <resource_group>   Azure resource group name"
    echo "  -v <vm_name>          Azure VM name"
    echo "  -z <vm_size>          Azure VM size (e.g., 'Standard_E4s_v3', 'Standard_E16_v5')"
    echo "  -g <vnet_rg>          Virtual network resource group (required for 'existing_vnet')"
    echo "  -n <vnet_name>        Virtual network name (required for 'existing_vnet')"
    echo "  -s <subnet_name>      Subnet name (required for 'existing_vnet')"
    echo "  -h                    Show this help message"
    echo
    echo -e "${CYAN}Examples:${RESET}"
    echo "  $0 -d new_vnet -l eastus -r myResourceGroup -v myVM -z Standard_E4s_v3"
    echo "  $0 -d existing_vnet -l eastus -r myResourceGroup -v myVM -g myVnetRG -n myVnet -s mySubnet -z Standard_E16_v5"
    exit 0
}

# Validate inputs to ensure required parameters are provided
function validate_inputs() {
    log_info "Validating input parameters..."
    if [ -z "${deployment_type:-}" ] || [ -z "${location:-}" ] || [ -z "${resource_group:-}" ] || [ -z "${vm_name:-}" ] || [ -z "${vm_size:-}" ]; then
        log_error "Missing required parameters. Use -h for help."
        exit 1
    fi

    if [[ "$deployment_type" != "new_vnet" && "$deployment_type" != "existing_vnet" ]]; then
        log_error "Invalid deployment type (-d). Must be 'new_vnet' or 'existing_vnet'."
        exit 1
    fi

    if [ "$deployment_type" == "existing_vnet" ] && { [ -z "${vnet_rg:-}" ] || [ -z "${vnet_name:-}" ] || [ -z "${subnet_name:-}" ]; }; then
        log_error "-g, -n, and -s are mandatory when deployment type is 'existing_vnet'."
        exit 1
    fi
}

# Perform system pre-checks to ensure the script runs correctly
function pre_checks() {
    log_info "Performing system pre-checks..."
    if [ "$(uname -m)" != "x86_64" ]; then
        log_error "This script only supports x86_64 architecture."
        exit 1
    fi

    if [ ! -w "/tmp" ]; then
        log_error "The /tmp directory is not writable."
        exit 1
    fi
}

# Clean up conflicting files in /tmp
function cleanup_tmp() {
    log_info "Cleaning up /tmp directory to avoid conflicts..."
    rm -f /tmp/azcopy.tar.gz /tmp/datasync.zip
    rm -rf /tmp/azcopy_linux_amd64*
    rm -f /tmp/*.vhdx /tmp/*.raw /tmp/*.vhd
    log_success "Temporary files removed."
}

# Install required dependencies
function setup_dependencies() {
    log_info "Installing required dependencies..."
    echo "[azure-cli]" | tee /etc/yum.repos.d/azure-cli.repo > /dev/null
    echo "name=Azure CLI" | tee -a /etc/yum.repos.d/azure-cli.repo > /dev/null
    echo "baseurl=https://packages.microsoft.com/yumrepos/azure-cli" | tee -a /etc/yum.repos.d/azure-cli.repo > /dev/null
    echo "enabled=1" | tee -a /etc/yum.repos.d/azure-cli.repo > /dev/null
    echo "gpgcheck=1" | tee -a /etc/yum.repos.d/azure-cli.repo > /dev/null
    echo "gpgkey=https://packages.microsoft.com/keys/microsoft.asc" | tee -a /etc/yum.repos.d/azure-cli.repo > /dev/null
    yum install -y qemu-img jq unzip azure-cli || {
        log_error "Failed to install dependencies."
        exit 1
    }

    log_info "Downloading AzCopy..."
    curl -Ls "https://aka.ms/downloadazcopy-v10-linux" -o /tmp/azcopy.tar.gz
    tar -xf /tmp/azcopy.tar.gz -C /tmp || {
        log_error "Failed to download or extract AzCopy."
        exit 1
    }
    mv /tmp/azcopy_linux_amd64*/azcopy /usr/bin/
    chmod +x /usr/bin/azcopy
    log_success "Dependencies installed successfully."
}

# Download the AWS DataSync agent
function download_datasync() {
    log_info "Downloading AWS DataSync agent for Hyper-V..."
    curl -s https://d8vjazrbkazun.cloudfront.net/AWS-DataSync-Agent-HyperV.zip -o /tmp/datasync.zip || {
        log_error "Failed to download AWS DataSync agent."
        exit 1
    }
    log_success "AWS DataSync agent downloaded successfully."
}

# Convert the downloaded DataSync agent to a VHD format
function convert_datasync() {
    log_info "Converting AWS DataSync agent to VHD format..."
    unzip /tmp/datasync.zip -d /tmp || {
        log_error "Failed to extract AWS DataSync agent."
        exit 1
    }

    vhdxdisk=$(find /tmp -name '*.vhdx' | head -n 1)
    rawdisk=${vhdxdisk//vhdx/raw}
    vhddisk=${vhdxdisk//vhdx/vhd}

    qemu-img convert -f vhdx -O raw "$vhdxdisk" "$rawdisk"

    MB=$((1024 * 1024))
    size=$(qemu-img info -f raw --output json "$rawdisk" | jq -r '."virtual-size"')
    rounded_size=$((((size + MB - 1) / MB) * MB))

    qemu-img resize "$rawdisk" "$rounded_size"
    qemu-img convert -f raw -o subformat=fixed,force_size -O vpc "$rawdisk" "$vhddisk"

    rm "$rawdisk"
    disk_name=$(basename "$vhddisk" .vhd)
    upload_size=$(qemu-img info --output json "$vhddisk" | jq -r '."virtual-size"')
    log_success "DataSync agent converted to VHD successfully."
}

# Check if the specified resource group exists, create it if not
function check_resource_group() {
    log_info "Checking Azure resource group: $resource_group..."
    if [ "$(az group exists --name "$resource_group")" == "false" ]; then
        az group create --location "$location" --resource-group "$resource_group" --only-show-errors || {
            log_error "Failed to create resource group."
            exit 1
        }
    fi
    log_success "Azure resource group is ready."
}

# Upload the converted VHD to Azure
function upload_to_azure() {
    log_info "Uploading VHD to Azure..."
    az login || {
        log_error "Failed to login to Azure."
        exit 1
    }

    check_resource_group

    az disk create -n "$disk_name" -g "$resource_group" -l "$location" --os-type Linux --upload-type Upload --upload-size-bytes "$upload_size" --sku Standard_LRS --only-show-errors || {
        log_error "Failed to create Azure disk."
        exit 1
    }

    sas_uri=$(az disk grant-access -n "$disk_name" -g "$resource_group" --access-level Write --duration-in-seconds 86400 | jq -r '.accessSas') || {
        log_error "Failed to grant SAS access."
        exit 1
    }

    azcopy copy "$vhddisk" "$sas_uri" --blob-type PageBlob || {
        log_error "Failed to upload VHD to Azure."
        exit 1
    }

    az disk revoke-access -n "$disk_name" -g "$resource_group"
    log_success "VHD uploaded to Azure successfully."
}

# Create a new Azure VM using the uploaded VHD
function create_vm() {
    log_info "Creating Azure VM: $vm_name..."
    if [ "$deployment_type" == "new_vnet" ]; then
        az vm create -g "$resource_group" -l "$location" --name "$vm_name" --size "$vm_size" --os-type Linux --attach-os-disk "$disk_name" --public-ip-address "" --only-show-errors || {
            log_error "Failed to create Azure VM."
            exit 1
        }
    else
        subnet_id=$(az network vnet subnet show --resource-group "$vnet_rg" --vnet-name "$vnet_name" --name "$subnet_name" -o tsv --query id)
        az vm create -g "$resource_group" -l "$location" --name "$vm_name" --size "$vm_size" --os-type Linux --attach-os-disk "$disk_name" --subnet "$subnet_id" --public-ip-address "" --only-show-errors || {
            log_error "Failed to create Azure VM."
            exit 1
        }
    fi
    log_success "Azure VM created successfully."
}

# Display help if no arguments are provided
if [ "$#" -eq 0 ]; then
    show_help
fi

# Parse command-line arguments
while getopts ":d:l:r:v:g:n:s:z:h" opt; do
    case $opt in
        d) deployment_type="$OPTARG" ;;
        l) location="$OPTARG" ;;
        r) resource_group="$OPTARG" ;;
        v) vm_name="$OPTARG" ;;
        g) vnet_rg="$OPTARG" ;;
        n) vnet_name="$OPTARG" ;;
        s) subnet_name="$OPTARG" ;;
        z) vm_size="$OPTARG" ;;
        h) show_help ;;
        *)
            log_error "Invalid option: -$OPTARG"
            exit 1
            ;;
    esac

done

# Execute the main workflow
validate_inputs
pre_checks
cleanup_tmp
setup_dependencies
download_datasync
convert_datasync
upload_to_azure
create_vm
