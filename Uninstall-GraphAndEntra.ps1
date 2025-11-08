# First, uninstall Microsoft Entra PowerShell modules
$EntraModules = Get-Module Microsoft.Entra* -ListAvailable | Select-Object Name -Unique
Foreach ($Module in $EntraModules)
{
    $ModuleName = $Module.Name
    $Versions = Get-Module $ModuleName -ListAvailable
    Foreach ($Version in $Versions)
    {
        $ModuleVersion = $Version.Version
        Write-Host "Uninstall-Module $ModuleName $ModuleVersion"
        Uninstall-Module $ModuleName -RequiredVersion $ModuleVersion -Force
    }
}

# Then uninstall Microsoft.Graph modules (except Authentication)
$Modules = Get-Module Microsoft.Graph* -ListAvailable | Where {$_.Name -ne "Microsoft.Graph.Authentication"} | Select-Object Name -Unique
Foreach ($Module in $Modules)
{
    $ModuleName = $Module.Name
    $Versions = Get-Module $ModuleName -ListAvailable
    Foreach ($Version in $Versions)
    {
        $ModuleVersion = $Version.Version
        Write-Host "Uninstall-Module $ModuleName $ModuleVersion"
        Uninstall-Module $ModuleName -RequiredVersion $ModuleVersion -Force
    }
}

# Finally, uninstall Microsoft.Graph.Authentication
$ModuleName = "Microsoft.Graph.Authentication"
$Versions = Get-Module $ModuleName -ListAvailable
Foreach ($Version in $Versions)
{
    $ModuleVersion = $Version.Version
    Write-Host "Uninstall-Module $ModuleName $ModuleVersion"
    Uninstall-Module $ModuleName -RequiredVersion $ModuleVersion -Force
}
