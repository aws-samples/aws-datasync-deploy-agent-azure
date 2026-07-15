# AWS DataSync Deployment for Azure

This repository contains a script designed to convert the DataSync Agent VHDX to VHD on Amazon Linux 2023 (AL2023), upload the generated disk to Azure and create an Azure Virtual Machine. The script will create the DataSync Virtual Machine in a new Azure vNet and Subnet or it can also use an existing Azure vNET and Subnet. During deployment, you have the option to specify your Azure Subscription ID, which allows the script to deploy the appliance within a specific Azure subscription context. Please review the Parameters section for all deployment options, including how to specify the Subscription ID and other configuration settings.

## Blogs
For more details on migrating Azure Blob Storage to Amazon S3 using AWS DataSync, see the following blog post:

[Migrating Azure Blob Storage to Amazon S3 Using AWS DataSync](https://aws.amazon.com/blogs/storage/migrating-azure-blob-storage-to-amazon-s3-using-aws-datasync/)

For information on moving data from Azure Files SMB shares to AWS using AWS DataSync, check out this blog post:

[How to Move Data from Azure Files SMB Shares to AWS Using AWS DataSync](https://aws.amazon.com/blogs/storage/how-to-move-data-from-azure-files-smb-shares-to-aws-using-aws-datasync/)

## Getting Started

To start the deployment, make sure you have met all the necessary prerequisites and are familiar with the configuration parameters needed for successful execution.

**It is recommended to log in to your Azure account before running the script.** During the script execution, you'll be prompted to enter the authorization code provided in the Azure console to grant the script access to your Azure resources.

## Architecture

The deployment runs from an Amazon Linux 2023 EC2 instance and produces a DataSync agent VM in Azure:

```mermaid
flowchart LR
    subgraph AWS["AWS"]
        EC2["Amazon Linux 2023<br/>EC2 instance"]
        CF["DataSync agent zip<br/>(Hyper-V VHDX)"]
        CF -->|"curl download"| EC2
        EC2 -->|"qemu-img: VHDX to VHD"| VHD["Fixed VHD"]
    end
    subgraph Azure["Azure"]
        DISK["Managed disk"]
        VM["DataSync agent VM<br/>(no public IP)"]
        DISK -->|"attach-os-disk"| VM
        VM --- VNET["New or existing<br/>vNet + subnet"]
    end
    VHD -->|"AzCopy to time-limited SAS"| DISK
```

## Deployment Steps

The deployment script automates the following steps to integrate AWS DataSync with Azure:

1. **Provide Configuration Parameters**: Customize the deployment by specifying required parameters such as deployment type, location, resource group, and VM details.
2. **Install Dependencies**: Automatically installs Azure CLI, AzCopy, and other required tools.
3. **Download and Convert DataSync Agent**: Downloads the AWS DataSync agent and converts it to a VHD format compatible with Azure.
4. **Authenticate with Azure**: Guides you through logging into Azure to manage resources securely and validates the provided Subscription ID (if specified).
5. **Create or Use Resource Group**: Ensures the specified Azure resource group exists or creates it if necessary.
6. **Upload VHD to Azure**: Renames the VHD file to match the Azure VM name and uploads it as a managed disk in Azure.
7. **Create Azure VM**: Deploys an Azure Virtual Machine using the uploaded VHD, supporting both new and existing VNET configurations.

### Prerequisites

Before running the deployment script, please ensure that you have the following and the parameters needed for Azure readily available:
- Amazon Linux 2023 instance with 200GB storage
- Azure permissions to:
  - Create/manage resource groups
  - Create/manage virtual machines
  - Create/manage virtual networks (if using new_vnet deployment)
  - Upload and manage disks

> This script has been developed to run on an Amazon Linux 2023 AMI. The EC2 instance should have at least **200GB** of disk space: the conversion holds the intermediate `.raw` and the final fixed `.vhd` (each roughly 80GB) at the same time, so ~160GB is the bare peak and leaves no headroom. The script pre-checks for at least 170GB free on the work directory and will stop early if there is not enough space. (Amazon Linux 2 reached end of life on June 30, 2026 and should no longer be used.)
>
> **Note:** the script writes its large intermediate files to `/var/tmp` by default (override with the `WORKDIR` environment variable). Do not use `/tmp`, which on Amazon Linux 2023 is a RAM-backed `tmpfs` mount that is far too small.

![Amazon EC2 Launch Instance](./docs/datasync.png)

**Mandatory Parameters:**
- **Deployment Type (-d)**: Choose whether you want to use a ('new_vnet' or 'existing_vnet')
- **Location (-l)**: Azure region where you want to deploy your resources (e.g., 'eastus', 'westus')
- **Resource Group (-r)**: Azure Resource Group name (e.g. aws-datasync-rg)
- **Virtual Machine Name (-v)**: The  name for the Azure Virtual Machine that will host the AWS DataSync Agent (e.g. aws-datasync-vm)
- **Virtual Machine Size (-z)**: Azure VM size (e.g., 'Standard_E4s_v5', 'Standard_E16_v5')

**Optional Parameter:**
- **Subscription ID (-u)**: Azure subscription ID (optional)

**Additional Parameters (when -d is existing_vnet):**
- **VNET Resource Group (-g)**: Virtual network resource group (required for 'existing_vnet')
- **VNET Name (-n)**: Virtual network name (required for 'existing_vnet')
- **Subnet Name (-s)**: (required for 'existing_vnet')

**Display Help Menu**
- **Show help message (-h)**
```
sudo bash datasync.sh -h
```
![Datasync Help Menu options](./docs/deployment-menu-options.png)


When selecting the Azure Virtual Machine for the Datasync Agent, we recommend the following:
- 32 GB of RAM assigned to the VM for task executions working with **up** to 20 million files, objects, or directories.
- 64 GB of RAM assigned to the VM for task executions working with **more** than 20 million files, objects, or directories.  
- For detailed AWS DataSync agent requirements, see the [AWS DataSync Agent Requirements](https://docs.aws.amazon.com/datasync/latest/userguide/agent-requirements.html) documentation.

> **Important — the DataSync agent image is Hyper-V Generation 1 (Gen1).** You must choose a VM
> size that supports Gen1 disks. Newer size families are **Gen2-only** (e.g. the `v7` E/D-series)
> or **confidential-compute only** (e.g. `EC*`/`DC*` sizes, which require a ConfidentialVM/Gen2
> image) and will fail with a `cannot boot Hypervisor Generation '1'` or `security type` error.
> Gen1-capable families such as `Esv3`/`Esv4`/`Esv5` (e.g. `Standard_E4s_v5`) work. If your chosen
> size reports **capacity restrictions** (`SkuNotAvailable`) in your region, try another Availability
> Zone (`az vm create --zone 1|2|3`), or deploy to a different region (`-l eastus2`, `-l westus2`).
> To list Gen1-capable, unrestricted 4-vCPU sizes in a region:
> ```bash
> az vm list-skus --location <region> --resource-type virtualMachines --all \
>   --query "[?length(restrictions)==\`0\` && capabilities[?name=='HyperVGenerations' && contains(value,'V1')] && capabilities[?name=='vCPUs' && value=='4']].name" -o tsv
> ```

---
### Download the Deployment Script
Run the following command to download the deployment script from the code repository:

```
curl -sLO https://raw.githubusercontent.com/aws-samples/aws-datasync-deploy-agent-azure/main/src/bash/datasync.sh
```

> **Before running, review the script.** This sample is executed with `sudo`, so it runs with
> root privileges on your EC2 instance. Open `datasync.sh` and read it before running, and
> for reproducible deployments pin the download to a specific release tag instead of `main`
> (replace `main` in the URL above with the tag you want).

Make the script executable:
```
chmod +x datasync.sh
```
### Running the Deployment Script

Once you have your parameters ready, you can initiate the deployment script using the following commands:

```
sudo bash datasync.sh -d new_vnet -l eastus -r testResourceGroup -v testVM -z Standard_E4s_v5 -u xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
```

Replace `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx` with your actual Azure subscription ID.

For existing_vnet deployment:
```
sudo bash datasync.sh -d existing_vnet -l eastus -r aws-datasync-rg -v datasync-vm -g existing-vnet-rg -n existing-vnet -s existing-subnet -z Standard_E16_v5 -u mySubscriptionId
```
Replace `mySubscriptionId` with your actual Azure subscription ID.

### Subscription ID Validation

The script validates the provided Azure subscription ID to ensure it is correct. If the subscription ID is invalid, the script will log an error and exit. Retrieve the correct subscription ID using the following command in Azure CloudShell:

```
az account list --output table
```
## Azure CLI Login
You will be prompted to login to Azure and allow the script to create the Virtual Machine for the DataSync Appliance

![Azure CLI Login](./docs/Azure-Authentication.png)

Confirm the sign-in request for the Microsoft Azure CLI to grant the script access to your Azure resources:

![Azure CLI Access Confirmation](./docs/Azure-CLI-Access.png)


## Successful deployment to Azure.

![Deployment Successful](./docs/DataSync-VM.png)

## Login Credentials
After the successful deployment of the AWS DataSync agent on the Azure Virtual Machine, you can access the agent using the following default login credentials:

Username: admin   
Password: password

Be sure to use these credentials to log into the DataSync agent and continue the setup and configuration.

> ⚠️ **Security: change the default password immediately.** `admin` / `password` are
> well-known default credentials. On first login, change the password to a strong, unique
> value. Do not expose the agent local console to untrusted or public networks — this script
> deliberately creates the VM **without a public IP** (`--public-ip-address ""`), so reach the
> console over the private vNet or through a bastion host, and restrict the subnet's network
> security group to only the sources that need access.


### Logging
The script includes logging with color-coded output:

- 🔵 INFO
- 🟡 WARNING
- 🔴 ERROR
- 🟢 SUCCESS

## Clean Up

Once the deployment script has successfully executed and the AWS DataSync Agent is deployed on Azure, you can clean up your environment:

1. **Delete the Amazon Linux 2023 EC2 instance.** The EC2 instance used for the deployment can be safely deleted once the script completes — it is only needed for the one-time VHDX→VHD conversion and upload, and is not required for the running agent.

2. **Remove the scratch files on the build instance** (only relevant if you keep the EC2 instance). The conversion leaves large intermediate images (the agent zip and the ~80 GB `.vhd`) in the work directory:
   ```bash
   rm -f "${WORKDIR:-/var/tmp}"/datasync.zip "${WORKDIR:-/var/tmp}"/azcopy.tar.gz "${WORKDIR:-/var/tmp}"/*.vhdx "${WORKDIR:-/var/tmp}"/*.raw "${WORKDIR:-/var/tmp}"/*.vhd
   ```
   (A subsequent run of the script also clears these automatically before starting.)

3. **Delete any orphaned Azure managed disks from failed attempts.** If VM creation failed (for example due to `SkuNotAvailable` capacity errors) and you re-ran the deployment, earlier uploaded disks may be left behind and will continue to incur storage charges. List and delete unattached disks:
   ```bash
   # list disks and their attachment state
   az disk list -g <resource_group> --query "[].{name:name, state:diskState, attachedTo:managedBy}" -o table
   # delete an unattached disk you no longer need
   az disk delete -n <disk_name> -g <resource_group> --yes
   ```

4. **Remove the resource group entirely** if it was created solely for this deployment and you want to tear everything down (VM, disk, and vNet if `new_vnet` was used):
   ```bash
   az group delete --name <resource_group> --yes --no-wait
   ```

Thank you for using the AWS DataSync Deployment for Azure repository. We hope this tool proves valuable in streamlining your data synchronization between AWS and Azure environments.

## Security

When deploying this sample, keep the following in mind:

- **Change the default agent credentials** (`admin` / `password`) on first login. See the
  [Login Credentials](#login-credentials) section.
- **Restrict console network access.** The VM is created without a public IP; keep it that
  way and limit access to the agent console via network security groups and a private path
  (vNet peering / bastion).
- **Delete the build EC2 instance** once deployment completes (see [Clean Up](#clean-up)). It
  is only needed for the one-time VHDX→VHD conversion.
- **Use least-privilege Azure permissions** scoped to the resource group, disk, network, and
  VM operations this script performs.
- **Review the script before running it as root.**

For reporting security issues, see CONTRIBUTING for more information.

## License

This library is licensed under the MIT-0 License. See the LICENSE file.

## About

VHDX to VHD Conversion Tool for AWS DataSync
