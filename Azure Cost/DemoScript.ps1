$ErrorActionPreference = 'Stop';
$VerbosePreference = 'Continue';



Write-Output 'Import PowerBIPS module'
Import-Module 'PowerBIPS'
#Source: https://www.powershellgallery.com/packages/PowerBIPS
#GitHub: https://github.com/DevScope/powerbi-powershell-modules




$AzureSubscriptionName = 'Primary MSDN';

Write-Output 'Login to Azure resource manager account'
$Credential = Get-Credential
$azureContext = Login-AzureRMAccount -credential $Credential
$subscription = Get-AzureRMSubscription -SubscriptionName $AzureSubscriptionName
$subscriptionId = $subscription.SubscriptionId;
$tenantId = $subscription.TenantId;

Write-Output 'Create Authentication for Azure management interface'
$AuthenticationUri = 'https://login.windows.net/{0}' -f $tenantId
$authenticationContext = New-Object Microsoft.IdentityModel.Clients.ActiveDirectory.AuthenticationContext($AuthenticationUri);

$clientId = [GUID]'1950a258-227b-4e31-a9cf-717495945fc2';
$userCredential = New-Object Microsoft.IdentityModel.Clients.ActiveDirectory.UserCredential($Credential.UserName, $Credential.Password);

Write-Output 'Authenticate to Azure management API'
$resourceAppIdURI = 'https://management.core.windows.net/';
$authenticationResult = $authenticationContext.AcquireToken($resourceAppIdURI, $clientId, $userCredential);
$AzureAuthHeaders = @{'authorization' = $authenticationResult.CreateAuthorizationHeader()};

Write-Output 'Authenticate to Power BI API'
$resourceAppIdURI = 'https://analysis.windows.net/powerbi/api';
$authenticationResult = $authenticationContext.AcquireToken($resourceAppIdURI, $clientId, $userCredential);
$PowerBiAuthToken =  $authenticationResult.AccessToken;





Write-Output 'Read Azure Resources.';
$ApiVersion = '2015-01-01'
$ResourcesUrl = 'https://management.azure.com/subscriptions/{0}/resources?api-version={1}' `
				-f $subscriptionId, $ApiVersion;
$ResourceIdLookup = @{};
$Resources = Do {
    $ResourcesData = Invoke-RestMethod -Uri $ResourcesUrl -Headers $AzureAuthHeaders -ContentType 'application/json'

    $ResourcesData.value | ForEach {
        $ResourceIdLookup.Add($_.id, $_);
        $resourceGroup = $_.id.Split('/')[4];
        Add-Member -InputObject $_ -MemberType NoteProperty -Name 'ResourceGroup' -Value $resourceGroup -Force
        Write-Output $_;
    }

    if ($ResourcesData.NextLink) {
		$ResourcesUrl = $ResourcesData.NextLink;
	} else {
		$ResourcesUrl = $null;
	}
} until (-not $ResourcesUrl)





Write-Output 'Read Azure Resource Rate Card.';
$AzureSubscriptionOfferDurableId = 'MS-AZR-0063P'; #From Azure Portal.
$AzureSubscriptionCurrency = 'AUD'; #From Azure Portal.
$AzureSubscriptionRegionInfo = 'AU'; #From Azure Portal.
$AzureSubscriptionLocale = 'en-US';
$ApiVersion = '2015-06-01-preview';
$ResourceCardUrl = "https://management.azure.com/subscriptions/{0}/providers/Microsoft.Commerce/RateCard?api-version={1}&`$filter=OfferDurableId eq '{2}' and Currency eq '{3}' and Locale eq '{4}' and RegionInfo eq '{5}'" `
                -f $subscriptionId, $ApiVersion, $AzureSubscriptionOfferDurableId, $AzureSubscriptionCurrency, $AzureSubscriptionLocale, $AzureSubscriptionRegionInfo;
$ResourceCards = Invoke-RestMethod -Uri $ResourceCardUrl -Headers $AzureAuthHeaders -ContentType 'application/json';

