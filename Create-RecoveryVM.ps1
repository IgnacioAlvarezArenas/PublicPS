#################### Create-RecoveryVM.ps1 #################################
##### This script is intended to create a recovery VM for###################
##### Windows VMs and mount the OS disk of the broken VM for further #######
##### troubleshooting like restoring Last Known Good Config ################
############################################################################

<#
.SYNOPSIS

DISCLAIMER: all the operations of the functions of the script have cost associated.
   
This script is intended to create a RecoveryVM to troubleshoot Windows VM Issues

.DESCRIPTION
    Script can perform following tasks
    
         1) Create recovery VM
         
         By doing this, a VM called RecoveryVM-MS will be created. OS Disk of damaged VM will be mounted as data disk. Snapshot and backup disk will be created
                                                                                  
         2) Restore VM Disk
         
         This function will perform an OS Swap between the backup OS disk of the damaged VM and the disk that was fixed on the recovery VM
                                                                               
         3) Clean up Recovery VM

         This function will delete the recoveryVM, all associated objects (public IP,NIC and all the snapshots of the damaged VM).
                  

 .PARAMETER VMName
    Name of the VM which is currently not working (damaged VM)
.EXAMPLE
    C:\PS> Create-RecoveryVM.ps1 -vmname YOURVMNAME
    
.NOTES
    Author: Azure CXP
#>

#### Function to Create RecoveryVM ####
param(
        [Parameter(Mandatory)][string]$VMName
      )

