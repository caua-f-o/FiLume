# Teste da ponte do FiPDF.Scan (roda no build do GitHub, sem scanner).
# Uso: pwsh backend/test/ponte.ps1 <pasta do FiPDF.Scan publicado>
param([Parameter(Mandatory)] [string]$Dir)
$ErrorActionPreference = 'Stop'
$exe = Join-Path $Dir 'FiPDF.Scan.exe'
$bad = 0
function Check([string]$label, [bool]$ok, [string]$extra = '') {
  if ($ok) { Write-Host "OK $label" } else { Write-Host "FALHA $label $extra"; $script:bad++ }
}

function Start-Bridge([string]$arguments) {
  $psi = [Diagnostics.ProcessStartInfo]::new($exe, $arguments)
  $psi.RedirectStandardInput = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.UseShellExecute = $false
  $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
  $psi.Environment['FILUME_LOG_DIR'] = (Join-Path ([IO.Path]::GetTempPath()) 'fipdf-scan-teste')
  return [Diagnostics.Process]::Start($psi)
}

function Read-Json($proc, [int]$seconds = 60) {
  $task = $proc.StandardOutput.ReadLineAsync()
  if (-not $task.Wait([TimeSpan]::FromSeconds($seconds))) { throw "sem resposta do FiPDF.Scan em $seconds s" }
  $line = $task.Result
  if ($null -eq $line) { throw 'o FiPDF.Scan fechou a saída' }
  Write-Host "  < $line"
  return $line | ConvertFrom-Json
}

# --------------------------------------------------------------- pronto e comandos
$p = Start-Bridge 'servir --demo'
$ready = Read-Json $p 120
Check 'anuncia que está pronto, com a versão do protocolo' ($ready.tipo -eq 'pronto' -and $ready.versao -eq 1)
# Algum recurso do .NET desligado pelo trimming (ex.: o COM que o WIA usa) aparece como erro do driver.
$switched = @($ready.erros | Where-Object { $_.mensagem -match 'feature switch|disabled via' })
Check 'nenhum driver quebrado pelo trimming' ($switched.Count -eq 0) (($switched | ForEach-Object { "$($_.driver): $($_.mensagem)" }) -join ' | ')
$demo = $ready.dispositivos | Where-Object { $_.driver -eq 'demo' } | Select-Object -First 1
Check 'o aparelho de demonstração aparece com URL local' ($demo -and $demo.url -match '^http://127\.0\.0\.1:\d+/eSCL$') "$($demo.url)"
$port = [int]([uri]$demo.url).Port

# Só 127.0.0.1: confere quem está escutando na porta.
$listen = @(Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue)
Check 'escuta só em 127.0.0.1' ($listen.Count -ge 1 -and @($listen | Where-Object { $_.LocalAddress -ne '127.0.0.1' }).Count -eq 0) (($listen | ForEach-Object LocalAddress) -join ', ')

$caps = Invoke-WebRequest "$($demo.url)/ScannerCapabilities" -UseBasicParsing -TimeoutSec 20
Check 'responde o eSCL (ScannerCapabilities) em 127.0.0.1' ($caps.StatusCode -eq 200 -and $caps.Content -match 'FiPDF Demonstra')
Check 'capacidades do aparelho: as que ele informou (A4, sem o 4800 dpi genérico)' ($caps.Content -match 'PlatenInputCaps' -and $caps.Content -match 'AdfDuplexInputCaps' -and $caps.Content -match 'FiPDFAutoSource' -and $caps.Content -match '<scan:MaxWidth>2480<' -and $caps.Content -notmatch '4800')
$status = Invoke-WebRequest "$($demo.url)/ScannerStatus" -UseBasicParsing -TimeoutSec 20
Check 'parado, não inventa estado do alimentador' ($status.StatusCode -eq 200 -and $status.Content -notmatch 'AdfState') $status.Content

# Pelo IP de rede da máquina, não pode responder.
$ip = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } | Select-Object -First 1).IPAddress
if ($ip) {
  $reached = $false
  try { Invoke-WebRequest "http://${ip}:$port/eSCL/ScannerCapabilities" -UseBasicParsing -TimeoutSec 5 | Out-Null; $reached = $true } catch { }
  Check "não responde pelo IP da rede ($ip)" (-not $reached)
}

