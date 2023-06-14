$location = ""
$rgname = ""
$subscriptionID = "" 
$kustoClusterName = ""
$clidatabase = "dbwatcherDB"
$adminUserName = ""
$script = ".create-merge table MonitoringAgentLogs (TIMESTAMP:datetime, log_level:string, message:string, agent_machine_name:string, process_id:int)\n\n.create-merge table MonitoringAgentMetrics (TIMESTAMP:datetime, agent_machine_name:string, process_id:int, dataset:string, metric_name:string, metric_value:real, metric_type:string, metric_unit:string, server_name:string, database_name:string)"
$scriptName = "dbWatcherConfig"
$vmList = (Get-Content "vmsToMonitor.json" -Raw) | ConvertFrom-Json

$getRG = az group show --name $rgname

if($getRG -eq $null)
{
    $createRG = az group create --name $rgname --location $location
}

$providerName = "Microsoft.KeyVault"
$provider = az provider list --query "[?namespace=='$providerName'].registrationState"

if($provider[1] -ne '  "Registered"')
{
    Write-Host "Registering provider: $providerName"
    az provider register  --namespace Microsoft.KeyVault --wait
}

$providerName = "Microsoft.DatabaseWatcher"
$provider = az provider list --query "[?namespace=='$providerName'].registrationState"

if($provider[1] -ne '  "Registered"')
{
    Write-Host "Registering provider: $providerName"
    az provider register  --namespace Microsoft.DatabaseWatcher --wait
}

$providerName = "Microsoft.Kusto"
$provider = az provider list --query "[?namespace=='$providerName'].registrationState"

if($provider[1] -ne '  "Registered"')
{
    Write-Host "Registering provider: $providerName"
    az provider register  --namespace Microsoft.Kusto --wait
}

# Install extension to use the latest Kusto CLI version
#az extension add -n kusto

$sku = @{}
$properties = @{}
$tags = @{}


$kustoclusterParameters = @{}
$kustoclusterParameters.Add("name",$kustoClusterName)
$kustoclusterParameters.Add("databases_kustodb_name",$clidatabase)
$kustoclusterParameters.Add("scriptName",$scriptName)
$kustoclusterParameters.Add("kqlScript",$script)

$sku.Add("capacity",1)
$sku.Add("name","Dev(No SLA)_Standard_E2a_v4")
$sku.Add("tier","Basic")

$properties.Add(
        "enableStreamingIngest", $true)
$properties.Add(
        "enablePurge",$false)
$properties.Add(
        "enableDoubleEncryption",$false)
$properties.Add("enableDiskEncryption",$false)
$properties.Add("trustedExternalTenants",@())
$properties.Add("enableAutoStop",$true)

$zonesa = @(1,2,3)

$kustoclusterParameters.Add("tags",$tags)
$kustoclusterParameters.Add("sku",$sku)
$kustoclusterParameters.Add("zones",$zonesa)
$kustoclusterParameters.Add("properties",$properties)

$kustoCluster = $null

$kustoCluster = Get-AzKustoCluster -Name $kustoClusterName -ResourceGroupName $rgname -ErrorAction SilentlyContinue
if($kustoCluster -eq $null)
{
    Write-Host "Creating Kusto Cluster $kustoClusterName and DB $clidatabase"
    New-AzResourceGroupDeployment -ResourceGroupName $rgname -TemplateUri .\kustocluster-template.json -TemplateParameterObject $kustoclusterParameters
    Write-Host "Kusto Cluster $kustoClusterName and DB $clidatabase created!"
}
Write-Host "Adding admin permission to admin user to cluster $kustoClusterName"
$clusterPrincipal=$null
$clusterPrincipal = Get-AzKustoClusterPrincipalAssignment -ClusterName $kustoClusterName -ResourceGroupName $rgname -ErrorAction SilentlyContinue
if($clusterPrincipal -eq $null)
{
    New-AzKustoClusterPrincipalAssignment -ClusterName $kustoClusterName -PrincipalAssignmentName "AllDatabasesAdmin" -PrincipalId $adminUserName -PrincipalType 'User' -ResourceGroupName $rgname -Role 'AllDatabasesAdmin'
}
foreach($vm in $vmList.vms)
{
    $vmPrincipalId = az resource show --id "/subscriptions/$($subscriptionID)/resourceGroups/$($vm.ResourceGroup)/providers/Microsoft.HybridCompute/machines/$($vm.Name )" --query identity.principalId
    New-AzKustoClusterPrincipalAssignment -ClusterName $kustoClusterName -PrincipalAssignmentName "$($vm.Name )" -PrincipalId $vmPrincipalId.Replace("""","")  -PrincipalType 'App' -ResourceGroupName $rgname -Role 'AllDatabasesAdmin'
    Write-Host "Adding VM $($vm.Name) manage identity $($vmPrincipalId) as admin user to cluster $($kustoClusterName)"
}