#################### Create-RecoveryVM.ps1 #################################
##### This script is intended to create a recovery VM for###################
##### Windows VMs and mount the OS disk of the broken VM for further #######
##### troubleshooting like restoring Last Known Good Config ################
############################################################################

<#
.SYNOPSIS

DISCLAIMER: all the operations of the functions of the script have cost associated.
   
This script is intended to create a RecoveryVM to troubleshoot Windows VM Issues

.PREREQUISITES
   
-Internet connection from Azure VM is required for some operations
-This script only supports managed disks VMs

.DESCRIPTION
    Script can perform following tasks
    
         1) Create recovery VM
         
         By doing this, a VM called RecoveryVM-MS will be created in a new VNET/subnet dedicated for it. OS Disk of damaged VM will be mounted as data disk. Snapshot and backup disk will be created for the damaged VM

         2) Create Recovery VM and Restore Last Known Good Configuration (Internet connection needed)

         By doing this, a VM called RecoveryVM-MS will be created in a new VNET/subnet dedicated for it. OS Disk of damaged VM will be mounted as data disk. Snapshot and backup disk will be created for the damaged VM
         Last known good configuration will be applied on the damaged VM and disk will be swapped back to start the VM.
                                                                                
         3) Restore VM Disk
         
         This function will perform an OS Swap between the backup OS disk of the damaged VM and the disk that was fixed on the recovery VM
                                                                               
         4) Clean up Recovery VM

         This function will delete the recoveryVM, all associated objects (Recovery resource group, recovery VNET, public IP,NIC and all the snapshots of the damaged VM). 
         VM backup disk created will remain as a backup method. Will need to be deleted manually
                  

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
        [Parameter(Mandatory)][string]$VMName,
        [bool]$lastknowngood=$false
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
    $size="Standard_D2s_v3"
    $RG=new-azresourcegroup -name recoveryrg -Location $location
    $RG=(get-azresourcegroup -name recoveryrg -location $location).ResourceGroupName
    $vmRG=$vm.ResourceGroupName

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
if($vmstatus.powerstate -like '*running*')
{

    try{
    stop-azvm -Name $vmname -ResourceGroupName $vmRG -WarningAction SilentlyContinue
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
$snapshotdiskname="Disk-"+$snapshotname
new-azdisk -DiskName $snapshotdiskname -ResourceGroupName $vmRG -Disk $diskconfig  -WarningAction SilentlyContinue| out-null

#### Swapping OS Disk 
$backupdisk = Get-AzDisk -ResourceGroupName $vmRG -Name $snapshotdiskname
Set-AzVMOSDisk -VM $vm -ManagedDiskId $backupdisk.Id -Name $backupdisk.Name -WarningAction SilentlyContinue | out-null
Update-AzVM -ResourceGroupName $vmRG -VM $vm | out-null

#######################
### Creating RecoveryVM
#######################
### Creating new network objects (RecoveryVNET and subnet, Public IP and network interface)



$publicIpname="rvmpublicip-"+$(get-date -f yyyy-MM-dd-HHmmss)
$vnetname="RecoveryVNET-MS"
$subnetname="RecoveryVNET-MS-subnet1"
$nicname="rvm-nic1"+$(get-date -f yyyy-MM-dd-HHmmss)

write-host ""
write-host "Creating network resources for RecoveryVM-MS." -ForegroundColor Yellow
write-host "VNET:$vnetname" -ForegroundColor Yellow
write-host "Subnet:$subnetname" -ForegroundColor Yellow
write-host "Public IP:$publicipname" -ForegroundColor Yellow
write-host "NIC:$nicname"  -ForegroundColor Yellow
write-host "" 

    try{

       $vnet = New-AzVirtualNetwork -ResourceGroupName $RG -Location $location -name $vnetname -AddressPrefix 192.168.150.0/24 -WarningAction SilentlyContinue
       $subnetConfig = Add-AzVirtualNetworkSubnetConfig -Name $subnetname -AddressPrefix 192.168.150.0/24 -VirtualNetwork $vnet -WarningAction SilentlyContinue
       $vnet | Set-AzVirtualNetwork | out-null
        }
    catch{write-host "Could not create VNET RecoveryVNET-MS and subnet RecoveryVNET-MS-subnet1 to host Recovery VM. Exitting script" -ForegroundColor red;stop-transcript;exit}

    try{
        $publicIp = New-AzPublicIpAddress -Name $publicIpName -ResourceGroupName $RG -Location $location -AllocationMethod Dynamic
        }
    catch{write-host "New Public IP address could not be created, please assign one manually" -ForegroundColor red}

        $vnet=get-azvirtualnetwork -Name $vnetname
        $subnet=Get-azvirtualnetworksubnetconfig -name $subnetname -VirtualNetwork $vnet

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
        
        if($vm.StorageProfile.ImageReference.Sku -like "*2012*")
        {$version="9600.19652.2003081959"}
        elseif($vm.StorageProfile.ImageReference.Sku -like "*2016*")
        {$version="2016.127.20190416"}
        elseif($vm.StorageProfile.ImageReference.Sku -like "*2019*")
        {$version="2019.0.20190410"}

        $recoveryvm=Set-AzVMSourceImage -VM $vmconfig -PublisherName $vm.storageprofile.imagereference.publisher -offer $vm.storageprofile.imagereference.offer -Skus $vm.StorageProfile.ImageReference.Sku -Version $version
        $recoveryvm = Set-AzVMOperatingSystem -VM $recoveryvm -Windows -ComputerName "RECOVERYVM-MS" -Credential $Credential -ProvisionVMAgent
        $recoveryvm=Add-AzVMNetworkInterface -VM $recoveryvm -id $rvmnic.Id
        $recoveryvm = Set-AzVMBootDiagnostic -VM $recoveryvm -Disable
        $recoveryvm=add-azvmdatadisk -vm $recoveryvm -createoption attach -ManagedDiskId $disk.id -lun -0
       }
    else{
        write-host "Please enter the version of your OS (2012/2016/2019):" 
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
        $recoveryvm = Set-AzVMBootDiagnostic -VM $recoveryvm -Disable
        $recoveryvm=add-azvmdatadisk -vm $recoveryvm -createoption attach -ManagedDiskId $disk.id -lun -0
        
        }
    
write-host ""
write-host ""
write-host "Creating new VM" -ForegroundColor Green

new-azvm -ResourceGroupName $RG -location $location -VM $recoveryvm
$recoveryvmtest=get-azvm -Name recoveryvm-ms

##### Managing VM CReation failure
if($recoveryvmtest -eq $null)
{
      write-host "New VM creation RecoveryVM-MS failed. Please proceed with manual creation or review errors above." -ForegroundColor red
      write-host ""
     
      write-host "Swapping back disk per VM Creation Fail" -ForegroundColor Red
      start-sleep 200

      $disk=get-azdisk -Name $disk.name
            
      Set-AzVMOSDisk -VM $vm -ManagedDiskId $disk.Id -Name $disk.name | out-null
      Update-AzVM -ResourceGroupName $vm.ResourceGroupName -VM $vm | out-null
      

      write-host ""
      write-host "Deleting resource group RecoveryRG" -ForegroundColor Red
      remove-azresourcegroup -Name RecoveryRG -force
      stop-transcript
      exit

}
 
####### Installing Hyper-V role if it is required for further troubleshooting   
write-host "Installing Hyper-V on Recovery VM. It will be rebooted." -ForegroundColor Yellow
 
try{
   

   if($vm.StorageProfile.ImageReference.Sku -like "*2012*" -or $OSImage -like "2012-r2-datacenter")
       {
       $protectedSettings = @{"commandToExecute" = 'powershell -ExecutionPolicy Unrestricted -command "Enable-WindowsOptionalFeature –Online -FeatureName Microsoft-Hyper-V –All -NoRestart;Install-WindowsFeature RSAT-Hyper-V-Tools -IncludeAllSubFeature;shutdown /r /f /t 0"'};
       $recoveryvm=Set-AzVMExtension -ResourceGroupName $RG -Location $location -VMName "RECOVERYVM-MS" -Name "InstallHyperV" -Publisher "Microsoft.Compute" -ExtensionType "CustomScriptExtension" -TypeHandlerVersion "1.10" -ProtectedSettings $protectedSettings
       }
   else{
        $protectedSettings = @{"commandToExecute" = 'powershell -ExecutionPolicy Unrestricted -command "Install-WindowsFeature -Name Hyper-V -IncludeManagementTools -Restart"'};
        $recoveryvm=Set-AzVMExtension -ResourceGroupName $RG -Location $location -VMName "RECOVERYVM-MS" -Name "InstallHyperV" -Publisher "Microsoft.Compute" -ExtensionType "CustomScriptExtension" -TypeHandlerVersion "1.10" -ProtectedSettings $protectedSettings
   
       }
    }
catch{write-host "Could not enable VMEXtension to install Hyper-V. Please install Hyper-v manually" -ForegroundColor red}    



if($lastknowngood -eq $true)
{
    try{

    ###removing the previous extension for installing Hyper-V
    Remove-AzVMExtension -ResourceGroupName $RG -Name "InstallHyperV" -VMName "RecoveryVM-MS" -WarningAction SilentlyContinue -Force | out-null

    ### Adding the extension 

    write-host "Restoring last known good configuration in VM $vmname" -ForegroundColor Yellow
    write-host "WARNING: THIS OPERATION WILL FAIL WITHOUT INTERNET CONNECTIVITY FROM THE VM $vmname" -ForegroundColor Yellow

    $URI="https://raw.githubusercontent.com/IgnacioAlvarezArenas/PublicPS/master/LastKnownGood.ps1"
    $settings = @{"fileUris"= @($URI);"commandToExecute" = 'powershell -ExecutionPolicy Unrestricted -file .\lastknowngood.ps1"'};
    $recoveryvm=Set-AzVMExtension -ResourceGroupName $RG -Location $location -VMName "RECOVERYVM-MS" -Name "LastKnownGoodConfig" -Publisher "Microsoft.Compute" -ExtensionType "CustomScriptExtension" -TypeHandlerVersion "1.10" -Settings $settings
       }
    catch
        {
        write-host "Could not enable VMEXtension to restore Last Known Good Config. Check Internet connection and review the extension logs in Recovery VM." -ForegroundColor red
        write-host "Last Known Good Configuration script can be found at: https://github.com/IgnacioAlvarezArenas/PublicPS/blob/master/LastKnownGood.ps1" -ForegroundColor Yellow
        stop-transcript;exit
        }    


}

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
write-host "2) DISK, VNET, NIC and Public IP associated to RecoveryVM-MS" -ForegroundColor Yellow
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


write-host "The following resources will be removed:" -ForegroundColor Yellow
write-host "NIC: " $nic.name -ForegroundColor Yellow
write-host "PublicIP: $publicipname" -ForegroundColor Yellow
write-host "snapshots: " $snapshots.name -ForegroundColor Yellow
write-host "VNET: RecoveryVNET-MS" -ForegroundColor Yellow
write-host "Resource group: RecoveryRG" -ForegroundColor Yellow
write-host "Do you agree to remove all the following resources? (yes/no)" -ForegroundColor Yellow

$answer=read-host

if($answer -like "yes" -or $answer -like "y")
{

write-host "Stopping Recovery VM" -ForegroundColor Yellow


try{
    stop-azvm -ResourceGroupName $RG -Name "RECOVERYVM-MS" -WarningAction SilentlyContinue -Force
   }
catch{write-host "Could not stop RECOVERYVM-MS, exitting script." -ForegroundColor red; stop-transcript;exit}

write-host ""
write-host ""
write-host "Removing VM RecoveryVM-MS" -ForegroundColor Yellow

try {
    remove-azvm -Name "RECOVERYVM-MS" -ResourceGroupName $RG -WarningAction SilentlyContinue -Force
    }
catch{write-host "Could not remove RECOVERYVM-MS, exitting script." -ForegroundColor red;stop-transcript;exit}

write-host ""
write-host ""
write-host "Removing NIC of RECOVERYVM-MS: " $nic.id -ForegroundColor Yellow

try {
    $nicname=$nic.name
    Remove-AzNetworkInterface -Name $nic.name -ResourceGroupName $RG -WarningAction SilentlyContinue -Force
    }
catch{write-host "Could not remove $nicname, please remove it manually" -ForegroundColor Red}

write-host ""
write-host "Removing Public IP of Recovery VM: $publicipname" -ForegroundColor Yellow

try {
     Remove-AzPublicIpAddress -Name $publicipname -ResourceGroupName $RG -WarningAction SilentlyContinue -Force
    }
catch{write-host "Could not remove $nicname, please remove it manually" -ForegroundColor Red}

write-host ""
write-host "Removing OS Disk of RECOVERYVM-MS" -ForegroundColor Yellow

try {
    Remove-AzDisk -DiskName $vm.storageprofile.osdisk.name -ResourceGroupName $RG -Force
    }
catch{write-host "Could not remove disk from RECOVERYVM-MS, please remove it manually" -ForegroundColor red}

write-host ""
write-host "Removing VNET created for VM" -ForegroundColor Yellow
try {
    Remove-AzVirtualNetwork -Name "RecoveryVNET-MS" -ResourceGroupName $RG -Force
    }
catch{write-host "Could not remove disk from RECOVERYVM-MS, please remove it manually" -ForegroundColor red}


write-host
write-host "Removing all recovery snapshots from damaged VM $vmname" -ForegroundColor Yellow

foreach($snap in $snapshots)
    {
    write-host "Removing snapshot " $snap.name -ForegroundColor Yellow

     try{
        Remove-AzSnapshot -SnapshotName $snap.name -ResourceGroupName $RG -WarningAction SilentlyContinue -Force
        }
     catch{Write-host "Could not remove snapshots called recoverysnapshot. Please remove them manually if required" -ForegroundColor red}

     }

  try{
        Remove-azresourcegroup -name "recoveryrg" -force
        }
     catch{Write-host "Could not remove Resource Group RecoveryRG. Please remove manually" -ForegroundColor red}

     
$snapshotdiskname="Disk-"+$VMName
$snapshotdisk=get-azdisk | ? {$_.name -like "*$snapshotdiskname*" }     
$snapshotdiskfinalname=$snapshotdisk.Name

write-host "Leaving disk $snapshotdiskfinalname not deleted as a possible backup. Please remove it manually once incident is resolved." -ForegroundColor Yellow
Stop-Transcript

}
else{write-host "Exitting script as it has been decided to not remove the objects" -ForegroundColor Red;Stop-Transcript;exit}
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
write-host ""
write-host "WARNING: This script only works in VMs that have managed disks, and as long as the disks are not encrypted" -ForegroundColor Yellow
write-host ""
write-host ""
write-host "Please select what operation you want to proceed with:"
write-host "1. Create RecoveryVM and attach OS Disk for further investigation. OS Disk snapshot will be taken for backup." -ForegroundColor Yellow
write-host "2. Restore Last Known Good Configuration. This operation creates RecoveryVM and attach OS Disk, restoring last known good configuration on it. OS Disk snapshot will be taken for backup. Disks will be automatically swapped after" -ForegroundColor Yellow
write-host "3. Restore Disk (Swap OS Disk). Perform this operation after the disk was fixed on Recovery VM" -ForegroundColor Yellow
write-host "4. Delete RecoveryVM and all its objects. Disk used as backup will remain, will have to be deleted manually" -ForegroundColor Yellow
write-host "Please select an option (1,2,3,4):" -ForegroundColor Yellow
$selection=read-host

if($selection -eq "1" -or $selection -eq "2" -or $selection -eq "3" -or $selection -eq "4")
{
    switch($selection)
        {
        1 {CreateRecoveryVM -VMName $vmname}
        2 {CreateRecoveryVM -VMName $vmname -lastknowngood $true;RestoreDisk -VMName $vmname}
        3 {RestoreDisk -VMName $vmname}
        4 {RemoveRecoveryVM -VMName $vmname}
        }
}
else
{
write-host "Selection is not correct. Please select one option by typing the number of the option (1,2,3 or 4) and press Enter" -ForegroundColor red
}
