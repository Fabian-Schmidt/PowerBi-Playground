#Needs the following Assets:
#-'$AzureCredentialName' Credential
#-'AzureCostImport-$AzureSubscriptionName' DateTime
param (
    [Parameter(Mandatory=$true)]
    [string] 
    $AzureCredentialName,

    [Parameter(Mandatory=$true)]
    [string] 
    $AzureSubscriptionName,

    [Parameter(Mandatory=$false)]
    [boolean]
    $LoadDelta = $true,

    [Parameter(Mandatory=$false)]
    [string]
    $AzureCostGranularity = 'Daily',#Can be Hourly or Daily
    #TODO: Support Hourly

    [Parameter(Mandatory=$false)]
    [boolean]
    $AzureCostShowDetails = $true,

    [Parameter(Mandatory=$false)]
    [string]
    $PowerBiDatasetName = 'Azure Cost',

    [Parameter(Mandatory=$true)]
    [string]
    $AzureSubscriptionOfferDurableId, #From Azure Portal.
    #e.g. MS-AZR-0063P or MS-AZR-0025P

    [Parameter(Mandatory=$true)]
    [string]
    $AzureSubscriptionCurrency, #From Azure Portal.
	#e.g. AUD

    [Parameter(Mandatory=$true)]
    [string]
    $AzureSubscriptionRegionInfo, #From Azure Portal.
	#e.g. AU

    [Parameter(Mandatory=$false)]
    [string]
    $AzureSubscriptionLocale = 'en-US' #Name of entities.
)
$VerbosePreference = 'Continue';
$ErrorActionPreference = 'Stop';

$LoadDelta_AutomationVariable = ('AzureCostImport-' +  $AzureSubscriptionName)
$today = Get-Date;
if ($LoadDelta) {
    Write-Verbose 'Read last import to PowerBi'
    $lastImport = Get-AutomationVariable -Name $LoadDelta_AutomationVariable;
    if ([System.String]::IsNullOrEmpty($lastImport)) {
        $LoadDelta = $false;
        $lastImport = $null;
    } else {
        $lastImport = [System.DateTime]::Parse($lastImport)
    }
}
if ($lastImport -is [DateTime] -and $lastImport -lt $today) {
    Write-Verbose "Last import to PowerBi $lastImport";
    $reportedStartTime = $lastImport;
    #TODO: Detect if last run was today.
} else {
    Write-Verbose "Never";
    $LoadDelta = $false;
    #The begin of the month 120 days ago.
	$reportedStartTime = $today.AddDays(-120).AddDays($today.AddDays(-120).Day * -1 + 2);
}
$reportedEndTime = $today;

Write-Verbose 'Import PowerBIPS module'
Import-Module 'PowerBIPS'

Write-Verbose 'Get credentials from Azure Automation'
$Credential = Get-AutomationPSCredential -Name $AzureCredentialName
$userCredential = New-Object Microsoft.IdentityModel.Clients.ActiveDirectory.UserCredential($Credential.UserName, $Credential.Password);

Write-Verbose 'Login to Azure account'
#Add-AzureRmAccount -credential $Credential;
$azureContext = Login-AzureRMAccount -credential $Credential;
Write-Verbose 'Get Azure subscription details'
$subscription = Get-AzureRMSubscription -SubscriptionName $AzureSubscriptionName
if ($subscription -eq $null){
    Write-Error "Subscription $AzureSubscriptionName not found."
}
$subscriptionId = $subscription.SubscriptionId;
Write-Verbose "SubscriptionId: $subscriptionId"
$subscriptionName = $subscription.SubscriptionName;
Write-Verbose "SubscriptionName: $subscriptionName"
$tenantId = $subscription.TenantId
Write-Verbose "TenantId: $tenantId"
$subscriptionIdLookup = @{};
$subscriptionIdLookup.Add([guid]$subscription.SubscriptionId, $subscription.SubscriptionName);

Write-Verbose 'Create Authentication for Azure management interface'
$AuthenticationUri = 'https://login.windows.net/{0}' -f $tenantId
$authenticationContext = New-Object Microsoft.IdentityModel.Clients.ActiveDirectory.AuthenticationContext($AuthenticationUri);

$clientId = [GUID]'1950a258-227b-4e31-a9cf-717495945fc2';
#$redirectUri = New-Object System.Uri('urn:ietf:wg:oauth:2.0:oob');

Write-Verbose 'Authenticate to Azure management API'
$resourceAppIdURI = 'https://management.core.windows.net/';
#$authenticationResult = $authenticationContext.AcquireToken($resourceAppIdURI, $clientId, $redirectUri, 'Never');#Auto or Never
$authenticationResult = $authenticationContext.AcquireToken($resourceAppIdURI, $clientId, $userCredential);
$AzureAuthHeaders = @{'authorization' = $authenticationResult.CreateAuthorizationHeader()};

