<#
.SYNOPSIS
    Applies baseline security and branding Group Policies to the domain.

.DESCRIPTION
    1. Domain password policy: 12+ characters, complexity, 90-day expiry,
       lockout after 5 failed attempts (15 min).
    2. GPO "Bloqueo de pantalla": locks the session after N minutes idle.
    3. GPO "Fondo corporativo": company desktop wallpaper, published in
       NETLOGON so every computer in the domain can read it.
    GPOs 2 and 3 are linked to the company root OU, so they apply to every
    department below it. Idempotent, supports -WhatIf and writes a log.

.EXAMPLE
    .\New-ADLabGPOs.ps1 -WallpaperPath .\fondo-corp.jpg -WhatIf
    .\New-ADLabGPOs.ps1 -WallpaperPath .\fondo-corp.jpg -LockMinutes 5
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $RootOU = "Empresa",
    [ValidateScript({ Test-Path $_ -PathType Leaf })] [string] $WallpaperPath = ".\fondo-corp.jpg",
    [ValidateRange(1, 60)] [int] $LockMinutes = 10,
    [string] $LogDir = "C:\LabReport\logs"
)

$ErrorActionPreference = 'Stop'
Import-Module ActiveDirectory, GroupPolicy

New-Item -ItemType Directory -Path $LogDir -Force -WhatIf:$false | Out-Null
$log = Join-Path $LogDir "New-ADLabGPOs_$(Get-Date -Format yyyyMMdd_HHmmss).log"
Start-Transcript -Path $log -WhatIf:$false | Out-Null

function Write-Step([string] $status, [string] $message) {
    $color = @{ 'OK' = 'Green'; 'SKIP' = 'Yellow'; 'ERROR' = 'Red' }[$status]
    Write-Host ("[{0,-6}] {1}" -f $status, $message) -ForegroundColor $color
}

try {
    $domain = Get-ADDomain
    $target = "OU=$RootOU,$($domain.DistinguishedName)"
    Get-ADOrganizationalUnit -Identity $target | Out-Null   # fail early if the OU is missing

    # 1) Password policy: only one per domain, it lives in the Default Domain Policy
    if ($PSCmdlet.ShouldProcess($domain.DNSRoot, "Set password and lockout policy")) {
        Set-ADDefaultDomainPasswordPolicy -Identity $domain.DNSRoot `
            -MinPasswordLength 12 -ComplexityEnabled $true -PasswordHistoryCount 5 `
            -MaxPasswordAge (New-TimeSpan -Days 90) -MinPasswordAge (New-TimeSpan -Days 1) `
            -LockoutThreshold 5 -LockoutDuration (New-TimeSpan -Minutes 15) `
            -LockoutObservationWindow (New-TimeSpan -Minutes 15)
        Write-Step OK "Passwords: 12+ chars, complex, 90 days, lockout after 5 failures"
    }

    function Set-LinkedGPO([string] $name, [string] $comment, [hashtable[]] $values) {
        if (-not $PSCmdlet.ShouldProcess("$name -> $target", "Create/update and link GPO")) { return }
        $gpo = Get-GPO -Name $name -ErrorAction SilentlyContinue
        if (-not $gpo) { $gpo = New-GPO -Name $name -Comment $comment }
        foreach ($v in $values) {
            Set-GPRegistryValue -Name $name -Key $v.Key -ValueName $v.Name -Type String -Value $v.Value | Out-Null
        }
        if ((Get-GPInheritance -Target $target).GpoLinks.DisplayName -notcontains $name) {
            New-GPLink -Name $name -Target $target -LinkEnabled Yes | Out-Null
        }
        Write-Step OK "GPO '$name' linked to $RootOU"
    }

    # 2) Screen lock
    $desktop = "HKCU\Software\Policies\Microsoft\Windows\Control Panel\Desktop"
    Set-LinkedGPO "Bloqueo de pantalla" "Locks the session after $LockMinutes minutes idle" @(
        @{ Key = $desktop; Name = 'ScreenSaveActive'; Value = '1' },
        @{ Key = $desktop; Name = 'ScreenSaverIsSecure'; Value = '1' },
        @{ Key = $desktop; Name = 'ScreenSaveTimeOut'; Value = "$($LockMinutes * 60)" })

    # 3) Corporate wallpaper, served from NETLOGON (replicated by AD itself)
    $wallpaper = "\\$($domain.DNSRoot)\NETLOGON\fondo-corp.jpg"
    if ($PSCmdlet.ShouldProcess($wallpaper, "Publish wallpaper")) {
        Copy-Item -Path $WallpaperPath -Destination $wallpaper -Force
    }
    $system = "HKCU\Software\Microsoft\Windows\CurrentVersion\Policies\System"
    Set-LinkedGPO "Fondo corporativo" "Company desktop wallpaper" @(
        @{ Key = $system; Name = 'Wallpaper'; Value = $wallpaper },
        @{ Key = $system; Name = 'WallpaperStyle'; Value = '4' })   # 4 = Fill

    Write-Host "`nGPOs linked to OU=$RootOU :" -ForegroundColor Cyan
    (Get-GPInheritance -Target $target).GpoLinks | Format-Table DisplayName, Enabled, Order -AutoSize
}
catch {
    Write-Step ERROR $_.Exception.Message
    throw
}
finally {
    Stop-Transcript | Out-Null
    Write-Host "Log: $log" -ForegroundColor DarkGray
}
