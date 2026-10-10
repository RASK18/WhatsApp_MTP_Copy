param(
    [Parameter(Mandatory = $true)] [string]$Dispositivo,
    [Parameter(Mandatory = $true)] [string]$Origen,
    [Parameter(Mandatory = $true)] [string]$Destino,
    [switch]$Simular
)

$ErrorActionPreference = 'Stop'
$sh = New-Object -ComObject Shell.Application
$movil = $sh.NameSpace(17).Items() | Where-Object { $_.Name -eq $Dispositivo } | Select-Object -First 1
if ($null -eq $movil) { throw "No se encuentra el dispositivo '$Dispositivo' en Este equipo." }

$carpeta = $movil
foreach ($parte in ($Origen -split '[\\/]' | Where-Object { $_ })) {
    $siguiente = $carpeta.GetFolder.Items() |
        Where-Object { $_.IsFolder -and $_.Name -eq $parte } | Select-Object -First 1
    if ($null -eq $siguiente) { throw "No existe la carpeta '$parte' en el origen MTP '$Origen'." }
    $carpeta = $siguiente
}

$script:copiados = 0
$script:omitidos = 0
$script:diferentes = 0
$script:errores = 0

function Get-MtpSize($item) {
    try {
        $tamano = $item.ExtendedProperty('System.Size')
        if ($null -ne $tamano -and "${tamano}" -ne '') { return [long]$tamano }
    } catch { }
    return $null
}

function Wait-MtpCopy([string]$ruta, $tamanoEsperado) {
    $ultimoProgreso = [DateTime]::UtcNow
    $tamanoAnterior = -1L
    $vecesEstable = 0

    while (([DateTime]::UtcNow - $ultimoProgreso).TotalSeconds -lt 60) {
        Start-Sleep -Milliseconds 250
        if (-not [IO.File]::Exists($ruta)) { continue }

        try { $tamano = (Get-Item -LiteralPath $ruta).Length }
        catch { continue }

        if ($tamano -ne $tamanoAnterior) {
            $tamanoAnterior = $tamano
            $ultimoProgreso = [DateTime]::UtcNow
            $vecesEstable = 0
        } else {
            $vecesEstable++
        }

        if ($null -ne $tamanoEsperado -and $tamano -ne $tamanoEsperado) { continue }
        if ($null -eq $tamanoEsperado -and $vecesEstable -lt 8) { continue }

        # Comprobar que el Explorador ha liberado el archivo.
        try {
            $f = [IO.File]::Open($ruta, 'Open', 'Read', 'None')
            $f.Dispose()
            return $true
        } catch [System.IO.IOException] { }
    }
    return $false
}

function Copy-MtpFolder($fuente, [string]$carpetaLocal) {
    if (-not $Simular) { [void][IO.Directory]::CreateDirectory($carpetaLocal) }
    $destinoShell = if (-not $Simular) { $sh.NameSpace($carpetaLocal) } else { $null }
    if (-not $Simular -and $null -eq $destinoShell) { throw "No se puede abrir '$carpetaLocal'." }

    foreach ($elemento in $fuente.GetFolder.Items()) {
        $rutaLocal = Join-Path $carpetaLocal $elemento.Name
        if ($elemento.IsFolder) {
            Copy-MtpFolder $elemento $rutaLocal
            continue
        }

        $tamanoMtp = Get-MtpSize $elemento
        if ([IO.File]::Exists($rutaLocal)) {
            if ($null -ne $tamanoMtp -and
                (Get-Item -LiteralPath $rutaLocal).Length -ne $tamanoMtp) {
                $script:diferentes++
                Write-Warning "DISTINTO TAMANO, no sobrescrito: $rutaLocal"
            } else {
                $script:omitidos++
            }
            continue
        }
        if (Test-Path -LiteralPath $rutaLocal) {
            $script:errores++
            Write-Warning "El destino existe, pero no es un archivo: $rutaLocal"
            continue
        }

        if ($Simular) {
            Write-Host "[SIMULACION] Copiaria: $rutaLocal"
            $script:copiados++
            continue
        }

        Write-Host "Copiando: $rutaLocal"
        try {
            $destinoShell.CopyHere($elemento, 0)
            if (Wait-MtpCopy $rutaLocal $tamanoMtp) {
                $script:copiados++
            } else {
                $script:errores++
                Write-Warning "No se pudo confirmar la copia. Revisar el archivo: $rutaLocal"
            }
        } catch {
            $script:errores++
            Write-Warning "Error copiando '$rutaLocal': $_"
        }
    }
}

Copy-MtpFolder $carpeta $Destino
Write-Host "`nResultado: copiados/por copiar=$copiados; omitidos=$omitidos; tamano distinto=$diferentes; errores=$errores"
if ($errores -gt 0 -or $diferentes -gt 0) {
    Write-Warning 'Revisa las incidencias antes de considerar completa la copia de seguridad.'
}
