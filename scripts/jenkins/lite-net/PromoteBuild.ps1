<#
.SYNOPSIS
    A tool for changing the version, and release notes, of a given version of the Couchbase Lite nuget packages
.DESCRIPTION
    This tool will unzip the package, change the nuget version and release notes, then repackage in the same directory
.PARAMETER Product
    The product name,i.e. couchbase-lite-net, couchbase-lite-net-extensions
.PARAMETER InVersion
    The existing version of the libraries to modify
.PARAMETER OutVersion
    The version to modify the libraries to
.PARAMETER ReleaseNotes
    If supplied, the new release notes will be read from the specified file and replaced in the package metadata
    If specified, will push to Couchbase's internal feed
.EXAMPLE
    C:\PS> .\PromoteBuild.ps1 -Product couchbase-lite-net -InVersion 2.0.0-b0001 -OutVersion 2.0.0-db001
    Changes couchbase-lite-net libraries's version from 2.0.0-b0001 to 2.0.0-db001
.EXAMPLE
    C:\PS> .\PromoteBuild.ps1 -Product couchbase-lite-net -InVersion 2.0.0-b0001 -OutVersion 2.0.0 -ReleaseNotes notes.txt
    Changes couchbase-lite-net libraries's version from 2.0.0-b0001 to 2.0.0 and modifies the release notes to contain the content in notes.txt
#>
param(
    [Parameter(Mandatory=$true, HelpMessage="The product")][string]$Product,
    [Parameter(Mandatory=$true, HelpMessage="The existing version of the libraries to modify")][string]$InVersion,
    [Parameter(Mandatory=$true, HelpMessage="The version to modify the libraries to")][string]$OutVersion,
    [string]$ReleaseNotes
)

function Take-While() {
    param( [scriptblock]$pred = $(throw "Need a predicate") )
    begin {
        $take = $true
    } process {
        if($take) {
            $take = & $pred $_
            if($take) {
                $_
            }
        } else {
            return
        }
    }
    
}

Push-Location $PSScriptRoot
try {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $ErrorActionPreference = "Stop"

    if($ReleaseNotes) {
        $ReleaseNotes = Resolve-Path -Path $ReleaseNotes
    }

    $Version1 = $InVersion.StartsWith("1")
    $Version31Up = -not $Version1 -and -not $InVersion.StartsWith("2") -and -not $InVersion.StartsWith("3.0")
    $buildlessVersion = $InVersion.Split("-")[0]
    $numericBuildNumber = $InVersion.Split("-")[1].TrimStart('b', '0')

    switch ($Product) {
        "couchbase-lite-net" {
            if ($Version31Up) {
                $package_names = "Couchbase.Lite","Couchbase.Lite.Enterprise","Couchbase.Lite.Support.Android","Couchbase.Lite.Support.iOS","Couchbase.Lite.Support.NetDesktop","Couchbase.Lite.Support.UWP","Couchbase.Lite.Support.WinUI","Couchbase.Lite.Enterprise.Support.Android","Couchbase.Lite.Enterprise.Support.iOS","Couchbase.Lite.Enterprise.Support.NetDesktop","Couchbase.Lite.Enterprise.Support.UWP","Couchbase.Lite.Enterprise.Support.WinUI"
                $snupkg_names = "Couchbase.Lite","Couchbase.Lite.Enterprise"
            } else {
                $package_names = "Couchbase.Lite","Couchbase.Lite.Enterprise","Couchbase.Lite.Support.Android","Couchbase.Lite.Support.iOS","Couchbase.Lite.Support.NetDesktop","Couchbase.Lite.Support.UWP","Couchbase.Lite.Enterprise.Support.Android","Couchbase.Lite.Enterprise.Support.iOS","Couchbase.Lite.Enterprise.Support.NetDesktop","Couchbase.Lite.Enterprise.Support.UWP"
                $snupkg_names = ""
            }
        }
        "couchbase-lite-net-extensions" {
            $package_names = "Couchbase.Lite.Extensions"
            $snupkg_names = "Couchbase.Lite.Extensions"
        }
        default {
            Write-Host "$Product is not supported."
        }
    }
    foreach($package in $package_names) {
        Write-Host "Downloading https://proget.sc.couchbase.com/nuget/CI/package/$package/$InVersion..."
        Invoke-WebRequest https://proget.sc.couchbase.com/nuget/CI/package/$package/$InVersion -OutFile "${package}.${InVersion}.nupkg"
    }
    foreach($snupkg in $snupkg_names) {
        Write-Host "Downloading http://latestbuilds.service.couchbase.com/builds/latestbuilds/${Product}/${buildlessVersion}/${numericBuildNumber}/${snupkg}.${InVersion}.snupkg"
        Invoke-WebRequest http://latestbuilds.service.couchbase.com/builds/latestbuilds/${Product}/${buildlessVersion}/${numericBuildNumber}/${snupkg}.${InVersion}.snupkg -OutFile "${snupkg}.${InVersion}.snupkg"
    }

    foreach($file in (Get-ChildItem $pwd -Filter *.*nupkg)) {
        $packageExtension = [System.IO.Path]::GetExtension($file.Name).TrimStart('.')
        $packageComponents = [System.IO.Path]::GetFileNameWithoutExtension($file.Name).Split('.') | Take-While { -Not [System.Char]::IsDigit($args[0][0]) }
        $package = [System.String]::Join(".", $packageComponents)
        Remove-Item -Recurse -Force $package -ErrorAction Ignore
        New-Item -ItemType Directory $package
        [System.IO.Compression.ZipFile]::ExtractToDirectory((Join-Path (Get-Location) "${package}.${InVersion}.$packageExtension"), (Join-Path (Get-Location) $package))
        Push-Location $package
        $stringContent = (Get-Content -Path "${package}.nuspec").Replace($InVersion, $OutVersion)
        $nuspec = [xml]$stringContent

        if($ReleaseNotes) {
            $nuspec.package.metadata.releaseNotes = $(Get-Content $ReleaseNotes) -join "`r`n"
        }

        $nuspec.Save([System.IO.Path]::Combine($pwd, "${package}.nuspec"))
        Pop-Location

        Remove-Item -Path "$package.$OutVersion.$packageExtension" -ErrorAction Ignore -Force
        & 7z a -tzip "$package.$OutVersion.$packageExtension" ".\$package\*"
        Remove-Item -Recurse -Force -Path $package
        Remove-Item -Force -Path "${package}.${InVersion}.$packageExtension"
    }
} finally {
    Pop-Location
}
