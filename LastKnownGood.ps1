$partition=get-disk -Number 2 | get-partition
$partition=$partition | ? {$_.partitionnumber -eq 2}
$path=$partition.driveletter+":\Windows\System32\config\SYSTEM"
reg load HKEY_USERS\ProblemSystem $path
$current=Get-ItemProperty -Path "Registry::\HKEY_USERS\Problemsystem\select" -name current
$default=Get-ItemProperty -Path "Registry::\HKEY_USERS\Problemsystem\select" -name default
$failed=Get-ItemProperty -Path "Registry::\HKEY_USERS\Problemsystem\select" -name failed
$lastknowngood=Get-ItemProperty -Path "Registry::\HKEY_USERS\Problemsystem\select" -name lastknowngood
$OSVersion=(gcim Win32_OperatingSystem).buildnumber

if($OSVersion -like '*9200*' -or $OSVersion -like '*9600*')
{
$newcurrent=$current.current+1
$newdefault=$default.default+1
$newfailed=$failed.failed+1
$newlastknowngood=$lastknowngood.lastknowngood+1

}
else{

$newcurrent=$current.current+1
$newdefault=$default.default+1
$newfailed=$failed.failed+1
$newlastknowngood=$newcurrent
}

write-host "Setting Current Value. Old value was "$current.current 
Set-ItemProperty -Path "Registry::\HKEY_USERS\Problemsystem\select" -name current  -Value $newcurrent

write-host "Setting Default Value. Old value was "$default.default
Set-ItemProperty -Path "Registry::\HKEY_USERS\Problemsystem\select" -name default  -Value $newdefault

write-host "Setting Failed Value. Old value was "$failed.failed
Set-ItemProperty -Path "Registry::\HKEY_USERS\Problemsystem\select" -name failed  -Value $newfailed

write-host "Setting LastKnownGood Value. Old value was "$lastknowngood.lastknowngood
Set-ItemProperty -Path "Registry::\HKEY_USERS\Problemsystem\select" -name lastknowngood -Value $newlastknowngood


reg unload HKEY_USERS\ProblemSystem



