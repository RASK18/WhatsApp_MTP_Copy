# WhatsApp MTP Copy

Script de PowerShell para copiar al PC las carpetas de WhatsApp que un dispositivo Android expone por USB mediante MTP. Mantiene las subcarpetas, añade los archivos que faltan y deja para el final las decisiones sobre archivos existentes con distinto tamaño.

Todo se copia a carpetas locales. El script no elimina ni modifica archivos del dispositivo y no envía el contenido a ningún servicio externo.

## Requisitos

- Windows con Windows PowerShell 5.1 o PowerShell 7.
- El dispositivo conectado por USB, con la transferencia de archivos habilitada y sus carpetas accesibles desde **Este equipo**.
- Una carpeta de destino con permisos de escritura y espacio suficiente para las copias. Resolver conflictos puede necesitar espacio adicional para una copia temporal.

Utiliza `Shell.Application`, el acceso del Explorador de Windows a los dispositivos MTP. No necesita instalar módulos de PowerShell.

## Uso rápido

1. Descarga el repositorio y abre PowerShell en la carpeta donde está `Copia_MTP_Incremental.ps1`.
2. Comprueba el nombre del dispositivo en **Este equipo**. `-Dispositivo` debe coincidir con ese nombre.
3. Ejecuta primero una simulación:

   ```powershell
   .\Copia_MTP_Incremental.ps1 -Dispositivo 'Mi móvil' -Simular
   ```

4. Revisa las rutas y los archivos que se muestran. Para realizar la copia:

   ```powershell
   .\Copia_MTP_Incremental.ps1 -Dispositivo 'Mi móvil'
   ```