function CreateRecoveryVM{
 
param(
        [Parameter(Mandatory)][string]$VMName
      )

write-host ""
write-host ""
write-host "This is the list of operations done by this script" -ForegroundColor Yellow
write-host "1) $vmname will be stopped" -ForegroundColor Yellow
write-host "2) $vmname OS disk will get an snapshot taken" -ForegroundColor Yellow
write-host "3) $vmname will get swapped OS disk for a new one from the snapshot in order to proceed with the mount of the old disk in Recovery VM" -ForegroundColor Yellow
write-host "4) All the information from the console of this script will be kept in a txt file in the running directory for debugging purposes" -ForegroundColor Yellow


$transcriptname=".\"+$vmname+"-CreateRecoveryVM-"+$(get-date -f yyyy-MM-dd-HHmmss)+".txt"
Start-Transcript -Path $transcriptname 


##### Obtaining current information of Broken VM and preparing prerequisites of new VM.

    try{
       $VM=get-azvm -Name $VMName
       }
    catch{write-host "VM not found, exiting script" -ForegroundColor red;stop-transcript;exit}


$location=$VM.location
$RG=$vm.ResourceGroupName
$size="Standard_D2s_v3"

    try {
        $nic=Get-AzNetworkInterface -ResourceId $vm.networkprofile.networkinterfaces.id
        }
    catch{write-host "Could not obtain network information of VM, please review. Exitting Script" -ForegroundColor red;stop-transcript; exit}

    try{
        $vnetname=$nic.IpConfigurations.Subnet.Id.Split("/")[8]
        $subnetname=$nic.IpConfigurations.Subnet.Id.Split("/")[10]
        $vnet=get-azvirtualnetwork -Name $vnetname
        $subnet=Get-azvirtualnetworksubnetconfig -name $subnetname -VirtualNetwork $vnet
        }
    catch{write-host "Could not obtain subnet information of VM, please review. Exitting script" -ForegroundColor red;stop-transcript; exit} 

    try{
        $disk=get-azdisk -Name $vm.storageprofile.osdisk.name
        }
    catch{write-host "Could not retrieive disk information. Please review" -ForegroundColor Red;stop-transcript; exit}

####### This section of code decides if it is being used a Windows Marketplace Image or a custom image. If it is a custom image,
####### it is required to select the OS. It does not really matter, but it can be useful to have the same OS in recovery VM to doublecheck configs


######## Stopping VM 
write-host ""
write-host ""
write-host "Stopping VM $vmname to perform all the operations" -ForegroundColor Yellow

$vmstatus=get-azvm -Name $vmname -status -WarningAction SilentlyContinue
if($vmstatus.powerstate -like 'running')
{

    try{
    stop-azvm -Name $vmname -ResourceGroupName $RG -WarningAction SilentlyContinue
       }
    catch{write-host "VM $vmname could not be stopped. Please review. Exitting script";stop-transcript;exit}

}

######### Creating Snapshot of current VM Disk
write-host ""
write-host ""
write-host "Taking Snapshot of $vmname" -ForegroundColor Yellow
$snapshotname=$vmname + "-RecoverySnapshot-"+$(get-date -f yyyy-MM-dd-HHmmss)
$snapshot =  New-AzSnapshotConfig -SourceUri $vm.StorageProfile.OsDisk.ManagedDisk.Id -Location $location -CreateOption copy -WarningAction SilentlyContinue
New-Azsnapshot -SnapshotName $snapshotname -Snapshot $snapshot -ResourceGroupName $RG -WarningAction SilentlyContinue | out-null 


######### Creating disk from snapshot
$snapshot=get-azsnapshot -ResourceGroupName $RG -SnapshotName $snapshotname
$diskconfig=new-azdiskconfig -SkuName $disk.sku.name -location $location -CreateOption Copy -SourceResourceId $snapshot.id -WarningAction SilentlyContinue
$diskname="Disk-"+$snapshotname
new-azdisk -DiskName $diskname -ResourceGroupName $RG -Disk $diskconfig  -WarningAction SilentlyContinue| out-null

#### Swapping OS Disk 
$backupdisk = Get-AzDisk -ResourceGroupName $RG -Name $diskname
Set-AzVMOSDisk -VM $vm -ManagedDiskId $backupdisk.Id -Name $backupdisk.Name -WarningAction SilentlyContinue | out-null
Update-AzVM -ResourceGroupName $RG -VM $vm | out-null

#######################
### Creating RecoveryVM
#######################
### Creating new network objects (Public IP and network interface)

$publicIpname="rvmpublicip-"+$(get-date -f yyyy-MM-dd-HHmmss)

    try{
    $publicIp = New-AzPublicIpAddress -Name $publicIpName -ResourceGroupName $RG -Location $location -AllocationMethod Dynamic
        }
    catch{write-host "New Public IP address could not be created, please assign one manually" -ForegroundColor red}

    $nicname="rvm-nic1"+$(get-date -f yyyy-MM-dd-HHmmss)

    try{
    $rvmnic = New-AzNetworkInterface -Name $nicname  -ResourceGroupName $RG -Location $location -SubnetId $subnet.id -PublicIpAddressId $PublicIP.id
    }
    catch{write-host "Recovery VM Network Interface could not be created. Please run the script again." -ForegroundColor red;stop-transcript;exit}

##### Setting up Disk and OS information before VM Creation. It depends on the image, if it is a custom image it requires to findout the OS##########
write-host ""
write-host ""
write-host "Please enter new admin credentials for the RECOVERYVM" -ForegroundColor Yellow
write-host "Password must have 3 of the following: 1 lower case character, 1 upper case character, 1 number, and 1 special character." -ForegroundColor Yellow
write-host "The value must be between 12 and 123 characters long." -ForegroundColor Yellow
$credential=get-credential
$vmconfig=new-azvmconfig -vmname "RECOVERYVM-MS" -vmsize $size -WarningAction SilentlyContinue


    if($vm.storageprofile.ImageReference.Publisher -like "*Windows*")
       {
        
        $recoveryvm=Set-AzVMSourceImage -VM $vmconfig -PublisherName $vm.storageprofile.imagereference.publisher -offer $vm.storageprofile.imagereference.offer -Skus $vm.StorageProfile.ImageReference.Sku -Version $vm.StorageProfile.ImageReference.Version
        $recoveryvm = Set-AzVMOperatingSystem -VM $recoveryvm -Windows -ComputerName "RECOVERYVM-MS" -Credential $Credential -ProvisionVMAgent
        $recoveryvm=Add-AzVMNetworkInterface -VM $recoveryvm -id $rvmnic.Id
        $recoveryvm=add-azvmdatadisk -vm $recoveryvm -createoption attach -ManagedDiskId $disk.id -lun -0
       }
    else{
        write-host "Please enter the version of your OS (2012/2016/2019)":
        $OSSelection=read-host
        
            while(!(($OSSelection -like "2012") -or ($OSSelection -like "2016") -or ($OSSelection -like "2019")))
            {
             write-host "Your selection is not valid.Please type one of these three options:2012/2016/2019. Example: 2012" -ForegroundColor Yellow
             $OSSelection=Read-Host
             
            }

            switch($OSSelection)
            {
            2012 {$OSImage="2012-R2-Datacenter"}
            2016 {$OSImage="2016-Datacenter"}
            2019 {$OSImage="2019-Datacenter"}               
            }

        
        $recoveryvm = Set-AzVMSourceImage -VM $vmconfig -PublisherName 'MicrosoftWindowsServer' -Offer 'WindowsServer' -Skus $OSImage -Version latest
        $recoveryvm = Set-AzVMOperatingSystem -VM $recoveryvm -Windows -ComputerName "RECOVERYVM-MS" -Credential $Credential -ProvisionVMAgent
        $recoveryvm=Add-AzVMNetworkInterface -VM $recoveryvm -id $rvmnic.Id
        $recoveryvm=add-azvmdatadisk -vm $recoveryvm -createoption attach -ManagedDiskId $disk.id -lun -0
        
        }
    
write-host ""
write-host ""
write-host "Creating new VM" -ForegroundColor Green

try{
    new-azvm -ResourceGroupName $RG -location $location -VM $recoveryvm
   }
catch{write-host "New VM creation $Vmname failed. Please use the resources listed above to recreate it manually." -ForegroundColor red}
    
write-host "Installing Hyper-V on Recovery VM. It will be rebooted." -ForegroundColor Yellow
   

try{
   Restart-AzVM -Name "RECOVERYVM-MS" -ResourceGroupName $RG -WarningAction SilentlyContinue
   $protectedSettings = @{"commandToExecute" = 'powershell -ExecutionPolicy Unrestricted -command "Install-WindowsFeature -Name Hyper-V -IncludeManagementTools -Restart"'};
   $recoveryvm=Set-AzVMExtension -ResourceGroupName $RG -Location $location -VMName "RECOVERYVM-MS" -Name "InstallHyperV" -Publisher "Microsoft.Compute" -ExtensionType "CustomScriptExtension" -TypeHandlerVersion "1.10" -ProtectedSettings $protectedSettings
    }
catch{write-host "Could not enable VMEXtension to install Hyper-V. Please install Hyper-v manually" -ForegroundColor red}    

Stop-Transcript
}

