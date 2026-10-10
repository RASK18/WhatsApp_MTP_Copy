<#
.SYNOPSIS
    Copia dos carpetas MTP y pregunta al final por los archivos de distinto tamano.
.DESCRIPTION
    Procesa Origen1 -> Destino1 y Origen2 -> Destino2. Los valores omitidos,
    vacios o con solo espacios usan los predeterminados. Los archivos existentes
    del mismo tamano, o cuyo tamano MTP no esta disponible, se omiten.
    -Simular muestra las copias y los conflictos sin escribir ni pedir decisiones.
.EXAMPLE
    .\Copia_MTP_Incremental.ps1 -Dispositivo 'Mi movil'
.EXAMPLE
    .\Copia_MTP_Incremental.ps1 -Dispositivo 'Mi movil' -Simular
#>
param(
    [Parameter(Mandatory = $true)] [ValidateNotNullOrEmpty()] [string]$Dispositivo,
    [string]$Origen1 = 'Almacenamiento de dispositivo interno\Android\data\com.whatsapp',
    [string]$Origen2 = 'Almacenamiento de dispositivo interno\Android\media\com.whatsapp',
    [string]$Destino1 = '%UserProfile%\Desktop\{{Dispositivo}}\data\com.whatsapp',
    [string]$Destino2 = '%UserProfile%\Desktop\{{Dispositivo}}\media\com.whatsapp',
    [switch]$Simular
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($Origen1)) { $Origen1 = 'Almacenamiento de dispositivo interno\Android\data\com.whatsapp' }
if ([string]::IsNullOrWhiteSpace($Origen2)) { $Origen2 = 'Almacenamiento de dispositivo interno\Android\media\com.whatsapp' }
if ([string]::IsNullOrWhiteSpace($Destino1)) { $Destino1 = '%UserProfile%\Desktop\{{Dispositivo}}\data\com.whatsapp' }
if ([string]::IsNullOrWhiteSpace($Destino2)) { $Destino2 = '%UserProfile%\Desktop\{{Dispositivo}}\media\com.whatsapp' }

$script:copiados = 0
$script:omitidos = 0
$script:diferentes = 0
$script:errores = 0
$script:resueltos = 0
$script:conservados = 0
$script:reemplazados = 0
$script:ambos = 0
$script:conflictos = New-Object 'System.Collections.Generic.List[object]'

function Resolve-LocalDestination([string]$ruta) {
    if ($ruta.Contains('{{Dispositivo}}') -and
        ($Dispositivo.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0 -or
         $Dispositivo -match '[. ]$' -or $Dispositivo -match '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\.|$)')) {
        throw 'El nombre del dispositivo no es valido como carpeta de Windows. Indica destinos sin {{Dispositivo}}.'
    }
    $expandida = [Environment]::ExpandEnvironmentVariables($ruta).Replace('{{Dispositivo}}', $Dispositivo)
    return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($expandida)
}

function Get-MtpFolder($dispositivoMtp, [string]$ruta) {
    $carpeta = $dispositivoMtp
    foreach ($parte in ($ruta -split '[\\/]' | Where-Object { $_ })) {
        $siguiente = $carpeta.GetFolder.Items() |
            Where-Object { $_.IsFolder -and $_.Name -eq $parte } | Select-Object -First 1
        if ($null -eq $siguiente) { throw "No existe o no es accesible la carpeta '$parte' en el origen MTP '$ruta'." }
        $carpeta = $siguiente
    }
    return $carpeta
}

function Get-MtpSize($item) {
    try {
        $tamano = $item.ExtendedProperty('System.Size')
        if ($null -ne $tamano -and "${tamano}" -ne '') { return [long]$tamano }
    } catch { }
    return $null
}

function Get-MtpModified($item) {
    try {
        $fecha = $item.ExtendedProperty('System.DateModified')
        if ($null -ne $fecha -and "$fecha" -ne '') { return [datetime]$fecha }
    } catch { }
    try {
        $fecha = $item.ModifyDate
        if ($null -ne $fecha -and "$fecha" -ne '') { return [datetime]$fecha }
    } catch { }
    return $null
}

function Format-Modified($fecha) {
    if ($null -eq $fecha) { return 'No disponible' }
    if ($fecha.Kind -eq [DateTimeKind]::Utc) { $fecha = $fecha.ToLocalTime() }
    return $fecha.ToString('yyyy-MM-dd HH:mm:ss')
}

function Format-Size($tamano) {
    if ($null -eq $tamano) { return 'No disponible' }
    return ('{0:N0} bytes' -f $tamano)
}

