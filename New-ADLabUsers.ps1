<#
.SYNOPSIS
    Builds a company structure in Active Directory from a CSV file:
    department OUs, security groups, users and shared folders.

.DESCRIPTION
    - Root OU (default "Empresa") with one child OU per department.
    - Global security group "GG_<Department>" inside each department OU.
    - Users named firstname.lastname (accents removed), random initial password,
      password change forced at first logon, added to their department group.
    - C:\Compartido\<Department> shared over SMB, NTFS Modify only for its group.
    - Idempotent: anything that already exists is skipped, so it is safe to re-run.
    - Supports -WhatIf (dry run) and writes a full log of every run.

.PARAMETER CsvPath
    CSV with the columns FirstName, LastName, Department, Title.

.EXAMPLE
    .\New-ADLabUsers.ps1 -CsvPath .\employees.csv -WhatIf    # simulate, change nothing
    .\New-ADLabUsers.ps1 -CsvPath .\employees.csv            # apply
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)] [ValidateScript({ Test-Path $_ -PathType Leaf })] [string] $CsvPath,
    [string] $RootOU = "Empresa",
    [string] $ShareRoot = "C:\Compartido",
    [string] $ReportPath = "C:\LabReport\created_users.csv",
    [string] $LogDir = "C:\LabReport\logs"
)

$ErrorActionPreference = 'Stop'
Import-Module ActiveDirectory

New-Item -ItemType Directory -Path $LogDir -Force -WhatIf:$false | Out-Null
$log = Join-Path $LogDir "New-ADLabUsers_$(Get-Date -Format yyyyMMdd_HHmmss).log"
Start-Transcript -Path $log -WhatIf:$false | Out-Null

function Write-Step([string] $status, [string] $message) {
    $color = @{ 'OK' = 'Green'; 'SKIP' = 'Yellow'; 'ERROR' = 'Red' }[$status]
    Write-Host ("[{0,-6}] {1}" -f $status, $message) -ForegroundColor $color
}

function Remove-Accents([string] $text) {
    $normalized = $text.Normalize([Text.NormalizationForm]::FormD)
    -join ($normalized.ToCharArray() | Where-Object {
        [Globalization.CharUnicodeInfo]::GetUnicodeCategory($_) -ne 'NonSpacingMark' })
}

function Test-OU([string] $name, [string] $parentDN) {
    # Get-ADOrganizationalUnit throws (not just errors) if the parent does not exist yet,
    # which happens in -WhatIf runs where the root OU was only simulated
    try { [bool](Get-ADOrganizationalUnit -Filter "Name -eq '$name'" -SearchBase $parentDN -SearchScope OneLevel) }
    catch { $false }
}

function New-RandomPassword {
    $chars = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789'
    $bytes = New-Object byte[] 12
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    $body = -join ($bytes | ForEach-Object { $chars[$_ % $chars.Length] })
    "$body#$(Get-Random -Minimum 10 -Maximum 99)"
}

