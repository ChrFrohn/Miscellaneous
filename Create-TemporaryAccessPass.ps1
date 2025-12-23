<#
.SYNOPSIS
    Creates a Temporary Access Pass (TAP) for an user using Microsoft Graph API.

.DESCRIPTION
    This script uses Microsoft Graph API to create a 4-hour multi-use Temporary Access Pass for a user
    and sends it to the user's manager via email. The script:
    - Authenticates using Managed Identity
    - Retrieves user information from Entra ID
    - Gets the user's manager information
    - Creates a TAP that is immediately active for 4 hours
    - Sends the TAP to the user's manager via Microsoft Graph
    - TAP can be used multiple times within the 4-hour window
    
    Designed for execution in Azure environments with Managed Identity configured.
    Used alongside admin account creation workflows for temporary access.

.PARAMETER UserPrincipalNameOrObjectId
    The User Principal Name (UPN) or Entra ID Object ID of the user to create a TAP for.
    The TAP will be sent to this user's manager via email.
    Example: "user@christianfrohn.dk" or "12345678-1234-1234-1234-123456789012"

.EXAMPLE
    .\Create-TemporaryAccessPass.ps1 -UserPrincipalNameOrObjectId "user@christianfrohn.dk"
    Creates a TAP for the specified user and sends it to their manager

.EXAMPLE
    .\Create-TemporaryAccessPass.ps1 -UserPrincipalNameOrObjectId "12345678-1234-1234-1234-123456789012"
    Creates a TAP using the user's Object ID and sends it to their manager

.NOTES
    Author: Christian Frohn
    https://www.linkedin.com/in/frohn/
    Version: 1.0
    
    Prerequisites:
    - Azure Automation account with System-Assigned Managed Identity
    - Microsoft Graph API permissions configured for the managed identity
    - User email addresses configured in Entra ID
    
    Required Microsoft Graph API Permissions (assigned to the managed identity):
    - UserAuthenticationMethod.ReadWrite.All (Application): Create and manage TAPs
    - User.Read.All (Application): Read user profile information from Entra ID
    - Mail.Send (Application): Send email notifications

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
    $GraphApiHeaders = @{ 'Authorization' = "Bearer $GraphAccessToken" }
    
    Write-Output "SUCCESS: Authenticated to Microsoft Graph using managed identity"
}
catch {
    Write-Output "ERROR: Failed to authenticate to Microsoft Graph: $($_.Exception.Message)"
    Exit 1
}

# Determine if input is ObjectId (GUID) or UPN and construct URL
if ($UserPrincipalNameOrObjectId -match '^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$') {
    # Input is ObjectId
    $UserInfoApiUrl = "https://graph.microsoft.com/v1.0/users/${UserPrincipalNameOrObjectId}?`$select=id,userPrincipalName,displayName,mail"
    $ManagerApiUrl = "https://graph.microsoft.com/v1.0/users/${UserPrincipalNameOrObjectId}/manager?`$select=id,mail,userPrincipalName,displayName"
} else {
    # Input is UPN
    $UserInfoApiUrl = "https://graph.microsoft.com/v1.0/users/${UserPrincipalNameOrObjectId}?`$select=id,userPrincipalName,displayName,mail"
    $ManagerApiUrl = "https://graph.microsoft.com/v1.0/users/${UserPrincipalNameOrObjectId}/manager?`$select=id,mail,userPrincipalName,displayName"
}

try {
    $UserResponse = Invoke-RestMethod -Uri $UserInfoApiUrl -Headers $GraphApiHeaders -Method Get -ErrorAction Stop
    $UserId = $UserResponse.id
    $UserPrincipalName = $UserResponse.userPrincipalName
    $UserDisplayName = $UserResponse.displayName
    $UserEmail = $UserResponse.mail
    
    Write-Output "SUCCESS: Retrieved user information for $UserDisplayName ($UserPrincipalName)"
}
catch {
    Write-Output "ERROR: Failed to retrieve user information for $UserPrincipalNameOrObjectId - $($_.Exception.Message)"
    Exit 1
}