# Digitaliza a página de demonstração pelo eSCL, como o cliente do FiPDF faz.
$settings = '<?xml version="1.0" encoding="UTF-8"?><scan:ScanSettings xmlns:scan="http://schemas.hp.com/imaging/escl/2011/05/03" xmlns:pwg="http://www.pwg.org/schemas/2010/12/sm"><pwg:Version>2.6</pwg:Version><pwg:InputSource>Platen</pwg:InputSource><scan:ColorMode>RGB24</scan:ColorMode><scan:XResolution>300</scan:XResolution><scan:YResolution>300</scan:YResolution><pwg:DocumentFormat>image/jpeg</pwg:DocumentFormat></scan:ScanSettings>'
$job = Invoke-WebRequest "$($demo.url)/ScanJobs" -Method Post -Body $settings -ContentType 'text/xml' -UseBasicParsing -TimeoutSec 20
$location = "$($job.Headers['Location'])"
Check 'cria o trabalho de digitalização' ($job.StatusCode -eq 201 -and $location -match '/eSCL/ScanJobs/')
$jpg = Join-Path ([IO.Path]::GetTempPath()) 'fipdf-demo.jpg'
Invoke-WebRequest "$location/NextDocument" -UseBasicParsing -TimeoutSec 30 -OutFile $jpg
$bytes = [IO.File]::ReadAllBytes($jpg)
Check 'recebe a página (JPEG)' ($bytes.Length -gt 1000 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xD8) "$($bytes.Length) bytes"
$second = $null
try { $second = Invoke-WebRequest "$location/NextDocument" -UseBasicParsing -TimeoutSec 30 } catch { $second = $_.Exception.Response }
Check 'depois da última página, NextDocument responde 404' ([int]$second.StatusCode -eq 404) "$([int]$second.StatusCode)"

# Origem automática (extensão do FiPDF).
$auto = $settings.Replace('<pwg:InputSource>Platen</pwg:InputSource>', '<pwg:InputSource>Auto</pwg:InputSource>')
$job2 = Invoke-WebRequest "$($demo.url)/ScanJobs" -Method Post -Body $auto -ContentType 'text/xml' -UseBasicParsing -TimeoutSec 20
Check 'aceita a origem "Auto"' ($job2.StatusCode -eq 201)
Invoke-WebRequest "$($job2.Headers['Location'])/NextDocument" -UseBasicParsing -TimeoutSec 30 -OutFile $jpg

$p.StandardInput.WriteLine('ping')
Check 'ping → pong' ((Read-Json $p).tipo -eq 'pong')
$p.StandardInput.WriteLine('{"comando":"listar"}')
$l = Read-Json $p
Check 'listar (em JSON) devolve os aparelhos' ($l.tipo -eq 'dispositivos' -and @($l.dispositivos | Where-Object driver -eq 'demo').Count -eq 1)
$p.StandardInput.WriteLine('xyz')
Check 'comando desconhecido vira erro em português' ((Read-Json $p).codigo -eq 'comando-desconhecido')
$p.StandardInput.WriteLine('atualizar')
$a = Read-Json $p 120
$demo2 = $a.dispositivos | Where-Object driver -eq 'demo' | Select-Object -First 1
Check 'atualizar refaz os servidores' ($a.tipo -eq 'dispositivos' -and $demo2.url -match '^http://127\.0\.0\.1:')
$p.StandardInput.WriteLine('sair')
Check 'sair → tchau' ((Read-Json $p).tipo -eq 'tchau')
Check 'encerra depois de sair' ($p.WaitForExit(15000) -and $p.ExitCode -eq 0) "$($p.ExitCode)"

# ------------------------------------------------- o FiPDF some: o auxiliar também
$p = Start-Bridge 'servir --demo'
$null = Read-Json $p 120
$p.StandardInput.Close()
Check 'stdin fechado (FiPDF fechou) → encerra sozinho' ($p.WaitForExit(15000))

$parent = Start-Process pwsh -ArgumentList '-NoProfile', '-Command', 'Start-Sleep 3' -PassThru
$p = Start-Bridge "servir --pai $($parent.Id)"
$null = Read-Json $p 120
Check 'processo pai (--pai) terminou → encerra sozinho' ($p.WaitForExit(20000))

# ------------------------------------------------------------------ porta fixa
$p = Start-Bridge 'servir --demo --porta 18765'
$r = Read-Json $p 120
Check '--porta N usa a porta pedida' (@($r.dispositivos | Where-Object url -eq 'http://127.0.0.1:18765/eSCL').Count -eq 1) (($r.dispositivos | ForEach-Object url) -join ', ')
$p.StandardInput.WriteLine('sair'); $null = $p.WaitForExit(15000)

$log = Join-Path ([IO.Path]::GetTempPath()) 'fipdf-scan-teste/fipdf-scan.log'
Check 'grava o log' ((Test-Path $log) -and (Get-Content $log -Raw) -match 'FiPDF Demonstra')
Check 'o log registra a origem Auto do pedido' ((Get-Content $log -Raw) -match 'origem Auto')

if ($bad -gt 0) { Write-Host "$bad problemas"; exit 1 }
Write-Host 'Tudo certo.'