Write-Output 'Convert Resource Cards to a lookup.';
$MeterIds = @{};
$ResourceCards.Meters | ForEach { $MeterIds.Add([guid]$_.MeterId, $_); };




function Coalesce([string]$a, [string]$b, [string]$c) { if (-not [System.String]::IsNullOrEmpty($a)) { $a.Trim() } elseif (-not [System.String]::IsNullOrEmpty($b)) { $b.Trim() } else { $c } }



$AzureCostGranularity = 'Daily';#Can be Hourly or Daily
$AzureCostShowDetails = $true;
$today = Get-Date;
#The begin of the month 180 days ago.
$reportedStartTime = $today.AddDays(-180).AddDays($today.AddDays(-180).Day * -1 + 2);
$reportedEndTime = $today;
$dateTimeFormat = 'yyyy-MM-dd';
$ApiVersion = '2015-06-01-preview';
$UsageUrl = "https://management.azure.com/subscriptions/{0}/providers/Microsoft.Commerce/UsageAggregates?api-version={1}&reportedStartTime={2}&reportedEndTime={3}&aggregationGranularity={4}&showDetails={5}" `
            -f $subscriptionId, $ApiVersion, $reportedStartTime.ToString($dateTimeFormat), $reportedEndTime.ToString($dateTimeFormat), $AzureCostGranularity, $AzureCostShowDetails;


$TransformedUsageData = Do {
    $usageData = Invoke-RestMethod -Uri $UsageUrl -Headers $AzureAuthHeaders -ContentType 'application/json'
	
    $usageData.value.properties | ForEach {
            #Transform usage data
            $usage = $_;

            $meter = $MeterIds[[guid]$usage.MeterId];
            Add-Member -InputObject $_ -MemberType NoteProperty -Name 'Meter' -Value $meter -Force
            $location = $meter.MeterRegion;
            
			if ($_.InfoFields -ne $null -and $_.InfoFields.Project -ne $null) {
                $project = $usage.InfoFields.Project;
                $resource = $Resources | where {$_.type -Like ('*'+$usage.InfoFields.meteredService+'*') -and $_.name -eq $project} | select -First 1
                if ($resource -eq $null) { $resource = $Resources | where {$_.type -Like ('*'+$usage.InfoFields.meteredService+'*') -and $_.name -eq ($project -replace ' - ', '/')} | select -First 1; }
                if ($resource -eq $null) { $resource = $Resources | where {$_.type -Like ('*'+$usage.InfoFields.meteredService+'*') -and $_.name -eq ($project.split('(')[0])} | select -First 1; }
                if ($resource -eq $null) { $resource = @{ name = $project -replace ' - ', '/' }; }
                Add-Member -InputObject $_ -MemberType NoteProperty -Name 'Resource' -Value $resource -Force

                $location = Coalesce $location $resource.location $_.InfoFields.meteredRegion;
			}
			if ($_.instanceData -ne $null) {
				$value = ConvertFrom-Json($usage.instanceData);
                $resource = $ResourceIdLookup[$value.'Microsoft.Resources'.resourceUri];
                if ($resource -eq $null) {
                    $split = $value.'Microsoft.Resources'.resourceUri.Split('/');
                    $resource = @{ 
                        name = $split[$split.Length - 1];
                        ResourceGroup = $split[4]
                    }
                }
                Add-Member -InputObject $_ -MemberType NoteProperty -Name 'Resource' -Value $resource -Force

                $location = $value.'Microsoft.Resources'.location;
			}
            Add-Member -InputObject $_ -MemberType NoteProperty -Name 'Location' -Value $location -Force

            Write-Output $usage;
	} | Select-Object `
		@{n='Usage Date'; e={$_.UsageStartTime}}, `
		@{n='Month'; e={([DateTime]$_.UsageStartTime).ToString('MM')}}, `
		@{n='Year'; e={([DateTime]$_.UsageStartTime).ToString('yyyy')}}, `
		@{n='Year and Month'; e={([DateTime]$_.UsageStartTime).ToString('yyyy - MM')}}, `
		@{n='Subscription Id'; e={$_.SubscriptionId}}, `
		@{n='Subscription Name'; e={$AzureSubscriptionName}}, `
		@{n='Meter Id'; e={$_.MeterId}}, `
		@{n='Meter Name'; e={Coalesce $_.Meter.MeterName $_.MeterName}}, `
		@{n='Meter Category'; e={Coalesce $_.Meter.MeterCategory $_.MeterCategory}}, `
		@{n='Meter Sub-category';e={Coalesce $_.Meter.MeterSubCategory $_.meterSubCategory}}, `
		@{n='Meter Region';e={$_.location}}, `
		@{n='Unit'; e={Coalesce $_.Meter.Unit $_.Unit}}, `
		Quantity, `
		@{n='Meter Rate'; e={$_.Meter.MeterRates.0}}, `
		@{n='Cost'; e={$_.Meter.MeterRates.0 * $_.Quantity}}, `
		@{n='Resource';e={$_.Resource.name}}, `
		@{n='Resource Group';e={$_.Resource.ResourceGroup}}, `
		@{n='Category';e={'NA'}} | ` 
	        Where-Object {$_.Cost -ne $null -and [double]$_.Cost -gt 0}
	
    if ($usageData.NextLink) {
		$UsageUrl = $usageData.NextLink;
	} else {
		$UsageUrl = $null;
	}
} until (-not $UsageUrl)