function RemoveRecoveryVM{

param(
        [Parameter(Mandatory)][string]$VMName
      )

write-host ""
write-host "DISCLAIMER: Proceed with this process only if the damaged VM has been completely recovered" -ForegroundColor red
write-host ""
write-host ""
write-host "Script will remove:" -ForegroundColor Yellow
Write-Host "1) VM RecoveryVM-MS" -ForegroundColor Yellow
write-host "2) DISK, NIC and Public IP associated to RecoveryVM-MS" -ForegroundColor Yellow
write-host "3) All Snapshots named RecoverySnapshot" -ForegroundColor Yellow
write-host ""

$transcriptname=".\"+$vmname+"-RemoveRecoveryVM-"+$(get-date -f yyyy-MM-dd-HHmmss)+".txt"
Start-Transcript -Path $transcriptname 

try{

    $vm=get-azvm -Name "RECOVERYVM-MS"
    $damagedvm=get-azvm -Name $vmname
    }
catch {write-host "Could not retrieve RECOVERYVM-MS or $vmname, exitting script. Please review if it was deleted manually" -ForegroundColor red; stop-transcript;exit}

$location=$VM.location
$RG=$vm.ResourceGroupName
$snapshots=Get-AzSnapshot |? {$_.name -like "*recoverysnapshot*"}
$nic=Get-AzNetworkInterface -ResourceId $vm.networkprofile.networkinterfaces.id
$publicipname=$nic.IpConfigurations.publicipaddress.id.Split("/")[8]

write-host "Stopping Recovery VM" -ForegroundColor Yellow


try{
    stop-azvm -ResourceGroupName $RG -Name "RECOVERYVM-MS" -WarningAction SilentlyContinue
   }
catch{write-host "Could not stop RECOVERYVM-MS, exitting script." -ForegroundColor red; stop-transcript;exit}

write-host ""
write-host ""
write-host "Removing VM RecoveryVM-MS" -ForegroundColor Yellow

try {
    remove-azvm -Name "RECOVERYVM-MS" -ResourceGroupName $RG -WarningAction SilentlyContinue
    }
catch{write-host "Could not remove RECOVERYVM-MS, exitting script." -ForegroundColor red;stop-transcript;exit}

write-host ""
write-host ""
write-host "Removing NIC of RECOVERYVM-MS: " $nic.id -ForegroundColor Yellow

try {
    $nicname=$nic.name
    Remove-AzNetworkInterface -Name $nic.name -ResourceGroupName $RG -WarningAction SilentlyContinue
    }
catch{write-host "Could not remove $nicname, please remove it manually" -ForegroundColor Red}

write-host ""
write-host "Removing Public IP of Recovery VM: $publicipname" -ForegroundColor Yellow

try {
     Remove-AzPublicIpAddress -Name $publicipname -ResourceGroupName $RG -WarningAction SilentlyContinue
    }
catch{write-host "Could not remove $nicname, please remove it manually" -ForegroundColor Red}

write-host ""
write-host "Removing OS Disk of RECOVERYVM-MS" -ForegroundColor Yellow

try {
    Remove-AzDisk -DiskName $vm.storageprofile.osdisk.name -ResourceGroupName $RG
    }
catch{write-host "Could not remove disk from RECOVERYVM-MS, please remove it manually" -ForegroundColor red}


write-host
write-host "Removing all recovery snapshots from damaged VM $vmname" -ForegroundColor Yellow

foreach($snap in $snapshots)
    {
    write-host "Removing snapshot " $snap.name -ForegroundColor Yellow
     try{
        
        Remove-AzSnapshot -SnapshotName $snap.name -ResourceGroupName $RG -WarningAction SilentlyContinue
        }
     catch{Write-host "Could not remove snapshots called recoverysnapshot. Please remove them manually if required" -ForegroundColor red}

     }
     
$snapshotdiskname="Disk-"+$VMName
$snapshotdisk=get-azdisk | ? {$_.name -like "*$snapshotdiskname*" }     
$snapshotdiskfinalname=$snapshotdisk.Name

write-host "Leaving disk $snapshotdiskfinalname not deleted as a possible backup. Please remove it manually once incident is resolved." -ForegroundColor Yellow
Stop-Transcript
}