try {
    # --- Validate the CSV before touching AD ---------------------------------
    $employees = @(Import-Csv -Path $CsvPath -Encoding UTF8)
    $required = 'FirstName', 'LastName', 'Department', 'Title'
    $missing = $required | Where-Object { $_ -notin $employees[0].PSObject.Properties.Name }
    if ($missing) { throw "CSV is missing columns: $($missing -join ', ')" }
    $row = 1
    foreach ($e in $employees) {
        $row++
        foreach ($col in 'FirstName', 'LastName', 'Department') {
            if ([string]::IsNullOrWhiteSpace($e.$col)) { throw "CSV line ${row}: '$col' is empty" }
        }
    }
    Write-Step OK "CSV valid: $($employees.Count) employees"

    $domain = Get-ADDomain
    $netbios = $domain.NetBIOSName
    $rootDN = "OU=$RootOU,$($domain.DistinguishedName)"

    # --- Root OU ---------------------------------------------------------------
    if (Test-OU $RootOU $domain.DistinguishedName) {
        Write-Step SKIP "OU $RootOU already exists"
    } elseif ($PSCmdlet.ShouldProcess($rootDN, "Create OU")) {
        New-ADOrganizationalUnit -Name $RootOU -Path $domain.DistinguishedName
        Write-Step OK "OU $RootOU"
    }

    # --- Departments: OU + group + shared folder ------------------------------
    foreach ($dept in ($employees.Department | Sort-Object -Unique)) {
        $deptDN = "OU=$dept,$rootDN"
        $plain = Remove-Accents $dept
        $group = "GG_$plain"

        if (Test-OU $dept $rootDN) {
            Write-Step SKIP "OU $dept already exists"
        } elseif ($PSCmdlet.ShouldProcess($deptDN, "Create OU")) {
            New-ADOrganizationalUnit -Name $dept -Path $rootDN
            Write-Step OK "OU $dept"
        }

        if (Get-ADGroup -Filter "Name -eq '$group'") {
            Write-Step SKIP "Group $group already exists"
        } elseif ($PSCmdlet.ShouldProcess($group, "Create security group")) {
            New-ADGroup -Name $group -GroupScope Global -GroupCategory Security -Path $deptDN `
                -Description "Members of the $dept department"
            Write-Step OK "Group $group"
        }

        $folder = Join-Path $ShareRoot $plain
        if (Get-SmbShare -Name $plain -ErrorAction SilentlyContinue) {
            Write-Step SKIP "Share \\$env:COMPUTERNAME\$plain already exists"
        } elseif ($PSCmdlet.ShouldProcess($folder, "Create folder and SMB share \\$env:COMPUTERNAME\$plain")) {
            New-Item -ItemType Directory -Path $folder -Force | Out-Null
            $acl = Get-Acl $folder
            $acl.SetAccessRuleProtection($true, $false)   # stop inheriting "Users: Read"
            foreach ($id in "BUILTIN\Administrators", "NT AUTHORITY\SYSTEM") {
                $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(
                    $id, "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow")))
            }
            $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(
                "$netbios\$group", "Modify", "ContainerInherit,ObjectInherit", "None", "Allow")))
            Set-Acl -Path $folder -AclObject $acl
            New-SmbShare -Name $plain -Path $folder -FullAccess "$netbios\$group" `
                -ChangeAccess "$netbios\Domain Admins" | Out-Null
            Write-Step OK "Share \\$env:COMPUTERNAME\$plain (Modify: $group only)"
        }
    }

    # --- Users -----------------------------------------------------------------
    $report = @()
    foreach ($e in $employees) {
        $sam = (Remove-Accents "$($e.FirstName).$($e.LastName)").ToLower() -replace '[^a-z0-9.]', ''
        if ($sam.Length -gt 20) { $sam = $sam.Substring(0, 20) }   # sAMAccountName limit

        if (Get-ADUser -Filter "SamAccountName -eq '$sam'") {
            Write-Step SKIP "User $sam already exists"
            continue
        }
        if (-not $PSCmdlet.ShouldProcess("$sam ($($e.Department))", "Create user")) { continue }

        $password = New-RandomPassword
        New-ADUser -Name "$($e.FirstName) $($e.LastName)" -GivenName $e.FirstName -Surname $e.LastName `
            -SamAccountName $sam -UserPrincipalName "$sam@$($domain.DNSRoot)" `
            -DisplayName "$($e.FirstName) $($e.LastName)" -Title $e.Title -Department $e.Department `
            -Path "OU=$($e.Department),$rootDN" `
            -AccountPassword (ConvertTo-SecureString $password -AsPlainText -Force) `
            -ChangePasswordAtLogon $true -Enabled $true
        Add-ADGroupMember -Identity "GG_$(Remove-Accents $e.Department)" -Members $sam

        $report += [pscustomobject]@{
            User = $sam; Name = "$($e.FirstName) $($e.LastName)"
            Department = $e.Department; InitialPassword = $password
        }
        Write-Step OK "User $sam ($($e.Department))"
    }

    if ($report) {
        New-Item -ItemType Directory -Path (Split-Path $ReportPath) -Force | Out-Null
        $report | Export-Csv -Path $ReportPath -NoTypeInformation -Encoding UTF8 -Append
        Write-Host "`n$($report.Count) users created. Initial passwords: $ReportPath" -ForegroundColor Cyan
        Write-Host "Hand them over through a secure channel, then delete that file." -ForegroundColor Cyan
    }
}
catch {
    Write-Step ERROR $_.Exception.Message
    throw
}
finally {
    Stop-Transcript | Out-Null
    Write-Host "Log: $log" -ForegroundColor DarkGray
}