$TransformedUsageData | Out-GridView






Write-Output 'Prep Power BI schema';
$PowerBiDatasetName = 'Power BI UserGroup'
$table = @{
    name = "UsageData"; 
    columns = @(
	@{name = "Usage Date"; dataType ="Datetime"}, 
	@{name = "Month"; dataType ="Int64"}, 
	@{name = "Year"; dataType ="Int64"}, 
	@{name = "Year and Month"; dataType ="String"}, 
	@{name = "Subscription Id"; dataType ="String"}, 
	@{name = "Subscription Name"; dataType ="String"},
	@{name = "Meter Id"; dataType ="String"}, 
	@{name = "Meter Name"; dataType ="String"}, 
	@{name = "Meter Category"; dataType ="String"}, 
	@{name = "Meter Sub-category"; dataType ="String"}, 
	@{name = "Meter Region"; dataType ="String"}, 
	@{name = "Unit"; dataType ="String"}, 
	@{name = "Quantity"; dataType ="double"}, 
	@{name = "Meter Rate"; dataType ="double"}, 
	@{name = "Cost"; dataType ="double"}, 
	@{name = "Resource"; dataType ="String"},
	@{name = "Resource Group"; dataType ="String"},
	@{name = "Category"; dataType ="String"}
    ) 
}
$dataSetSchema = @{
    name = $PowerBiDatasetName; 
    tables = @(
        $table
    )
}







if (!(Test-PBIDataSet -authToken $PowerBiAuthToken -name $PowerBiDatasetName -verbose))
{
    Write-Output "Creating Dataset $PowerBiDatasetName.";
    $pbiDataSet = New-PBIDataSet -authToken $PowerBiAuthToken -dataSet $dataSetSchema -verbose
} else {
    $pbiDataSet = Get-PBIDataSet -authToken $PowerBiAuthToken -name $PowerBiDatasetName -verbose

    Write-Output "Clear Dataset $PowerBiDatasetName and update schema.";
	Clear-PBITableRows -authToken $PowerBiAuthToken -dataSetName $PowerBiDatasetName -tableName $table.Name -verbose
	Update-PBITableSchema -authToken $PowerBiAuthToken -dataSetId $pbiDataSet.id -table $table -verbose
}



$TransformedUsageData | Out-PowerBI -AuthToken $PowerBiAuthToken -dataSetName $PowerBiDatasetName -tableName $table.Name -batchSize 1000 -verbose