function RestoreDisk{

param(
        [Parameter(Mandatory)][string]$VMName
      )

$transcriptname=".\"+$vmname+"-RestoreDisk-"+$(get-date -f yyyy-MM-dd-HHmmss)+".txt"
Start-Transcript -Path $transcriptname 

$vm=get-azvm -Name $vmname

try{
$recoveryvm=get-azvm -Name recoveryvm-ms
    }
catch{write-host "RecoveryVM could not be retrieved. Please review if VM exists" -ForegroundColor red;stop-transcript;exit}

write-host "Detaching disk from RecoveryVM-MS" -ForegroundColor Yellow

try{
$recovereddisk=get-azdisk -DiskName $recoveryvm.storageprofile.datadisks.name
    }
catch{write-host "Recovered disk could not be found. Review if disk is attached to recovery VM" -ForegroundColor red; stop-transcript;exit}

try{
Remove-AzVMDataDisk -VM $recoveryvm -Name $recoveryvm.storageprofile.datadisks.name | out-null
Update-AzVM -ResourceGroupName $recoveryvm.ResourceGroupName -VM $recoveryvm 
   }
catch{write-host "Recovered disk could not be detached from RecoveryVM. Please review" -ForegroundColor red;stop-transcript; exit}

write-host "Swapping OSDisk on $vmname with the recovered disk" -ForegroundColor Yellow
try{
Set-AzVMOSDisk -VM $vm -ManagedDiskId $recovereddisk.Id -Name $recovereddisk.name | out-null
Update-AzVM -ResourceGroupName $vm.ResourceGroupName -VM $vm | out-null
    }
catch{write-host "Swap of OS Disk failed, please investigate or do it manually" -ForegroundColor red;stop-transcript;exit}

Stop-Transcript
    }
    

write-host ""
write-host ""
write-host "DISCLAIMER: Be aware that this script is intended to create a recovery VM in your environment, having cost associated to it." -ForegroundColor Red 
write-host "Please select what operation you want to proceed with:"
write-host "1. Create RecoveryVM and attach OS Disk for further investigation. OS Disk snapshot will be taken for backup." -ForegroundColor Yellow
write-host "2. Restore Disk (Swap OS Disk). Perform this operation after the disk was fixed on Recovery VM" -ForegroundColor Yellow
write-host "3. Delete RecoveryVM and all its objects. Disk used as backup will remain, will have to be deleted manually" -ForegroundColor Yellow
write-host "Please select an option (1,2,3):" -ForegroundColor Yellow
$selection=read-host

if($selection -eq "1" -or $selection -eq "2" -or $selection -eq "3")
{
    switch($selection)
        {
        1 {CreateRecoveryVM -VMName $vmname}
        2 {RestoreDisk -VMName $vmname}
        3 {RemoveRecoveryVM -VMName $vmname}
        }
}
else
{
write-host "Selection is not correct. Please select one option by typing the number of the option (1,2,3) and press Enter" -ForegroundColor red
}