Write-Verbose 'Authenticate to Power BI API'
$resourceAppIdURI = 'https://analysis.windows.net/powerbi/api';
#$authenticationResult = $authenticationContext.AcquireToken($resourceAppIdURI, $clientId, $redirectUri, 'Never');#Auto or Never
$authenticationResult = $authenticationContext.AcquireToken($resourceAppIdURI, $clientId, $userCredential);
$PowerBiAuthToken =  $authenticationResult.AccessToken;


Write-Verbose 'Prep Power BI schema';
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
	@{name = "MeterRate"; dataType ="double"}, 
	@{name = "Cost"; dataType ="double"}, 
	@{name = "Location State"; dataType ="String"}, 
	@{name = "Location Country"; dataType ="String"}, 
    @{name = "Location Latitude"; dataType ="double"}, 
	@{name = "Location Longitude"; dataType ="double"}, 
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
    Write-Verbose "Creating Dataset $PowerBiDatasetName.";
    $pbiDataSet = New-PBIDataSet -authToken $PowerBiAuthToken -dataSet $dataSetSchema -verbose
}
else
{
    $pbiDataSet = Get-PBIDataSet -authToken $PowerBiAuthToken -name $PowerBiDatasetName -verbose

	if (-not $LoadDelta) {
        Write-Verbose "Clear Dataset $PowerBiDatasetName and update schema.";
		Clear-PBITableRows -authToken $PowerBiAuthToken -dataSetName $PowerBiDatasetName -tableName $table.Name -verbose
		Update-PBITableSchema -authToken $PowerBiAuthToken -dataSetId $pbiDataSet.id -table $table -verbose
	}
}