function Wait-MtpCopy([string]$ruta, $tamanoEsperado) {
    $ultimoProgreso = [DateTime]::UtcNow
    $tamanoAnterior = -1L
    $vecesEstable = 0

    while (([DateTime]::UtcNow - $ultimoProgreso).TotalSeconds -lt 60) {
        Start-Sleep -Milliseconds 250
        if (-not [IO.File]::Exists($ruta)) { continue }

        try { $tamano = (Get-Item -LiteralPath $ruta -Force).Length }
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

function Copy-MtpFolder($fuente, [string]$carpetaLocal, [string]$rutaMtp) {
    if (-not $Simular) { [void][IO.Directory]::CreateDirectory($carpetaLocal) }
    $destinoShell = if (-not $Simular) { $sh.NameSpace($carpetaLocal) } else { $null }
    if (-not $Simular -and $null -eq $destinoShell) { throw "No se puede abrir '$carpetaLocal'." }

    foreach ($elemento in $fuente.GetFolder.Items()) {
        try {
            $rutaLocal = Join-Path $carpetaLocal $elemento.Name
            $rutaElementoMtp = "$rutaMtp\$($elemento.Name)"
            if ($elemento.IsFolder) {
                Copy-MtpFolder $elemento $rutaLocal $rutaElementoMtp
                continue
            }

            $tamanoMtp = Get-MtpSize $elemento
            if ([IO.File]::Exists($rutaLocal)) {
                $archivoLocal = Get-Item -LiteralPath $rutaLocal -Force
                if ($null -ne $tamanoMtp -and $archivoLocal.Length -ne $tamanoMtp) {
                    $script:diferentes++
                    $script:conflictos.Add([pscustomobject]@{
                        Elemento = $elemento
                        RutaMtp = $rutaElementoMtp
                        RutaLocal = $rutaLocal
                    })
                    Write-Host "DISTINTO TAMANO, pendiente para el final: $rutaLocal"
                } else {
                    $script:omitidos++
                }
                continue
            }
            if (Test-Path -LiteralPath $rutaLocal) {
                throw "El destino existe, pero no es un archivo: $rutaLocal"
            }

            if ($Simular) {
                Write-Host "[SIMULACION] Copiaria: $rutaLocal"
                $script:copiados++
                continue
            }

            Write-Host "Copiando: $rutaLocal"
            $destinoShell.CopyHere($elemento, 0)
            if (Wait-MtpCopy $rutaLocal $tamanoMtp) {
                $script:copiados++
            } else {
                $script:errores++
                Write-Warning "No se pudo confirmar la copia. Revisar el archivo: $rutaLocal"
            }
        } catch {
            $script:errores++
            Write-Warning "Error procesando '$($elemento.Name)' en '$rutaMtp': $_"
        }
    }
}

function Get-AlternativePath([string]$ruta) {
    $directorio = [IO.Path]::GetDirectoryName($ruta)
    $nombre = [IO.Path]::GetFileNameWithoutExtension($ruta)
    $extension = [IO.Path]::GetExtension($ruta)
    $alternativa = Join-Path $directorio "$nombre (dispositivo)$extension"
    $numero = 2
    while (Test-Path -LiteralPath $alternativa) {
        $alternativa = Join-Path $directorio "$nombre (dispositivo $numero)$extension"
        $numero++
    }
    return $alternativa
}

function Copy-MtpConflict($conflicto, [string]$accion, [long]$tamanoMtp, $fechaMtp, $archivoLocal) {
    $tamanoLocal = $archivoLocal.Length
    $fechaLocalUtc = $archivoLocal.LastWriteTimeUtc
    $directorio = [IO.Path]::GetDirectoryName($conflicto.RutaLocal)
    $temporal = Join-Path $directorio ('.mtp-conflicto-' + [guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($temporal)
    $rutaTemporal = Join-Path $temporal $conflicto.Elemento.Name

    try {
        $temporalShell = $sh.NameSpace($temporal)
        if ($null -eq $temporalShell) { throw "No se puede abrir '$temporal'." }
        $temporalShell.CopyHere($conflicto.Elemento, 0)
        if (-not (Wait-MtpCopy $rutaTemporal $tamanoMtp)) {
            throw 'No se pudo confirmar la copia temporal. El archivo local no se ha reemplazado.'
        }

        $tamanoActualMtp = Get-MtpSize $conflicto.Elemento
        $fechaActualMtp = Get-MtpModified $conflicto.Elemento
        if ($null -eq $tamanoActualMtp -or $tamanoActualMtp -ne $tamanoMtp -or
            ($null -ne $fechaMtp -and $fechaActualMtp -ne $fechaMtp)) {
            throw 'El origen ha cambiado o no se puede verificar. El archivo local no se ha reemplazado.'
        }

        if ($accion -eq 'R') {
            $actualLocal = Get-Item -LiteralPath $conflicto.RutaLocal -Force
            if ($actualLocal.PSIsContainer -or $actualLocal.Length -ne $tamanoLocal -or
                $actualLocal.LastWriteTimeUtc -ne $fechaLocalUtc) {
                throw 'El archivo local ha cambiado desde la pregunta. No se reemplazara con una decision anterior.'
            }
            # La transferencia termina antes de sustituir el archivo existente.
            [IO.File]::Replace($rutaTemporal, $conflicto.RutaLocal, [NullString]::Value)
            $script:reemplazados++
            Write-Host "Reemplazado: $($conflicto.RutaLocal)"
        } else {
            $rutaAlternativa = Get-AlternativePath $conflicto.RutaLocal
            # File.Move falla si otro proceso ocupa el nombre; nunca sobrescribe.
            [IO.File]::Move($rutaTemporal, $rutaAlternativa)
            $script:ambos++
            Write-Host "Conservadas ambas versiones. Copia del dispositivo: $rutaAlternativa"
        }
        $script:copiados++
        $script:resueltos++
    } catch {
        # CopyHere puede seguir transfiriendo: no eliminar esta carpeta si falla.
        Write-Warning "Carpeta temporal conservada para revisar: $temporal"
        throw
    }

    try { [IO.Directory]::Delete($temporal, $false) }
    catch { Write-Warning "La copia esta confirmada, pero no se pudo retirar la carpeta temporal vacia: $temporal" }
}

function Resolve-MtpConflicts {
    if ($script:conflictos.Count -eq 0) { return }
    Write-Host "`nTerminado el recorrido de los dos origenes. Conflictos: $($script:conflictos.Count)"
    $numero = 0
    foreach ($conflicto in $script:conflictos) {
        $numero++
        try {
            $archivoLocal = Get-Item -LiteralPath $conflicto.RutaLocal -Force
            if ($archivoLocal.PSIsContainer) { throw 'El destino ya no es un archivo.' }
            $tamanoMtp = Get-MtpSize $conflicto.Elemento
            $fechaMtp = Get-MtpModified $conflicto.Elemento

            Write-Host "`nConflicto $numero de $($script:conflictos.Count)"
            Write-Host "Origen ($Dispositivo): $($conflicto.RutaMtp)"
            Write-Host "Destino: $($conflicto.RutaLocal)"
            @(
                [pscustomobject]@{
                    Version = 'Dispositivo'
                    Nombre = $conflicto.Elemento.Name
                    Modificacion = Format-Modified $fechaMtp
                    Tamano = Format-Size $tamanoMtp
                }
                [pscustomobject]@{
                    Version = 'Local (PC)'
                    Nombre = $archivoLocal.Name
                    Modificacion = Format-Modified $archivoLocal.LastWriteTime
                    Tamano = Format-Size $archivoLocal.Length
                }
            ) | Format-List Version, Nombre, Modificacion, Tamano | Out-String -Width 4096 | Write-Host

            if ($Simular) {
                Write-Host '[SIMULACION] Se preguntaria al final: conservar local, reemplazar o conservar ambas.'
                continue
            }

            do {
                Write-Host '[C] Conservar la version local (predeterminado)'
                Write-Host '[R] Reemplazar la version local por la del dispositivo'
                Write-Host '[A] Conservar ambas; guardar la del dispositivo con otro nombre'
                $respuesta = Read-Host 'Elige C, R o A; Intro conserva la local'
                $accion = if ([string]::IsNullOrWhiteSpace($respuesta)) { 'C' } else { $respuesta.Trim().ToUpperInvariant() }
                if ($accion -notin @('C', 'R', 'A')) { Write-Warning 'Opcion no valida.' }
            } while ($accion -notin @('C', 'R', 'A'))

            if ($accion -eq 'C') {
                $script:conservados++
                $script:resueltos++
                Write-Host "Conservada la version local: $($conflicto.RutaLocal)"
                continue
            }
            if ($null -eq $tamanoMtp) { throw 'No se puede consultar el tamano del origen. El conflicto queda pendiente.' }
            Copy-MtpConflict $conflicto $accion $tamanoMtp $fechaMtp $archivoLocal
        } catch {
            $script:errores++
            Write-Warning "Conflicto pendiente en '$($conflicto.RutaLocal)': $_"
        }
    }
}

$sh = New-Object -ComObject Shell.Application
$movil = $sh.NameSpace(17).Items() | Where-Object { $_.Name -eq $Dispositivo } | Select-Object -First 1
if ($null -eq $movil) { throw "No se encuentra el dispositivo '$Dispositivo' en Este equipo." }

$pares = @(
    [pscustomobject]@{ Origen = $Origen1; Destino = $Destino1 }
    [pscustomobject]@{ Origen = $Origen2; Destino = $Destino2 }
)
foreach ($par in $pares) {
    try {
        $destinoLocal = Resolve-LocalDestination $par.Destino
        Write-Host "`nOrigen: $($par.Origen)"
        Write-Host "Destino: $destinoLocal"
        $carpeta = Get-MtpFolder $movil $par.Origen
        Copy-MtpFolder $carpeta $destinoLocal $par.Origen
    } catch {
        $script:errores++
        Write-Warning "No se pudo completar el origen '$($par.Origen)': $_"
    }
}

Resolve-MtpConflicts
$pendientes = $script:diferentes - $script:resueltos
Write-Host "`nResultado: copiados/por copiar=$copiados; omitidos=$omitidos; tamano distinto=$diferentes; errores=$errores"
Write-Host "Conflictos: conservados local=$conservados; reemplazados=$reemplazados; ambas versiones=$ambos; pendientes=$pendientes"
if ($Simular) { Write-Host 'SIMULACION: no se ha creado, copiado ni reemplazado ningun archivo.' }
if ($errores -gt 0 -or $pendientes -gt 0) {
    Write-Warning 'Revisa las incidencias antes de considerar completa la copia de seguridad.'
}
