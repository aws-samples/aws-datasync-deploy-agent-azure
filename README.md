# AWS DataSync Deployment for Azure

This repository contains a script designed to convert the DataSync Agent VHDX to VHD  on Amazon Linux 2 (AL2), and upload the generated disk to Azure and create an Azure Virtual Machine. The script can create the DataSync Virtual Machine in a **new** Azure vNet and Subnet or it can also use an **existing** Azure vNET and Subnet. Please review the Parameters section for deployment options.

## Getting Started

To begin the deployment process, ensure that you have the necessary prerequisites in place and are familiar with the configuration parameters required for successful execution.

### Prerequisites

Before running the deployment script, please ensure that you have the following parameters readily available:

#### The following parameters are mandatory

- *Deployment Type (`-d`):* Choose whether you want to use a `new_vnet` or an `existing_vnet`.
- *Location (`-l`):* The Azure region where you want to deploy your resources, such as `eastus`.
- *Resource Group (`-r`):* The name of the Azure Resource Group where the deployed resources will be managed, e.g., `aws-datasync-rg`.
- *Virtual Machine Name (`-v`):* The desired name for the Azure Virtual Machine that will host the AWS DataSync Agent, for example, `datasync-vm`.

#### The following parameters are mandatory when the value of `-d` is `existing_vnet`

- *VNET Resource Group (`-g`):* The name of the Azure Resource Group with the existing VNET, e.g., `existing-vnet-rg`
- *VNET Name (`-n`):* The name of the existing VNET, e.g., `existing-vnet`
- *Subnet Name (`-s`):* The name of the subnet that exists in the VNET, e.g., `existing-subnet`

---

This script has been developed to run on an Amazon Linux 2 AMI and the EC2 instance should have at least 160GB of disk space for the conversion process

![Amazon EC2 Launch Instance](./docs/datasync.png)

### Download the Deployment Script

Run the following command to download the deployment script from the code repository.

`curl -sLO https://raw.githubusercontent.com/aws-samples/aws-datasync-deploy-agent-azure/main/src/bash/datasync.sh`

### Running the Deployment Script

Once you have your parameters ready, you can initiate the deployment script using the following command:

If you would like to deploy the DataSync VM in a new VNET: 

`sudo bash datasync.sh -d new_vnet -l eastus -r aws-datasync-rg -v datasync-vm`

If you would like to deploy the DataSync VM in an existing VNET:

`sudo bash datasync.sh -d existing_vnet -l eastus -r aws-datasync-rg -v datasync-vm -g existing-vnet-rg -n existing-vnet -s existing-subnet`

## Deployment Steps

The deployment script automates several steps to ensure a smooth integration between AWS DataSync and Azure services. Here's a breakdown of the deployment process:

1. *Provide Configuration Parameters:*
   Before executing the script, open it in your preferred editor and provide the necessary configuration parameters. These parameters will be used to customize the deployment according to your requirements.

2. *Install Azure CLI and AzCopy:*
   As a part of the setup process, the script will automatically download and install the Azure Command-Line Interface (CLI) and AzCopy tools. These tools are essential for managing and transferring data within the Azure environment.

3. *Download AWS DataSync Agent for Hyper-V:*
   The script will download the AWS DataSync Agent specifically designed for Hyper-V environments. This agent enables efficient and secure data transfers between your Azure infrastructure and AWS.

4. *Convert VHDX to VHD:*
   Once the AWS DataSync Agent is downloaded, the script will take care of converting the Virtual Hard Disk (VHDX) file to the compatible Hyper-V Disk (HVD) format, ensuring compatibility with Azure.

5. *Azure Authentication:*
   To access and manage your Azure resources, the script will guide you through the authentication process, ensuring secure access to your Azure account.

6. *Create Resource Group:*
   The deployment script will automatically create a dedicated Azure Resource Group using the provided name. This Resource Group will serve as the container for your deployed resources.

7. *Upload VHD as Managed Disk:*
   The script will facilitate the seamless upload of the converted HVD file as a managed disk within the specified Resource Group. This disk will contain the AWS DataSync Agent.

8. *Create Virtual Machine:*
   Leveraging the uploaded managed disk, the script will assist you in creating an Azure Virtual Machine in either a new VNET or an existing VNET. This Virtual Machine will host the AWS DataSync Agent and enable data synchronization between AWS and Azure.

## Clean Up

Once the deployment script has successfully executed and the AWS DataSync Agent is seamlessly integrated with Azure, you can consider cleaning up your environment:

- *Delete Amazon Linux EC2 Instance:*
  The Amazon Linux EC2 instance that was used for the deployment can be safely deleted. The script will have completed its tasks, and the instance is no longer required for the ongoing operation of the integration.

Thank you for using the *AWS DataSync Deployment for Azure* repository. We hope this tool proves valuable in streamlining your data synchronization between AWS and Azure environments.

## Security

See [CONTRIBUTING](CONTRIBUTING.md#security-issue-notifications) for more information.

## License

This library is licensed under the MIT-0 License. See the LICENSE file.