Write-Verbose 'Read Azure Resource Rate Card.';
# Create request for azure management interface
$ApiVersion = '2015-06-01-preview';
$ResourceCardUrl = "https://management.azure.com/subscriptions/{0}/providers/Microsoft.Commerce/RateCard?api-version={1}&`$filter=OfferDurableId eq '{2}' and Currency eq '{3}' and Locale eq '{4}' and RegionInfo eq '{5}'" `
                -f $subscriptionId, $ApiVersion, $AzureSubscriptionOfferDurableId, $AzureSubscriptionCurrency, $AzureSubscriptionLocale, $AzureSubscriptionRegionInfo;
$ResourceCards = Invoke-RestMethod -Uri $ResourceCardUrl -Headers $AzureAuthHeaders -ContentType 'application/json';

Write-Verbose 'Convert Resource Cards to a lookup.';
$MeterIds = @{};
$ResourceCards.Meters | ForEach { $MeterIds.Add([guid]$_.MeterId, $_); };


Write-Verbose 'Read Azure Locations.';
#$LocationCountryLookup = Get-AutomationVariable -Name 'AzureCostImport-CountryLookup';
#$LocationStateLookup = Get-AutomationVariable -Name 'AzureCostImport-StateLookup';
if ($LocationLookup -eq $null -or $LocationCountryLookup -eq $null -or $LocationStateLookup -eq $null) {
    $ApiVersion = '2015-01-01'
    $LocationUrl = 'https://management.azure.com/subscriptions/{0}/locations?api-version={1}' `
				    -f $subscriptionId, $ApiVersion;
    $LocationData = Invoke-RestMethod -Uri $LocationUrl -Headers $AzureAuthHeaders -ContentType 'application/json'

    $LocationLookup = @{};
    $LocationCountryLookup = @{};
    $LocationStateLookup = @{};

    $LocationData.value | Foreach {
	    $location = $_;
        $LocationLookup.Add($location.name, $location);
        $LocationLookup.Add($location.displayName, $location);

	    $LocationUrl = "http://maps.googleapis.com/maps/api/geocode/json?latlng={0},{1}&sensor=false" `
				    -f $location.latitude, $location.longitude
	    $LocationDetails = Invoke-RestMethod -Uri $LocationUrl -ContentType 'application/json'
	
	    $country = ($LocationDetails.results | where {$_.types[0] -eq 'country'}).formatted_address;
	    if ($country -eq $null) {
		    $country = ($LocationDetails.results[0].address_components | where {$_.types[0] -eq 'country'}).long_name;
	    }
	    $state = ($LocationDetails.results | where {$_.types[0] -eq 'administrative_area_level_1'}).formatted_address;
	    if ($state -eq $null) {
		    $state = ($LocationDetails.results[0].address_components | where {$_.types[0] -eq 'administrative_area_level_1'}).long_name;
	    }
	    if ($state -eq $null) {
		    $state = $country;
	    }
	    $LocationCountryLookup.Add($location.name, $country);
	    $LocationCountryLookup.Add($location.displayName, $country);
	    $LocationStateLookup.Add($location.name, $state);
	    $LocationStateLookup.Add($location.displayName, $state);
    }
    #Cache of Locations does not work :-(
    #Error: Variables asset not found.
    #Set-AutomationVariable -Name 'AzureCostImport-CountryLookup' -Value $LocationCountryLookup;
    #Set-AutomationVariable -Name 'AzureCostImport-StateLookup' -Value $LocationStateLookup;
}

Write-Verbose 'Read Azure Resources.';
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


#Import

function Coalesce([string]$a, [string]$b, [string]$c) { if (-not [System.String]::IsNullOrEmpty($a)) { $a.Trim() } elseif (-not [System.String]::IsNullOrEmpty($b)) { $b.Trim() } else { $c } }
filter isNumeric() {
    return $_ -is [byte]  -or $_ -is [int16]  -or $_ -is [int32]  -or $_ -is [int64]  `
       -or $_ -is [sbyte] -or $_ -is [uint16] -or $_ -is [uint32] -or $_ -is [uint64] `
       -or $_ -is [float] -or $_ -is [double] -or $_ -is [decimal]
}

if ($AzureCostGranularity -eq 'Daily') {
    $dateTimeFormat = 'yyyy-MM-dd';
}
$ApiVersion = '2015-06-01-preview';
$UsageUrl = "https://management.azure.com/subscriptions/{0}/providers/Microsoft.Commerce/UsageAggregates?api-version={1}&reportedStartTime={2}&reportedEndTime={3}&aggregationGranularity={4}&showDetails={5}" `
            -f $subscriptionId, $ApiVersion, $reportedStartTime.ToString($dateTimeFormat), $reportedEndTime.ToString($dateTimeFormat), $AzureCostGranularity, $AzureCostShowDetails;

Do {
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
                if ($resource -eq $null) {
                    $project2 = $project -replace ' - ', '/';
                    $resource = $Resources | where {$_.type -Like ('*'+$usage.InfoFields.meteredService+'*') -and $_.name -eq $project2} | select -First 1
                }
                if ($resource -eq $null) {
                    $project3 = $project.split('(')[0];
                    $resource = $Resources | where {$_.type -Like ('*'+$usage.InfoFields.meteredService+'*') -and $_.name -eq $project3} | select -First 1
                }
				if ($resource -eq $null) {
                    $resource = @{ 
                        name = $project -replace ' - ', '/'
                    }
                }
                Add-Member -InputObject $_ -MemberType NoteProperty -Name 'Resource' -Value $resource -Force

                $location = Coalesce $location $resource.location $_.InfoFields.meteredRegion;
			}
			if ($_.instanceData -ne $null) {
				$value = ConvertFrom-Json($usage.instanceData);
                $resource = $ResourceIdLookup[$value.'Microsoft.Resources'.resourceUri];
                if ($resource -eq $null) {
                    $split = $value.'Microsoft.Resources'.resourceUri.Split('/');
                    $resource = @{ 
                        name = $split[$split.Length - 1]
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
				@{n='Subscription Name'; e={$subscriptionIdLookup[[guid]$_.SubscriptionId]}}, `
				@{n='Meter Id'; e={$_.MeterId}}, `
				@{n='Meter Name'; e={Coalesce $_.Meter.MeterName $_.MeterName}}, `
				@{n='Meter Category'; e={Coalesce $_.Meter.MeterCategory $_.MeterCategory}}, `
				@{n='Meter Sub-category';e={Coalesce $_.Meter.MeterSubCategory $_.meterSubCategory}}, `
				@{n='Meter Region';e={$_.location}}, `
				@{n='Unit'; e={Coalesce $_.Meter.Unit $_.Unit}}, `
				Quantity, `
				@{n='MeterRate'; e={$_.Meter.MeterRates.0}}, `
				@{n='Cost'; e={$_.Meter.MeterRates.0 * $_.Quantity}}, `
				@{n='Location State';e={$LocationStateLookup[$_.location]}}, `
				@{n='Location Country';e={$LocationCountryLookup[$_.location]}}, `
                @{n='Location Latitude';e={$LocationLookup[$_.location].latitude}}, `
                @{n='Location Longitude';e={$LocationLookup[$_.location].longitude}}, `
				@{n='Resource';e={$_.Resource.name}}, `
				@{n='Resource Group';e={$_.Resource.ResourceGroup}}, `
				@{n='Category';e={'NA'}} | ` 
			Where-Object {$_.Cost -ne $null -and [double]$_.Cost -gt 0} | `
			Out-PowerBI -AuthToken $PowerBiAuthToken -dataSetName $PowerBiDatasetName -tableName $table.Name -batchSize 2000 -verbose
#TODO: Category and Tag
    if ($usageData.NextLink) {
		$UsageUrl = $usageData.NextLink;
	} else {
		$UsageUrl = $null;
	}
} until (-not $UsageUrl)

Set-AutomationVariable -Name $LoadDelta_AutomationVariable -Value $reportedEndTime;