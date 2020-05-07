$logfile="c:\lastknowngood-"+$(get-date -f yyyy-MM-dd-HHmmss)+".txt"
$partition=get-disk -Number 2 | get-partition
$partition=$partition | ? {$_.partitionnumber -eq 2}
$path=$partition.driveletter+":\Windows\System32\config\SYSTEM"
reg load HKEY_USERS\ProblemSystem $path
$current=(Get-ItemProperty -Path "Registry::\HKEY_USERS\Problemsystem\select" -name current).current
$default=(Get-ItemProperty -Path "Registry::\HKEY_USERS\Problemsystem\select" -name default).default
$failed=(Get-ItemProperty -Path "Registry::\HKEY_USERS\Problemsystem\select" -name failed).failed
$lastknowngood=(Get-ItemProperty -Path "Registry::\HKEY_USERS\Problemsystem\select" -name lastknowngood).lastknowngood
$OSVersion=(gcim Win32_OperatingSystem).buildnumber

if($OSVersion -like '*9200*' -or $OSVersion -like '*9600*')
{
$newcurrent=$current+1
$newdefault=$default+1
$newfailed=$failed+1
$newlastknowngood=$lastknowngood+1
}
else{
$newcurrent=$current.current+1
$newdefault=$default.default+1
$newfailed=$failed.failed+1
$newlastknowngood=$newcurrent
}

write-output "Setting Current Value to $newcurrent. Old value was $current" >> $logfile
Set-ItemProperty -Path "Registry::\HKEY_USERS\Problemsystem\select" -name current  -Value $newcurrent

write-output "Setting Default Value to $newdefault. Old value was $default" >> $logfile
Set-ItemProperty -Path "Registry::\HKEY_USERS\Problemsystem\select" -name default  -Value $newdefault

write-output "Setting Failed Value to $newfailed. Old value was $failed" >> $logfile
Set-ItemProperty -Path "Registry::\HKEY_USERS\Problemsystem\select" -name failed  -Value $newfailed

write-output "Setting LastKnownGood Value to $newlastknowngood. Old value was $lastknowngood" >> $logfile
Set-ItemProperty -Path "Registry::\HKEY_USERS\Problemsystem\select" -name lastknowngood -Value $newlastknowngood


reg unload HKEY_USERS\ProblemSystem



