$out = @()
$out += "MyInvocation.MyCommand.Path = $($MyInvocation.MyCommand.Path)"
$out += "PSCommandPath                = $PSCommandPath"
$out += "PSScriptRoot                 = $PSScriptRoot"
$out += "MainModule.FileName          = $([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)"
$out += "args                         = $($args -join ',')"
$out += "Host.Name                    = $($Host.Name)"
$f = Join-Path $PSScriptRoot 'probe_out.txt'
Set-Content -LiteralPath $f -Value $out -Encoding UTF8
Write-Host ($out -join "`n")
exit 7