#!/bin/bash
# Script to download the AWS DataSync agent for Hyper-V, convert it to a VHD format, and deploy it on an Azure VM
# Runs on Amazon Linux 2023 x86_64 only

set -euo pipefail

# Scratch directory for the (large) intermediate disk images. Defaults to /var/tmp, which is
# disk-backed on Amazon Linux 2023. Do NOT default to /tmp: on AL2023 (and many modern distros)
# /tmp is a tmpfs (RAM-backed) mount capped at a fraction of system memory, which is far too
# small for the ~80 GB raw/VHD images produced here. Override with WORKDIR=/path if needed.
WORKDIR="${WORKDIR:-/var/tmp}"

# Peak scratch space required by the conversion (raw + fixed VHD coexist before cleanup).
# ~170 GB is the documented minimum; require a little headroom.
REQUIRED_WORKDIR_GB=170

# Color definitions for logs
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
GREEN='\033[0;32m'
RED='\033[0;31m'
RESET='\033[0m'

#Tag array
declare -a vm_tags=()

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
    echo "  -z <vm_size>          Azure VM size (e.g., 'Standard_E4s_v5', 'Standard_E16_v5')"
    echo "  -g <vnet_rg>          Virtual network resource group (required for 'existing_vnet')"
    echo "  -n <vnet_name>        Virtual network name (required for 'existing_vnet')"
    echo "  -s <subnet_name>      Subnet name (required for 'existing_vnet')"
    echo "  -u <subscription_id>  Azure subscription ID (optional)"
    echo "  -t <Key=Value>        Tag (repeatable, e.g., -t Env=Prod -t Team=DevOps)"
    echo "  -h                    Show this help message"
    echo
    echo -e "${CYAN}Examples:${RESET}"
    echo "  $0 -d new_vnet -l eastus -r myResourceGroup -v myVM -z Standard_E4s_v5 -u mySubscriptionId"
    echo "  $0 -d existing_vnet -l eastus -r myResourceGroup -v myVM -g myVnetRG -n myVnet -s mySubnet -z Standard_E16_v5 -u mySubscriptionId"
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

    mkdir -p "$WORKDIR" || {
        log_error "Could not create work directory: $WORKDIR"
        exit 1
    }

    if [ ! -w "$WORKDIR" ]; then
        log_error "The work directory is not writable: $WORKDIR"
        exit 1
    fi

    # Warn loudly if the work directory is a tmpfs (RAM-backed) mount — it will not have room
    # for the large intermediate images and the conversion will fail with "No space left".
    if [ "$(stat -f -c %T "$WORKDIR" 2>/dev/null)" = "tmpfs" ]; then
        log_warning "Work directory $WORKDIR is on a tmpfs (RAM-backed) mount and is likely too small. Set WORKDIR=/path to a disk-backed directory with at least ${REQUIRED_WORKDIR_GB} GB free."
    fi

    # Ensure the work directory has enough free space for the conversion.
    avail_gb=$(df -BG --output=avail "$WORKDIR" | tail -1 | tr -dc '0-9')
    if [ -n "${avail_gb:-}" ] && [ "$avail_gb" -lt "$REQUIRED_WORKDIR_GB" ]; then
        log_error "Insufficient free space in $WORKDIR: ${avail_gb} GB available, ${REQUIRED_WORKDIR_GB} GB required. Free up space or set WORKDIR=/path to a larger disk-backed directory."
        exit 1
    fi
}

# Clean up conflicting files in the work directory
function cleanup_tmp() {
    log_info "Cleaning up work directory ($WORKDIR) to avoid conflicts..."
    rm -f "$WORKDIR"/azcopy.tar.gz "$WORKDIR"/datasync.zip
    rm -rf "$WORKDIR"/azcopy_linux_amd64*
    rm -f "$WORKDIR"/*.vhdx "$WORKDIR"/*.raw "$WORKDIR"/*.vhd
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
    # Amazon Linux 2023 uses dnf (RHEL9 family). The Microsoft azure-cli yum repo above is
    # dnf-compatible; qemu-img, jq, and unzip resolve from the AL2023 repositories.
    dnf install -y qemu-img jq unzip azure-cli || {
        log_error "Failed to install dependencies."
        exit 1
    }

    log_info "Downloading AzCopy..."
    curl -fLs "https://aka.ms/downloadazcopy-v10-linux" -o "$WORKDIR"/azcopy.tar.gz
    tar -xf "$WORKDIR"/azcopy.tar.gz -C "$WORKDIR" || {
        log_error "Failed to download or extract AzCopy."
        exit 1
    }
    mv "$WORKDIR"/azcopy_linux_amd64*/azcopy /usr/bin/
    chmod +x /usr/bin/azcopy
    log_success "Dependencies installed successfully."
}