Sustituye `Mi móvil` por el nombre de tu dispositivo. Si PowerShell bloquea la ejecución del archivo, consulta la [documentación sobre las directivas de ejecución](https://learn.microsoft.com/powershell/module/microsoft.powershell.core/about/about_execution_policies). Una simulación consulta el dispositivo y el destino, pero no comprueba todos los permisos ni los posibles errores de una transferencia real.

## Parámetros y valores predeterminados

| Parámetro | Descripción | Valor predeterminado |
| --- | --- | --- |
| `-Dispositivo` | Nombre del dispositivo en **Este equipo**. Es obligatorio. | Sin valor predeterminado. |
| `-Origen1` | Primera carpeta dentro del dispositivo. | `Almacenamiento de dispositivo interno\Android\data\com.whatsapp` |
| `-Origen2` | Segunda carpeta dentro del dispositivo. | `Almacenamiento de dispositivo interno\Android\media\com.whatsapp` |
| `-Destino1` | Carpeta local para el primer origen. | `%UserProfile%\Desktop\{{Dispositivo}}\data\com.whatsapp` |
| `-Destino2` | Carpeta local para el segundo origen. | `%UserProfile%\Desktop\{{Dispositivo}}\media\com.whatsapp` |
| `-Simular` | Muestra lo que se copiaría y los conflictos, sin crear carpetas, copiar archivos ni pedir decisiones. | Desactivado. |

Los parámetros de origen y destino usan los valores predeterminados cuando se omiten, se pasan vacíos o contienen solo espacios. El script procesa las dos parejas: `Origen1 → Destino1` y `Origen2 → Destino2`. Si una falla, avisa y continúa con la otra.

Las rutas de origen son relativas al dispositivo, no rutas de disco como `C:\...`. El nombre del almacenamiento puede variar entre dispositivos; debe coincidir con el que muestra el Explorador.

En los destinos, `%UserProfile%` se expande al perfil de Windows y `{{Dispositivo}}` se sustituye por el nombre introducido. También se pueden usar en destinos personalizados. Las rutas relativas se resuelven desde la ubicación actual de PowerShell.

Con los valores predeterminados, el resultado se organiza así:

```text
%UserProfile%\Desktop\
└── Mi móvil\
    ├── data\
    │   └── com.whatsapp\
    └── media\
        └── com.whatsapp\
```

### Destinos personalizados

```powershell
.\Copia_MTP_Incremental.ps1 -Dispositivo 'Mi móvil' `
    -Destino1 'D:\Copias\{{Dispositivo}}\data\com.whatsapp' `
    -Destino2 'D:\Copias\{{Dispositivo}}\media\com.whatsapp'
```

### Nombre de almacenamiento diferente

Si el Explorador muestra `Almacenamiento interno` en lugar de `Almacenamiento de dispositivo interno`, indica las rutas que correspondan:

```powershell
.\Copia_MTP_Incremental.ps1 -Dispositivo 'Mi móvil' `
    -Origen1 'Almacenamiento interno\Android\data\com.whatsapp' `
    -Origen2 'Almacenamiento interno\Android\media\com.whatsapp' `
    -Simular
```

## Qué hace con cada archivo

La comparación se realiza entre archivos que corresponden a la misma ruta dentro de cada pareja de origen y destino.

| Situación | Comportamiento |
| --- | --- |
| El archivo no existe en el destino. | Lo copia, creando las subcarpetas necesarias. |
| El archivo existe y el tamaño coincide. | Lo omite. |
| El archivo existe y los tamaños son diferentes. | Anota el conflicto y continúa; pregunta al final. |
| El archivo existe, pero no se puede consultar el tamaño del original por MTP. | Lo omite sin verificar su contenido. |
| Hay una carpeta donde debería ir un archivo. | Registra una incidencia y continúa. |

No elimina archivos locales porque hayan desaparecido del dispositivo. La copia incremental consiste en añadir los que faltan y resolver manualmente los conflictos de tamaño; no sincroniza automáticamente las versiones modificadas.

## Decisiones al final de la copia

Después de recorrer ambos orígenes, presenta los conflictos uno por uno. Para cada uno muestra las rutas y el nombre, la fecha de modificación y el tamaño en bytes de ambas versiones. Si MTP no proporciona una fecha, muestra `No disponible`.

| Opción | Acción |
| --- | --- |
| `C` o Intro | Conserva la versión local. |
| `R` | Reemplaza la versión local por la del dispositivo. |
| `A` | Conserva ambas: mantiene el archivo local y guarda la versión del dispositivo con otro nombre. |

Con `A`, por ejemplo, `archivo.ext` se guarda como `archivo (dispositivo).ext`. Si ese nombre ya existe, utiliza `archivo (dispositivo 2).ext`, y así sucesivamente.

Para `R` y `A`, primero transfiere el archivo a una carpeta temporal dentro del destino. Antes de aplicar la decisión, comprueba la copia y vuelve a consultar el tamaño y la fecha disponibles del origen. En un reemplazo también revisa que el tamaño y la fecha de modificación local no hayan cambiado desde la pregunta. Si detecta cambios o falla la operación, el conflicto queda pendiente.

Las carpetas temporales tienen nombres como `.mtp-conflicto-<identificador>`. Se retiran cuando la operación termina correctamente. Si hay un error, se conservan y se muestra su ruta para revisarlas. Una transferencia del Explorador podría seguir activa: comprueba que haya terminado antes de manipular esas carpetas.

Con `-Simular`, muestra los detalles de los conflictos y las opciones que ofrecería, pero no solicita respuestas.

## Resumen de ejecución

Al terminar muestra:

- **Copiados / por copiar:** transferencias confirmadas, incluidos los conflictos resueltos con `R` o `A`; en simulación cuenta los archivos nuevos que copiaría.
- **Omitidos:** archivos existentes que no se transfirieron por la comparación inicial.
- **Tamaño distinto:** conflictos encontrados durante el recorrido.
- **Errores:** incidencias detectadas.
- **Conflictos:** cuántos se resolvieron conservando la versión local, reemplazándola o guardando ambas, y cuántos quedan pendientes.

Las decisiones y el resumen se muestran en consola. No se guardan en un registro persistente. Las incidencias contabilizadas tampoco establecen expresamente un código de salida de error para automatizaciones.

## Límites de la comprobación

**Un archivo omitido o una transferencia confirmada no equivalen a una verificación de integridad del contenido.**

- No calcula ni compara hashes. Dos archivos del mismo tamaño pueden tener contenido diferente.
- Si no se puede conocer el tamaño del original, un archivo local existente se omite aunque pudiera estar incompleto.
- Para confirmar una transferencia, espera a que el tamaño coincida con el esperado y pueda abrir el archivo en exclusiva. Si desconoce el tamaño esperado, espera aproximadamente dos segundos sin cambios de tamaño y comprueba que puede abrirlo.
- El límite de espera es de 60 segundos sin cambios de tamaño, no de duración total. No limita una llamada al Explorador que se quede bloqueada ni cancela una transferencia pendiente. [`CopyHere` no proporciona una notificación de finalización al script](https://learn.microsoft.com/windows/win32/shell/folder-copyhere).
- Una copia interrumpida puede dejar archivos parciales. No reanuda automáticamente las transferencias; en otra ejecución, un archivo parcial existente se trata conforme a las reglas de comparación anteriores.
- Solo copia lo que el dispositivo expone y permite leer por MTP. Una carpeta ausente o inaccesible, como puede ocurrir con `Android\data`, genera un aviso.
- No obtiene una instantánea consistente: los archivos pueden cambiar mientras se copian.
- Nombres incompatibles con Windows, rutas largas, permisos, falta de espacio o límites del sistema de archivos del destino pueden provocar errores.
- Si varios dispositivos tienen el mismo nombre, utiliza el primero que encuentra en **Este equipo**.

Es una copia de archivos accesibles por MTP. No descifra las bases de datos de WhatsApp ni realiza una restauración en la aplicación.

## Validación realizada

La versión actual ha pasado 11 comprobaciones en Windows PowerShell 5.1 y PowerShell 7 con un dispositivo simulado y operaciones locales reales sobre archivos de prueba. Cubren las opciones de conflicto, los valores predeterminados, la simulación, la continuidad cuando falta un origen y la conservación del archivo local ante errores o cambios durante una decisión.

La transferencia MTP con un dispositivo real queda pendiente de validar.

## Licencia

El repositorio incluye la licencia **GNU Affero General Public License, versión 3**. Consulta [LICENSE](LICENSE).
