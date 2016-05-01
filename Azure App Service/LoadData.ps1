$ErrorActionPreference = 'Stop';

$endTime = (Get-Date);
$startTime = $endTime.AddHours(-12);
$timeGrain = 'PT1M'; #PT1M (minute), PT1H (hour), P1D (day)
$LoadOnlyToday = $false;

Write-Output 'Import PowerBIPS module'
Import-Module 'PowerBIPS'

Write-Output 'Get credentials from Azure Automation'
#$azureCredential = Get-AutomationPSCredential -Name $AzureCredentialName
$azureCredential = Get-Credential;
if($azureCredential -eq $null)
{
	Write-Output "ERROR: Failed to get credential with name [$AzureCredentialName]"
	Write-Output "Exiting runbook due to error"
	return
}
$userCredential = New-Object Microsoft.IdentityModel.Clients.ActiveDirectory.UserCredential($azureCredential.UserName, $azureCredential.Password);

Write-Output 'Login to Azure resource manager account'
# Authenticate to Azure
$azureContext = Login-AzureRMAccount -credential $azureCredential

# Select an Azure Subscription for which to report usage data
$subscription = (Get-AzureRmSubscription |
     Out-GridView `
       -Title "Select an Azure Subscription ..." `
       -PassThru);
$subscriptionId = $subscription.SubscriptionId;
$tenantId = $subscription.TenantId
Select-AzureRmSubscription -SubscriptionId $subscriptionId

Write-Output 'Create Authentication for azure management interface'
# Create Authentication for azure management interface
$AuthenticationUri = 'https://login.windows.net/{0}' -f $tenantId
$authenticationContext = New-Object Microsoft.IdentityModel.Clients.ActiveDirectory.AuthenticationContext($AuthenticationUri);

Write-Output 'Authenticate to Azure management API'
#authenticate to Azure management API
$resourceAppIdURI = 'https://management.core.windows.net/';
$clientId = [GUID]'1950a258-227b-4e31-a9cf-717495945fc2';
$redirectUri = New-Object System.Uri('urn:ietf:wg:oauth:2.0:oob');
#$authenticationResult = $authenticationContext.AcquireToken($resourceAppIdURI, $clientId, $redirectUri, 'Never');#"AUTO"
$authenticationResult = $authenticationContext.AcquireToken($resourceAppIdURI, $clientId, $userCredential);#"AUTO"

$ResHeaders = @{'authorization' = $authenticationResult.CreateAuthorizationHeader()};

Add-Type -Path 'C:\Temp\Azure\UsageToPowerBi\Microsoft.Azure.Insights.dll';
$token = new-object Microsoft.Azure.TokenCloudCredentials($SubscriptionId, $authenticationResult.AccessToken);

Write-Output 'Authenticate to Power BI API'
#authenticate to Power BI.
$resourceAppIdURI = 'https://analysis.windows.net/powerbi/api';
$clientId = [GUID]'1950a258-227b-4e31-a9cf-717495945fc2';
$redirectUri = New-Object System.Uri('urn:ietf:wg:oauth:2.0:oob');
#$authenticationResult = $authenticationContext.AcquireToken($resourceAppIdURI, $clientId, $redirectUri, 'Never');#"AUTO"
$authenticationResult = $authenticationContext.AcquireToken($resourceAppIdURI, $clientId, $userCredential);#"AUTO"
$powerBiAuthToken =  $authenticationResult.AccessToken;


#Prep Power BI schema