# Get user's manager information
try {
    $ManagerResponse = Invoke-RestMethod -Uri $ManagerApiUrl -Headers $GraphApiHeaders -Method Get -ErrorAction Stop
    $ManagerEmail = $ManagerResponse.mail
    $ManagerDisplayName = $ManagerResponse.displayName
    $ManagerUPN = $ManagerResponse.userPrincipalName
    $ManagerId = $ManagerResponse.id
    
    Write-Output "SUCCESS: Retrieved manager information - $ManagerDisplayName ($ManagerUPN)"
}
catch {
    Write-Output "ERROR: Failed to retrieve manager information for $UserDisplayName - $($_.Exception.Message)"
    Write-Output "ERROR: User must have a manager assigned to receive TAP"
    Exit 1
}

$TapRequestBody = @{
    isUsableOnce = $false
    lifetimeInMinutes = 240
}

$TapRequestJson = $TapRequestBody | ConvertTo-Json

# Create the Temporary Access Pass
try {
    $CreateTapUrl = "https://graph.microsoft.com/v1.0/users/$UserId/authentication/temporaryAccessPassMethods"
    $TapResponse = Invoke-RestMethod -Uri $CreateTapUrl -Headers $GraphApiHeaders -Method POST -Body $TapRequestJson -ErrorAction Stop
    
    $TemporaryAccessPass = $TapResponse.temporaryAccessPass
    $TapId = $TapResponse.id
    $TapCreatedDateTime = $TapResponse.createdDateTime
    $TapStartDateTime = $TapResponse.startDateTime
    $TapLifetime = $TapResponse.lifetimeInMinutes
    $TapUsageType = "Multi-use"
    
    Write-Output "SUCCESS: Temporary Access Pass created for $UserDisplayName"
    Write-Output "TAP ID: $TapId"
        
}
catch {
    Write-Output "ERROR: Failed to create Temporary Access Pass - $($_.Exception.Message)"
    
    # Provide additional error details if available
    if ($_.Exception.Response) {
        Write-Output "ERROR: HTTP Status Code: $($_.Exception.Response.StatusCode)"
        try {
            $errorResponse = $_.Exception.Response.GetResponseStream()
            $reader = New-Object System.IO.StreamReader($errorResponse)
            $errorContent = $reader.ReadToEnd()
            Write-Output "ERROR: Response Content: $errorContent"
        } catch {
            Write-Output "ERROR: Unable to read error response content"
        }
    }
    Exit 1
}

if ($ManagerEmail) {
    try {
        Write-Output "Sending TAP via email to manager: $ManagerEmail..."
        
        $ExpiryDateTime = [datetime]::Parse($TapCreatedDateTime).AddMinutes($TapLifetime)
        
        $EmailBody = @"
Hello $ManagerDisplayName,

A Temporary Access Pass has been created for your team member: $UserDisplayName ($UserPrincipalName)

Access Code: $TemporaryAccessPass
- Valid for: 4 hours
- Can be used multiple times
- Expires: $($ExpiryDateTime.ToString("yyyy-MM-dd HH:mm:ss")) UTC

Please provide this code securely to $UserDisplayName for their temporary access needs.

Do not share this code with others.

"@

        $EmailMessage = @{
            message = @{
                subject = "Temporary Access Pass for $UserDisplayName"
                body = @{
                    contentType = "Text"
                    content = $EmailBody
                }
                toRecipients = @(
                    @{
                        emailAddress = @{
                            address = $ManagerEmail
                            name = $ManagerDisplayName
                        }
                    }
                )
            }
            saveToSentItems = $false
        }

        $EmailJson = $EmailMessage | ConvertTo-Json -Depth 5
        
        # Send email using Graph API (requires Mail.Send permission)
        # Use manager's mailbox to send the email (application permission allows sending from any user)
        $SendEmailUrl = "https://graph.microsoft.com/v1.0/users/$ManagerId/sendMail"
        $EmailHeaders = $GraphApiHeaders.Clone()
        $EmailHeaders['Content-Type'] = 'application/json'
        
        Invoke-RestMethod -Uri $SendEmailUrl -Headers $EmailHeaders -Method POST -Body $EmailJson -ErrorAction Stop
        
        Write-Output "SUCCESS: TAP sent via email to manager: $ManagerEmail"
        
    }
    catch {
        Write-Output "WARNING: Failed to send email to manager - $($_.Exception.Message)"
        Write-Output "TAP was created successfully but email delivery to manager failed."
    }
}
else {
    Write-Output "ERROR: Manager has no email address configured - cannot send TAP"
}

Write-Output "SUCCESS: TAP created for $UserDisplayName and sent to manager $ManagerDisplayName"
