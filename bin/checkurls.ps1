#!/usr/bin/env pwsh
<#
.SYNOPSIS
Verify all download URLs in manifests are accessible.

.DESCRIPTION
Tests that all architecture URLs defined in manifest configuration are valid and return expected responses.
Useful for catching broken links before installation.

.PARAMETER App
Name of the app/manifest to check URLs for.
If not specified, checks all manifests in the bucket.

.PARAMETER Dir
Path to the bucket directory containing manifests.
If not specified, uses ../bucket relative to script location.

.EXAMPLE
# Check specific app URLs
.\checkurls.ps1 -App mario-64 -Dir bucket

# Check all manifests
.\checkurls.ps1 -Dir bucket

.OUTPUTS
Status for each URL (accessible or 404).

.LINK
https://github.com/beyondmeat/scoop-recomps
#>

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/lib-releasehelpers.ps1"

$scoopHome = Get-ScoopHome
$checkurls = "$scoopHome/bin/checkurls.ps1"
$dir = Join-Path $PSScriptRoot '..\bucket'
$arguments = Get-DirectoryArgumentList -Arguments $Args -DefaultDirectory $dir
& $checkurls @arguments

