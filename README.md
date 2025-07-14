# AWS DataSync Deployment for Azure

This repository contains a script designed to convert the DataSync Agent VHDX to VHD on Amazon Linux 2 (AL2), upload the generated disk to Azure and create an Azure Virtual Machine. The script will create the DataSync Virtual Machine in a new Azure vNet and Subnet or it can also use an existing Azure vNET and Subnet. Please review the Parameters section for deployment options.

This repository contains a script designed to convert the DataSync Agent VHDX to VHD on Amazon Linux 2 (AL2), upload the generated disk to Azure and create an Azure Virtual Machine. The script will create the DataSync Virtual Machine in a new Azure vNet and Subnet or it can also use an existing Azure vNET and Subnet. During deployment, you have the option to specify your Azure Subscription ID, which allows the script to deploy the appliance within a specific Azure subscription context. Please review the Parameters section for all deployment options, including how to specify the Subscription ID and other configuration settings.

## Blogs
For more details on migrating Azure Blob Storage to Amazon S3 using AWS DataSync, see the following blog post:

[Migrating Azure Blob Storage to Amazon S3 Using AWS DataSync](https://aws.amazon.com/blogs/storage/migrating-azure-blob-storage-to-amazon-s3-using-aws-datasync/)

For information on moving data from Azure Files SMB shares to AWS using AWS DataSync, check out this blog post:

[How to Move Data from Azure Files SMB Shares to AWS Using AWS DataSync](https://aws.amazon.com/blogs/storage/how-to-move-data-from-azure-files-smb-shares-to-aws-using-aws-datasync/)

## Getting Started

To start the deployment, make sure you have met all the necessary prerequisites and are familiar with the configuration parameters needed for successful execution.

**It is recommended to log in to your Azure account before running the script.** During the script execution, you'll be prompted to enter the authorization code provided in the Azure console to grant the script access to your Azure resources.

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
- Amazon Linux 2 instance with 160GB storage
- Azure permissions to:
  - Create/manage resource groups
  - Create/manage virtual machines
  - Create/manage virtual networks (if using new_vnet deployment)
  - Upload and manage disks

> This script has been developed to run on an Amazon Linux 2 AMI and the EC2 instance should have at least 160GB of disk space for the conversion process

![Amazon EC2 Launch Instance](./docs/datasync.png)

**Mandatory Parameters:**
- **Deployment Type (-d)**: Choose whether you want to use a ('new_vnet' or 'existing_vnet')
- **Location (-l)**: Azure region where you want to deploy your resources (e.g., 'eastus', 'westus')
- **Resource Group (-r)**: Azure Resource Group name (e.g. aws-datasync-rg)
- **Virtual Machine Name (-v)**: The  name for the Azure Virtual Machine that will host the AWS DataSync Agent (e.g. aws-datasync-vm)
- **Virtual Machine Size (-z)**: Azure VM size (e.g., 'Standard_E4s_v3', 'Standard_E16_v5')

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

---
### Download the Deployment Script
Run the following command to download the deployment script from the code repository:

```
curl -sLO https://raw.githubusercontent.com/aws-samples/aws-datasync-deploy-agent-azure/main/src/bash/datasync.sh
```
Make the script executable:
```
chmod +x datasync.sh
```
### Running the Deployment Script

Once you have your parameters ready, you can initiate the deployment script using the following commands:

```
sudo bash datasync.sh -d new_vnet -l eastus -r testResourceGroup -v testVM -z Standard_E4s_v3 -u xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
```

Replace `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx` with your actual Azure subscription ID.

For existing_vnet deployment:
```
sudo bash datasync.sh -d existing_vnet -l eastus -r aws-datasync-rg -v datasync-vm -g existing-vnet-rg -n existing-vnet -s existing-subnet -z Standard_E16_v5 -u mySubscriptionId
```
Replace `subscription-id` with your actual Azure subscription ID.

### Subscription ID Validation

The script validates the provided Azure subscription ID to ensure it is correct. If the subscription ID is invalid, the script will log an error and exit. Retrieve the correct subscription ID using the following command in Azure CloudShell:

```
az account list --output table
```
## Azure CLI Login
You will be prompted to login to Azure and allow the script to create the Virtual Machine for the DataSync Appliance

![Azure CLI Login](./docs/Azure-Authentication.png)


## Successful deployment to Azure.

![Deployment Successful](./docs/DataSync-VM.png)

## Login Credentials
After the successful deployment of the AWS DataSync agent on the Azure Virtual Machine, you can access the agent using the following default login credentials:

Username: admin   
Password: password

Be sure to use these credentials to log into the DataSync agent and continue the setup and configuration.


### Logging
The script includes logging with color-coded output:

- 🔵 INFO
- 🟡 WARNING
- 🔴 ERROR
- 🟢 SUCCESS

## Clean Up

Once the deployment script has successfully executed and the AWS DataSync Agent is deployed on Azure, you can clean up your environment:

1. Delete Amazon Linux EC2 Instance: The Amazon Linux EC2 instance that was used for the deployment can be safely deleted. The script will have completed its tasks, and the instance is no longer required for the ongoing operation of the integration.

Thank you for using the AWS DataSync Deployment for Azure repository. We hope this tool proves valuable in streamlining your data synchronization between AWS and Azure environments.

## Security

See CONTRIBUTING for more information.

## License

This library is licensed under the MIT-0 License. See the LICENSE file.

## About

VHDX to VHD Conversion Tool for AWS DataSync