#CpuPercentage double: Minimum, Maximum, Average
#MemoryPercentage double: Minimum, Maximum, Average
#DiskQueueLength int64: Minimum, Maximum, Average 
#HttpQueueLength int64: Minimum, Maximum, Average
#BytesReceived double: Total
#BytesSent double: Total
$table1 = @{
    name = "App Service Plans"; 
    columns = @(
	@{name = "Name"; dataType ="String"}, 
	@{name = "Location"; dataType ="String"}, 
	@{name = "Timestamp"; dataType ="Datetime"}, 
	@{name = "Timestamp Hour"; dataType ="Datetime"}, 
	@{name = "Timestamp Day"; dataType ="Datetime"}, 
	@{name = "CPU Percentage Minimum"; dataType ="double"}, 
	@{name = "CPU Percentage Maximum"; dataType ="double"}, 
	@{name = "CPU Percentage Average"; dataType ="double"}, 
	@{name = "Memory Percentage Minimum"; dataType ="double"}, 
	@{name = "Memory Percentage Maximum"; dataType ="double"}, 
	@{name = "Memory Percentage Average"; dataType ="double"}, 
	@{name = "Disk Queue Length Minimum"; dataType ="int64"}, 
	@{name = "Disk Queue Length Maximum"; dataType ="int64"}, 
	@{name = "Disk Queue Length Average"; dataType ="int64"}, 
	@{name = "Http Queue Length Minimum"; dataType ="int64"}, 
	@{name = "Http Queue Length Maximum"; dataType ="int64"}, 
	@{name = "Http Queue Length Average"; dataType ="int64"}, 
	@{name = "Data In MiB"; dataType ="double"}, 
	@{name = "Data Out MiB"; dataType ="double"}
    ) 
}

#CpuTime double: Total
#MemoryWorkingSet double: Minimum, Maximum, Average
#Requests int64: Total
#Http2xx int64: Total
#Http3xx int64: Total
#Http4xx int64: Total
#Http5xx int64: Total
#AverageResponseTime double: Total
#BytesReceived double: Total
#BytesSent double: Total
$table2 = @{
    name = "App Services"; 
    columns = @(
	@{name = "Name"; dataType ="String"}, 
	@{name = "Location"; dataType ="String"}, 
	@{name = "App Service Plan"; dataType ="String"}, 
	@{name = "Timestamp"; dataType ="Datetime"}, 
	@{name = "Timestamp Hour"; dataType ="Datetime"}, 
	@{name = "Timestamp Day"; dataType ="Datetime"}, 
	@{name = "CPU Time (s)"; dataType ="double"}, 
	@{name = "CPU Time (s) * 10"; dataType ="double"}, 
	@{name = "Memory working set Mib Minimum"; dataType ="double"}, 
	@{name = "Memory working set Mib Maximum"; dataType ="double"}, 
	@{name = "Memory working set Mib Average"; dataType ="double"},
	@{name = "Requests"; dataType ="int64"}, 
	@{name = "Http 2xx"; dataType ="int64"}, 
	@{name = "Http 3xx"; dataType ="int64"}, 
	@{name = "Http 4xx"; dataType ="int64"}, 
	@{name = "Http 5xx"; dataType ="int64"}, 
	@{name = "Average Response Time (ms)"; dataType ="double"},
	@{name = "Data In MiB"; dataType ="double"},
	@{name = "Data Out MiB"; dataType ="double"}
    ) 
}

$datasetName = 'Azure App Service Metrics3';
$dataSetSchema = @{
    name = $datasetName; 
    tables = @(
        $table1,
		$table2
    )
} 


#Prep Power BI dataset and table.
if (!(Test-PBIDataSet -authToken $powerBiAuthToken -name $datasetName -verbose))
{  
    #create the dataset
    $pbiDataSet = New-PBIDataSet -authToken $powerBiAuthToken -dataSet $dataSetSchema -verbose
}
else
{
    $pbiDataSet = Get-PBIDataSet -authToken $powerBiAuthToken -name $datasetName -verbose

	if (-not $LoadOnlyToday) {
		Clear-PBITableRows -authToken $powerBiAuthToken -dataSetName $datasetName -tableName $table1.Name -verbose
		Update-PBITableSchema -authToken $powerBiAuthToken -dataSetId $pbiDataSet.id -table $table1 -verbose
		
		Clear-PBITableRows -authToken $powerBiAuthToken -dataSetName $datasetName -tableName $table2.Name -verbose
		Update-PBITableSchema -authToken $powerBiAuthToken -dataSetId $pbiDataSet.id -table $table2 -verbose
	}
}

