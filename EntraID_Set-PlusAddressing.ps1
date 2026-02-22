<#
.SYNOPSIS
    Sets the Mail attribute on an admin account using Plus addressing to route notifications to the manager's mailbox.

.DESCRIPTION
    This script configures Plus addressing for cloud admin accounts that don't have their own mailbox.
    It retrieves the admin account's manager (the regular user who owns the admin account) and sets
    the admin account's Mail attribute to use Plus addressing format (manager+adminaccount@domain.com).
    
    This allows PIM notifications and other email alerts for the admin account to be delivered
    to the manager's mailbox without requiring an Exchange license for the admin account.
    
    Designed for Azure Automation accounts using managed identity authentication.
    This script is intended to be used as a Custom Extension task in Entra ID Governance Lifecycle Workflows.

.PARAMETER UserPrincipalNameOrObjectId
    The User Principal Name (UPN) or Entra ID Object ID of the admin account to configure Plus addressing for.
    Example: "admin.johndoe@christianfrohn.dk" or "12345678-1234-1234-1234-123456789012"

.EXAMPLE
    .\EntraID_Set-PlusAddressing.ps1 -UserPrincipalNameOrObjectId "admin.johndoe@christianfrohn.dk"
    Sets the Mail attribute on the admin account to route notifications to the manager's mailbox using Plus addressing

.EXAMPLE
    .\EntraID_Set-PlusAddressing.ps1 -UserPrincipalNameOrObjectId "12345678-1234-1234-1234-123456789012"
    Sets Plus addressing using the admin account's Object ID

.NOTES
    Author: Christian Frohn
    https://www.linkedin.com/in/frohn/
    Version: 1.0
    
    Prerequisites:
    - Azure Automation account with System-Assigned Managed Identity
    - Admin account must have a manager assigned (set during provisioning in Part 1)
    - Manager must have a valid mail attribute with a mailbox
    
    Required Microsoft Graph API Permissions (assigned to the managed identity):
    - User.Read.All (Application): Read user profile and manager information from Entra ID
    - User.ReadWrite.All (Application): Update user mail attribute

.LINK
    https://github.com/ChrFrohn/Entra-Lifecycle-Workflows
    https://www.christianfrohn.dk
#>

param (
    [Parameter(Mandatory = $true)] 
    [string]$UserPrincipalNameOrObjectId
)

# Get access token for Microsoft Graph using managed identity
try {
    $GraphTokenUri = $env:IDENTITY_ENDPOINT + "?resource=https://graph.microsoft.com/&api-version=2019-08-01"
    $ManagedIdentityHeaders = @{ 'X-IDENTITY-HEADER' = $env:IDENTITY_HEADER }

    $GraphTokenResponse = Invoke-RestMethod -Uri $GraphTokenUri -Method Get -Headers $ManagedIdentityHeaders -ErrorAction Stop
    $GraphAccessToken = $GraphTokenResponse.access_token
    
    # Create headers for Graph API calls
    $GraphApiHeaders = @{
        'Authorization' = "Bearer $GraphAccessToken"
        'Content-Type'  = 'application/json'
    }
    
    Write-Output "SUCCESS: Authenticated to Microsoft Graph using managed identity"
}
catch {
    Write-Output "ERROR: Failed to authenticate to Microsoft Graph: $($_.Exception.Message)"
    Exit 1
}

# Determine if input is ObjectId (GUID) or UPN and construct URLs
if ($UserPrincipalNameOrObjectId -match '^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$') {
    # Input is ObjectId
    $AdminUserApiUrl = "https://graph.microsoft.com/v1.0/users/${UserPrincipalNameOrObjectId}?`$select=id,userPrincipalName,displayName,mail"
    $ManagerApiUrl = "https://graph.microsoft.com/v1.0/users/${UserPrincipalNameOrObjectId}/manager?`$select=id,mail,userPrincipalName"
} else {
    # Input is UPN - URL encode it
    $EncodedUPN = [System.Web.HttpUtility]::UrlEncode($UserPrincipalNameOrObjectId)
    $AdminUserApiUrl = "https://graph.microsoft.com/v1.0/users/${EncodedUPN}?`$select=id,userPrincipalName,displayName,mail"
    $ManagerApiUrl = "https://graph.microsoft.com/v1.0/users/${EncodedUPN}/manager?`$select=id,mail,userPrincipalName"
}

