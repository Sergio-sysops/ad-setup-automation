# Active Directory Setup Automation (PowerShell)

🇬🇧 English · [🇪🇸 Leer en español](#-en-español)

Two PowerShell scripts that turn a fresh Windows Server domain controller into a ready-to-use small-office network, driven by a simple CSV of employees.

Tested on **Windows Server 2025** (domain `corp.lan`) in a KVM lab.

![Dry run with -WhatIf](docs/1-whatif.png)

## What it does

**`New-ADLabUsers.ps1`**: company structure from a CSV
- One **OU per department** under a company root OU
- A **security group** per department (`GG_<Department>`)
- **Users** as `firstname.lastname` (accents removed), random initial password, password change forced at first logon
- A **shared folder per department** (`\\SERVER\<Department>`) where only that department's group can write, with NTFS inheritance broken on purpose

**`New-ADLabGPOs.ps1`**: baseline policies
- **Password policy**: 12+ characters, complexity, 90-day expiry, lockout after 5 failed attempts
- **Screen lock** GPO after 10 minutes idle
- **Corporate wallpaper** GPO, with the image published in `NETLOGON`

## Built to be safe to run

| Feature | Why it matters |
|---|---|
| `-WhatIf` | Shows exactly what would change, without touching anything |
| Idempotent | Re-running only creates what is missing (`[SKIP]` for the rest), so you can add employees to the CSV and run it again |
| CSV validation | Fails before touching AD if columns or required values are missing |
| Logging | Every run writes a full transcript to `C:\LabReport\logs\` |

![Second run: only new employees are created](docs/2-run.png)

## Usage

On the domain controller, as a Domain Admin:

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force

.\New-ADLabUsers.ps1 -CsvPath .\employees.csv -WhatIf   # simulate
.\New-ADLabUsers.ps1 -CsvPath .\employees.csv           # apply
.\New-ADLabGPOs.ps1  -WallpaperPath .\fondo-corp.jpg
```

CSV format (`employees.csv`):

```csv
FirstName,LastName,Department,Title
Laura,García,Ventas,Comercial
Andrés,Gómez,IT,Técnico de sistemas
```

## Result

| Active Directory Users and Computers | Group Policy Management |
|---|---|
| ![ADUC](docs/3-aduc.png) | ![GPMC](docs/4-gpmc.png) |

![GPO settings report](docs/5-gpo-report.png)

## Notes for production use

This is a lab setup. For a real company I would also recommend:
- At least **two domain controllers** and **System State backups**
- A domain name based on one you own (for example `ad.company.com`)
- **LAPS** for local admin passwords, and separate admin accounts
- Delivering initial passwords through a secure channel (the script writes them to a CSV that should be deleted after use)

All employee data in this repository is fictional.

---

## 🇪🇸 En español

Dos scripts de PowerShell que convierten un controlador de dominio Windows Server recién instalado en la red de una pequeña oficina lista para usar, a partir de un simple CSV de empleados.

Probado en **Windows Server 2025** (dominio `corp.lan`) en un laboratorio con KVM.

### Qué hace

**`New-ADLabUsers.ps1`**: estructura de la empresa desde un CSV
- Una **OU por departamento** dentro de una OU raíz de la empresa
- Un **grupo de seguridad** por departamento (`GG_<Departamento>`)
- **Usuarios** como `nombre.apellido` (sin tildes), contraseña inicial aleatoria y cambio obligatorio en el primer inicio de sesión
- Una **carpeta compartida por departamento** (`\\SERVIDOR\<Departamento>`) en la que solo escribe el grupo de ese departamento, con la herencia NTFS cortada a propósito

**`New-ADLabGPOs.ps1`**: directivas básicas
- **Contraseñas**: 12 caracteres o más, complejidad, caducidad a los 90 días y bloqueo tras 5 intentos fallidos
- **Bloqueo de pantalla** tras 10 minutos de inactividad
- **Fondo de escritorio corporativo**, con la imagen publicada en `NETLOGON`

### Pensado para ejecutarse sin miedo

| Función | Por qué importa |
|---|---|
| `-WhatIf` | Muestra exactamente qué cambiaría, sin tocar nada |
| Idempotente | Si lo vuelves a ejecutar solo crea lo que falta (`[SKIP]` en lo demás): puedes añadir empleados al CSV y lanzarlo otra vez |
| Validación del CSV | Se para antes de tocar AD si faltan columnas o datos obligatorios |
| Registro | Cada ejecución guarda un registro completo en `C:\LabReport\logs\` |

### Uso

En el controlador de dominio, como administrador del dominio:

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force

.\New-ADLabUsers.ps1 -CsvPath .\employees.csv -WhatIf   # simular
.\New-ADLabUsers.ps1 -CsvPath .\employees.csv           # aplicar
.\New-ADLabGPOs.ps1  -WallpaperPath .\fondo-corp.jpg
```

### Para usarlo en una empresa real

Es un laboratorio. En una empresa recomendaría además: al menos **dos controladores de dominio** y **copias del System State**, un nombre de dominio basado en uno propio (por ejemplo `ad.empresa.com`), **LAPS** para las contraseñas de administrador local y cuentas de administración separadas, y entregar las contraseñas iniciales por un canal seguro (el script las escribe en un CSV que hay que borrar después).

Todos los datos de empleados de este repositorio son inventados.