# Download the AWS DataSync agent
function download_datasync() {
    log_info "Downloading AWS DataSync agent for Hyper-V..."
    curl -fL https://d8vjazrbkazun.cloudfront.net/AWS-DataSync-Agent-HyperV.zip -o "$WORKDIR"/datasync.zip || {
        log_error "Failed to download AWS DataSync agent."
        exit 1
    }
    log_success "AWS DataSync agent downloaded successfully."
}

# Convert the downloaded DataSync agent to a VHD format
function convert_datasync() {
    log_info "Converting AWS DataSync agent to VHD format..."
    unzip "$WORKDIR"/datasync.zip -d "$WORKDIR" || {
        log_error "Failed to extract AWS DataSync agent."
        exit 1
    }

    vhdxdisk=$(find "$WORKDIR" -name '*.vhdx' | head -n 1)
    rawdisk=${vhdxdisk//vhdx/raw}
    vhddisk=${vhdxdisk//vhdx/vhd}

    qemu-img convert -f vhdx -O raw "$vhdxdisk" "$rawdisk"

    MB=$((1024 * 1024))
    size=$(qemu-img info -f raw --output json "$rawdisk" | jq -r '."virtual-size"')
    rounded_size=$((((size + MB - 1) / MB) * MB))

    qemu-img resize "$rawdisk" "$rounded_size"
    qemu-img convert -f raw -o subformat=fixed,force_size -O vpc "$rawdisk" "$vhddisk"

    rm "$rawdisk"

    # Rename the VHD file to match the Azure VM name before upload.
    # Move the specific file produced above (not a "$WORKDIR"/*.vhd glob) to stay robust
    # if other .vhd files are ever present in the work directory.
    target_vhd="$WORKDIR/${vm_name}.vhd"
    mv "$vhddisk" "$target_vhd" || {
        log_error "Failed to rename VHD file to match the VM name."
        exit 1
    }
    vhddisk="$target_vhd"

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

    if [ -n "${subscription_id:-}" ]; then
        log_info "Validating Azure subscription: $subscription_id"
        az account show --subscription "$subscription_id" > /dev/null 2>&1 || {
            log_error "Please ensure you entered the correct Azure subscription ID. You can run the command \"az account list --output table\" from Azure CloudShell to provide the subscription ID."
            exit 1
        }
        log_success "Azure subscription ID is valid: $subscription_id"
        az account set --subscription "$subscription_id" || {
            log_error "Please ensure you entered the correct Azure subscription ID. You can run the command \"az account list --output table\" from Azure CloudShell to provide the subscription ID."
            exit 1
        }
    fi

    check_resource_group

    az disk create -n "$disk_name" -g "$resource_group" -l "$location" --os-type Linux --upload-type Upload --upload-size-bytes "$upload_size" --sku Standard_LRS --only-show-errors || {
        log_error "Failed to create Azure disk. Ensure the disk is created with the correct upload type."
        exit 1
    }

    # Verify the disk state before granting SAS access
    disk_state=$(az disk show -n "$disk_name" -g "$resource_group" --query 'diskState' -o tsv)
    if [[ "$disk_state" != "ReadyToUpload" && "$disk_state" != "ActiveUpload" ]]; then
        log_error "Disk is not in a valid state for upload. Current state: $disk_state"
        exit 1
    fi

    # Grant a time-limited (2h) write SAS instead of 24h; access is revoked immediately after
    # the upload below. 2h leaves headroom for a large VHD upload on a slow link while keeping
    # the credential's lifetime far shorter than the previous 86400s (24h).
    # Note: the SAS field is "accessSas" in current Azure CLI; older versions used "accessSAS".
    # Read whichever is present so this works across CLI versions.
    grant_json=$(az disk grant-access -n "$disk_name" -g "$resource_group" --access-level Write --duration-in-seconds 7200) || {
        log_error "Failed to grant SAS access."
        exit 1
    }
    sas_uri=$(echo "$grant_json" | jq -r '.accessSas // .accessSAS // empty')
    if [ -z "$sas_uri" ]; then
        log_error "Could not obtain a SAS URI from 'az disk grant-access'. Response: $grant_json"
        exit 1
    fi

    azcopy copy "$vhddisk" "$sas_uri" --blob-type PageBlob || {
        log_error "Failed to upload VHD to Azure."
        exit 1
    }

    az disk revoke-access -n "$disk_name" -g "$resource_group"
    log_success "VHD uploaded to Azure successfully."
}

# Print actionable guidance for common az vm create failures, then exit.
# $1 = captured az vm create output/error text.
function handle_vm_create_failure() {
    local err="$1"
    log_error "Failed to create Azure VM."
    [ -n "$err" ] && echo -e "${RED}${err}${RESET}"

    if echo "$err" | grep -qi "Hypervisor Generation\|Gen2\|azuregen2vm\|security type"; then
        log_warning "The DataSync agent image is Hyper-V Generation 1 (Gen1). The chosen VM size ('$vm_size') looks Gen2-only or confidential-compute only, which cannot boot a Gen1 disk."
        log_warning "Choose a Gen1-capable size (e.g. an Esv3/Esv4/Esv5 family size such as Standard_E4s_v5) via -z."
    fi

    if echo "$err" | grep -qi "SkuNotAvailable\|Capacity Restrictions\|not available in location\|not available in zone"; then
        log_warning "VM size '$vm_size' is unavailable (capacity/quota) in location '$location'."
        log_warning "Try another region via -l, or find Gen1-capable, unrestricted sizes for your subscription with:"
        echo -e "${YELLOW}  az vm list-skus --location <region> --resource-type virtualMachines --all \\
    --query \"[?length(restrictions)==\\\`0\\\` && capabilities[?name=='HyperVGenerations' && contains(value,'V1')] && capabilities[?name=='vCPUs' && value=='4']].name\" -o tsv${RESET}"
        log_warning "Note: the uploaded disk is in '$location'; deploying to another region requires re-running this script with a new -l (the disk is re-uploaded)."
    fi

    exit 1
}

# Create a new Azure VM using the uploaded VHD
function create_vm() {
    # Build the optional --tags argument from any -t Key=Value flags.
    local tag_args=()
    if [ ${#vm_tags[@]} -gt 0 ]; then
        tag_args=(--tags "${vm_tags[@]}")
    fi

    log_info "Creating Azure VM: $vm_name (size: $vm_size, location: $location)..."
    local output
    if [ "$deployment_type" == "new_vnet" ]; then
        output=$(az vm create -g "$resource_group" -l "$location" --name "$vm_name" --size "$vm_size" --os-type Linux --attach-os-disk "$disk_name" --public-ip-address "" "${tag_args[@]}" --only-show-errors 2>&1) || handle_vm_create_failure "$output"
    else
        subnet_id=$(az network vnet subnet show --resource-group "$vnet_rg" --vnet-name "$vnet_name" --name "$subnet_name" -o tsv --query id)
        output=$(az vm create -g "$resource_group" -l "$location" --name "$vm_name" --size "$vm_size" --os-type Linux --attach-os-disk "$disk_name" --subnet "$subnet_id" --public-ip-address "" "${tag_args[@]}" --only-show-errors 2>&1) || handle_vm_create_failure "$output"
    fi
    log_success "Azure VM created successfully."
}

# Display help if no arguments are provided
if [ "$#" -eq 0 ]; then
    show_help
fi

# Parse command-line arguments
while getopts ":d:l:r:v:g:n:s:z:u:t:h" opt; do
    case $opt in
        d) deployment_type="$OPTARG" ;;
        l) location="$OPTARG" ;;
        r) resource_group="$OPTARG" ;;
        v) vm_name="$OPTARG" ;;
        g) vnet_rg="$OPTARG" ;;
        n) vnet_name="$OPTARG" ;;
        s) subnet_name="$OPTARG" ;;
        z) vm_size="$OPTARG" ;;
        u) subscription_id="$OPTARG" ;;
        t) vm_tags+=("$OPTARG") ;;
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