# Get admin account information
try {
    $AdminUserResponse = Invoke-RestMethod -Uri $AdminUserApiUrl -Headers $GraphApiHeaders -Method Get -ErrorAction Stop
    $AdminUserId = $AdminUserResponse.id
    $AdminUserPrincipalName = $AdminUserResponse.userPrincipalName
    $AdminDisplayName = $AdminUserResponse.displayName
    
    Write-Output "SUCCESS: Retrieved admin account information for $AdminUserPrincipalName (Display Name: $AdminDisplayName)"
}
catch {
    Write-Output "ERROR: Failed to retrieve admin account: $($_.Exception.Message)"
    Exit 1
}

# Get the admin account's manager (the regular user who owns the admin account)
try {
    $ManagerResponse = Invoke-RestMethod -Uri $ManagerApiUrl -Headers $GraphApiHeaders -Method Get -ErrorAction Stop
    $ManagerEmail = $ManagerResponse.mail
    $ManagerUPN = $ManagerResponse.userPrincipalName
    
    if (-not $ManagerEmail) {
        throw "Manager email address (mail attribute) not found. Manager must have a valid mailbox."
    }
    
    Write-Output "SUCCESS: Retrieved manager information - Email: $ManagerEmail, UPN: $ManagerUPN"
}
catch {
    Write-Output "ERROR: Failed to retrieve admin account's manager. Ensure the admin account has a manager assigned: $($_.Exception.Message)"
    Exit 1
}

# Construct Plus address from manager's email
# Format: localpart+adminidentifier@domain
try {
    $ManagerEmailParts = $ManagerEmail -split '@'
    if ($ManagerEmailParts.Count -ne 2) {
        throw "Invalid manager email format: $ManagerEmail"
    }
    
    $ManagerLocalPart = $ManagerEmailParts[0]
    $ManagerDomain = $ManagerEmailParts[1]
    
    # Extract admin identifier from admin UPN (the local part before @)
    $AdminLocalPart = ($AdminUserPrincipalName -split '@')[0]
    
    # Construct the Plus address
    $PlusAddress = "${ManagerLocalPart}+${AdminLocalPart}@${ManagerDomain}"
    
    Write-Output "SUCCESS: Constructed Plus address: $PlusAddress"
}
catch {
    Write-Output "ERROR: Failed to construct Plus address: $($_.Exception.Message)"
    Exit 1
}

# Update the admin account's mail attribute with the Plus address
try {
    $UpdateUserApiUrl = "https://graph.microsoft.com/v1.0/users/$AdminUserId"
    
    $UpdateBody = @{
        mail = $PlusAddress
    } | ConvertTo-Json
    
    Invoke-RestMethod -Uri $UpdateUserApiUrl -Headers $GraphApiHeaders -Method Patch -Body $UpdateBody -ErrorAction Stop
    
    Write-Output "SUCCESS: Updated mail attribute for admin account '$AdminUserPrincipalName' to '$PlusAddress'"
}
catch {
    Write-Output "ERROR: Failed to update mail attribute for admin account: $($_.Exception.Message)"
    
    if ($_.Exception.Response) {
        $statusCode = [int]$_.Exception.Response.StatusCode
        Write-Output "ERROR: HTTP Status Code: $statusCode"
        
        try {
            $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
            $errorContent = $reader.ReadToEnd()
            $reader.Close()
            Write-Output "ERROR: Response Content: $errorContent"
        } catch {
            Write-Output "ERROR: Unable to read error response content"
        }
    }
    
    Exit 1
}

Write-Output "SUCCESS: Plus addressing configured for admin account '$AdminUserPrincipalName'. PIM notifications will be delivered to manager's mailbox at '$ManagerEmail'"