#Load Server Farms
$ApiVersion = '2015-08-01';
$Url = "https://management.azure.com/subscriptions/{0}/providers/Microsoft.Web/serverfarms?api-version={1}" -f `
	$SubscriptionId, $ApiVersion
$Result = Invoke-RestMethod -Uri $Url -Headers $ResHeaders -ContentType 'application/json'

$serverFarm = $Result.value[2];
$serverFarm.Name;
$serverFarm.location;


$i = New-Object microsoft.azure.insights.insightsclient($token)
$ct = new-object System.Threading.CancellationToken;
#CpuPercentage double: Minimum, Maximum, Average
#MemoryPercentage double: Minimum, Maximum, Average
#DiskQueueLength int64: Minimum, Maximum, Average 
#HttpQueueLength int64: Minimum, Maximum, Average
#BytesReceived double: Total
#BytesSent double: Total
$filter = "(name.value eq 'CpuPercentage' or name.value eq 'MemoryPercentage' or name.value eq 'DiskQueueLength' or name.value eq 'HttpQueueLength' or name.value eq 'BytesReceived' or name.value eq 'BytesSent') and startTime eq {3} and endTime eq {4} and timeGrain eq duration'{5}'" -f `
	$serverFarm.id, $ApiVersion, $metricsNames, $startTime.ToUniversalTime().ToString('yyyy-MM-ddTHH:mmZ'), $endTime.ToUniversalTime().ToString('yyyy-MM-ddTHH:mmZ'), $timeGrain
$r = $i.MetricOperations.GetMetricsAsync($serverFarm.id, $filter, $ct)

$metrics = @{};
$r.Result.MetricCollection.Value | ForEach {
	$MetricValue = $_;
	$MetricValue.MetricValues | ForEach {
		if ($metrics[$_.Timestamp] -eq $null) {$metrics[$_.Timestamp] = @{};}
		$metrics[$_.Timestamp][$MetricValue.Name.Value] = $_;
	}
};

$metrics.Keys | Select-Object `
		@{n='Name'; e={$serverFarm.Name}}, `
		@{n='Location'; e={$serverFarm.location}}, `
		@{n='Timestamp'; e={$_.ToString("yyyy-MM-ddTHH:mmZ")}}, `
		@{n='Timestamp Hour'; e={$_.ToString("yyyy-MM-ddTHH:00Z")}}, `
		@{n='Timestamp Day'; e={$_.ToString("yyyy-MM-ddT00:00Z")}}, `
		@{n='CPU Percentage Minimum'; e={$metrics[$_]['CpuPercentage'].Minimum}}, `
		@{n='CPU Percentage Maximum'; e={$metrics[$_]['CpuPercentage'].Maximum}}, `
		@{n='CPU Percentage Average'; e={$metrics[$_]['CpuPercentage'].Average}}, `
		@{n='Memory Percentage Minimum'; e={$metrics[$_]['MemoryPercentage'].Minimum}}, `
		@{n='Memory Percentage Maximum'; e={$metrics[$_]['MemoryPercentage'].Maximum}}, `
		@{n='Memory Percentage Average'; e={$metrics[$_]['MemoryPercentage'].Average}}, `
		@{n='Disk Queue Length Minimum'; e={$metrics[$_]['DiskQueueLength'].Minimum}}, `
		@{n='Disk Queue Length Maximum'; e={$metrics[$_]['DiskQueueLength'].Maximum}}, `
		@{n='Disk Queue Length Average'; e={$metrics[$_]['DiskQueueLength'].Average}}, `
		@{n='Http Queue Length Minimum'; e={$metrics[$_]['HttpQueueLength'].Minimum}}, `
		@{n='Http Queue Length Maximum'; e={$metrics[$_]['HttpQueueLength'].Maximum}}, `
		@{n='Http Queue Length Average'; e={$metrics[$_]['HttpQueueLength'].Average}}, `
		@{n='Data In MiB'; e={$metrics[$_]['BytesReceived'].Total / 1024 / 1024}}, `
		@{n='Data Out MiB'; e={$metrics[$_]['BytesSent'].Total / 1024 / 1024}} | `
Out-PowerBI -AuthToken $powerBiAuthToken -dataSetName $datasetName -tableName $table1.Name -batchSize 1000 -verbose


$Url = "https://management.azure.com{0}/sites?api-version={1}" -f `
	$serverFarm.id, $ApiVersion
$sites = Invoke-RestMethod -Uri $Url -Headers $ResHeaders -ContentType 'application/json'

$sites.value | ForEach {
	$site = $_;
	#CpuTime, Requests, BytesReceived, BytesSent, Http2xx, Http3xx, Http401, Http403, Http404, Http406, Http4xx, Http5xx, MemoryWorkingSet, AverageResponseTime
	$filter = "(name.value eq 'CpuTime' or name.value eq 'Requests' or name.value eq 'BytesReceived' or name.value eq 'BytesSent' or name.value eq 'Http2xx' or name.value eq 'Http3xx'or name.value eq 'Http4xx' or name.value eq 'Http5xx' or name.value eq 'MemoryWorkingSet' or name.value eq 'AverageResponseTime') and startTime eq {3} and endTime eq {4} and timeGrain eq duration'{5}'" -f `
	$serverFarm.id, $ApiVersion, $metricsNames, $startTime.ToUniversalTime().ToString('yyyy-MM-ddTHH:mmZ'), $endTime.ToUniversalTime().ToString('yyyy-MM-ddTHH:mmZ'), $timeGrain
	$r = $i.MetricOperations.GetMetricsAsync($site.id, $filter, $ct)

	$metrics = @{};
	$r.Result.MetricCollection.Value | ForEach {
		$MetricValue = $_;
		$MetricValue.MetricValues | ForEach {
			if ($metrics[$_.Timestamp] -eq $null) {$metrics[$_.Timestamp] = @{};}
			$metrics[$_.Timestamp][$MetricValue.Name.Value] = $_;
		}
	};
	
	$metrics.Keys | Select-Object `
			@{n='Name'; e={$site.name}}, `
			@{n='Location'; e={$serverFarm.location}}, `
			@{n='App Service Plan'; e={$serverFarm.Name}}, `
			@{n='Timestamp'; e={$_.ToString("yyyy-MM-ddTHH:mmZ")}}, `
			@{n='Timestamp Hour'; e={$_.ToString("yyyy-MM-ddTHH:00Z")}}, `
			@{n='Timestamp Day'; e={$_.ToString("yyyy-MM-ddT00:00Z")}}, `
			@{n='CPU Time (s)'; e={$metrics[$_]['CpuTime'].Total}}, `
			@{n='CPU Time (s) * 10'; e={$metrics[$_]['CpuTime'].Total * 10}}, `
			@{n='Memory working set Mib Minimum'; e={$metrics[$_]['MemoryWorkingSet'].Minimum / 1024 / 1024}}, `
			@{n='Memory working set Mib Maximum'; e={$metrics[$_]['MemoryWorkingSet'].Maximum / 1024 / 1024}}, `
			@{n='Memory working set Mib Average'; e={$metrics[$_]['MemoryWorkingSet'].Average / 1024 / 1024}}, `
			@{n='Requests'; e={$metrics[$_]['Requests'].Total}}, `
			@{n='Http 2xx'; e={$metrics[$_]['Http2xx'].Total}}, `
			@{n='Http 3xx'; e={$metrics[$_]['Http3xx'].Total}}, `
			@{n='Http 4xx'; e={$metrics[$_]['Http4xx'].Total}}, `
			@{n='Http 5xx'; e={$metrics[$_]['Http5xx'].Total}}, `
			@{n='Average Response Time (ms)'; e={$metrics[$_]['AverageResponseTime'].Total}}, `
			@{n='Data In MiB'; e={$metrics[$_]['BytesReceived'].Total / 1024 / 1024}}, `
			@{n='Data Out MiB'; e={$metrics[$_]['BytesSent'].Total / 1024 / 1024}} | `
	Out-PowerBI -AuthToken $powerBiAuthToken -dataSetName $datasetName -tableName $table2.Name -batchSize 1000 -verbose
	
	$Url = "https://management.azure.com{0}/slots?api-version={1}" -f $site.id, $ApiVersion
	$siteSlots = Invoke-RestMethod -Uri $Url -Headers $ResHeaders -ContentType 'application/json'
	
	$siteSlots.value | ForEach {
		$site = $_;
		#CpuTime, Requests, BytesReceived, BytesSent, Http2xx, Http3xx, Http401, Http403, Http404, Http406, Http4xx, Http5xx, MemoryWorkingSet, AverageResponseTime
		$filter = "(name.value eq 'CpuTime' or name.value eq 'Requests' or name.value eq 'BytesReceived' or name.value eq 'BytesSent' or name.value eq 'Http2xx' or name.value eq 'Http3xx'or name.value eq 'Http4xx' or name.value eq 'Http5xx' or name.value eq 'MemoryWorkingSet' or name.value eq 'AverageResponseTime') and startTime eq {3} and endTime eq {4} and timeGrain eq duration'{5}'" -f `
		$serverFarm.id, $ApiVersion, $metricsNames, $startTime.ToUniversalTime().ToString('yyyy-MM-ddTHH:mmZ'), $endTime.ToUniversalTime().ToString('yyyy-MM-ddTHH:mmZ'), $timeGrain
		$r = $i.MetricOperations.GetMetricsAsync($site.id, $filter, $ct)
		
		$metrics = @{};
		$r.Result.MetricCollection.Value | ForEach {
			$MetricValue = $_;
			$MetricValue.MetricValues | ForEach {
				if ($metrics[$_.Timestamp] -eq $null) {$metrics[$_.Timestamp] = @{};}
				$metrics[$_.Timestamp][$MetricValue.Name.Value] = $_;
			}
		};
		
		$metrics.Keys | Select-Object `
				@{n='Name'; e={$site.name}}, `
				@{n='Location'; e={$serverFarm.location}}, `
				@{n='App Service Plan'; e={$serverFarm.Name}}, `
				@{n='Timestamp'; e={$_.ToString("yyyy-MM-ddTHH:mmZ")}}, `
				@{n='Timestamp Hour'; e={$_.ToString("yyyy-MM-ddTHH:00Z")}}, `
				@{n='Timestamp Day'; e={$_.ToString("yyyy-MM-ddT00:00Z")}}, `
				@{n='CPU Time (s)'; e={$metrics[$_]['CpuTime'].Total}}, `
				@{n='CPU Time (s) * 10'; e={$metrics[$_]['CpuTime'].Total * 10}}, `
				@{n='Memory working set Mib Minimum'; e={$metrics[$_]['MemoryWorkingSet'].Minimum / 1024 / 1024}}, `
				@{n='Memory working set Mib Maximum'; e={$metrics[$_]['MemoryWorkingSet'].Maximum / 1024 / 1024}}, `
				@{n='Memory working set Mib Average'; e={$metrics[$_]['MemoryWorkingSet'].Average / 1024 / 1024}}, `
				@{n='Requests'; e={$metrics[$_]['Requests'].Total}}, `
				@{n='Http 2xx'; e={$metrics[$_]['Http2xx'].Total}}, `
				@{n='Http 3xx'; e={$metrics[$_]['Http3xx'].Total}}, `
				@{n='Http 4xx'; e={$metrics[$_]['Http4xx'].Total}}, `
				@{n='Http 5xx'; e={$metrics[$_]['Http5xx'].Total}}, `
				@{n='Average Response Time (ms)'; e={$metrics[$_]['AverageResponseTime'].Total}}, `
				@{n='Data In MiB'; e={$metrics[$_]['BytesReceived'].Total / 1024 / 1024}}, `
				@{n='Data Out MiB'; e={$metrics[$_]['BytesSent'].Total / 1024 / 1024}} | `
		Out-PowerBI -AuthToken $powerBiAuthToken -dataSetName $datasetName -tableName $table2.Name -batchSize 1000 -verbose
	}
}