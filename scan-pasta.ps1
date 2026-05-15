Add-Type -AssemblyName Microsoft.VisualBasic

function Show-Header {
    Clear-Host
    Write-Host "=========================================" -ForegroundColor Cyan
    Write-Host "      ANALISADOR DE PASTAS DO DISCO" -ForegroundColor Yellow
    Write-Host "=========================================" -ForegroundColor Cyan
    Write-Host ""
}

function Test-Admin {
    $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($currentUser)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Restart-AsAdmin {
    $scriptPath = $MyInvocation.PSCommandPath
    if (-not $scriptPath) {
        Write-Host "Nao consegui reiniciar automaticamente como admin." -ForegroundColor Red
        return
    }

    Start-Process powershell.exe -Verb RunAs -ArgumentList "-ExecutionPolicy Bypass -File `"$scriptPath`""
    exit
}

function Get-ItemSizeBytes {
    param (
        [string]$FullPath,
        [bool]$IsFolder
    )

    try {
        if ($IsFolder) {
            $sum = (
                Get-ChildItem -LiteralPath $FullPath -Recurse -Force -File -ErrorAction SilentlyContinue |
                Measure-Object -Property Length -Sum
            ).Sum

            if ($null -eq $sum) { return 0 }
            return [int64]$sum
        }
        else {
            $item = Get-Item -LiteralPath $FullPath -Force -ErrorAction SilentlyContinue
            if ($null -eq $item) { return 0 }
            return [int64]$item.Length
        }
    }
    catch {
        return 0
    }
}

function Scan-Path {
    param (
        [string]$Path
    )

    Write-Host ""
    Write-Host "Escaneando... isso pode levar alguns segundos" -ForegroundColor Green
    Write-Host ""

    $children = @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue)
    $total = $children.Count
    $results = @()

    if ($total -eq 0) {
        Write-Progress -Activity "Escaneando pasta" -Completed
        return @()
    }

    for ($i = 0; $i -lt $total; $i++) {
        $item = $children[$i]
        $percent = [int](($i / $total) * 100)

        Write-Progress -Activity "Escaneando pasta" `
                       -Status ("Analisando {0} de {1}: {2}" -f ($i + 1), $total, $item.Name) `
                       -PercentComplete $percent

        $isFolder = [bool]$item.PSIsContainer
        $size = Get-ItemSizeBytes -FullPath $item.FullName -IsFolder $isFolder

        $results += [PSCustomObject]@{
            Numero     = 0
            Nome       = $item.Name
            Tipo       = if ($isFolder) { "Pasta" } else { "Arquivo" }
            TamanhoMB  = [math]::Round(($size / 1MB), 2)
            TamanhoGB  = [math]::Round(($size / 1GB), 2)
            TamanhoB   = [int64]$size
            Caminho    = $item.FullName
        }
    }

    Write-Progress -Activity "Escaneando pasta" -Completed

    $results = $results | Sort-Object TamanhoB -Descending

    for ($n = 0; $n -lt $results.Count; $n++) {
        $results[$n].Numero = $n + 1
    }

    return $results
}

function Show-Results {
    param (
        [array]$Results,
        [string]$Path
    )

    Write-Host ""
    Write-Host "Pasta atual: $Path" -ForegroundColor Cyan
    Write-Host ""

    if ($Results.Count -eq 0) {
        Write-Host "Nenhum item encontrado." -ForegroundColor Yellow
    }
    else {
        $Results | Format-Table Numero, Nome, Tipo, TamanhoMB, TamanhoGB -AutoSize
    }

    Write-Host ""
    Write-Host "Comandos disponiveis:" -ForegroundColor Yellow
    Write-Host "  /delete:1,2,3   -> apaga os itens pelos numeros" -ForegroundColor Gray
    Write-Host "  /new            -> nova busca com outro caminho" -ForegroundColor Gray
    Write-Host "  /admin          -> reiniciar como administrador" -ForegroundColor Gray
    Write-Host "  /exit           -> sair" -ForegroundColor Gray
    Write-Host ""
}

function Remove-WithWindowsUI {
    param (
        [string]$TargetPath,
        [string]$Tipo
    )

    try {
        if ($Tipo -eq "Pasta") {
            [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory(
                $TargetPath,
                [Microsoft.VisualBasic.FileIO.UIOption]::AllDialogs,
                [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin,
                [Microsoft.VisualBasic.FileIO.UICancelOption]::ThrowException
            )
        }
        else {
            [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile(
                $TargetPath,
                [Microsoft.VisualBasic.FileIO.UIOption]::AllDialogs,
                [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin,
                [Microsoft.VisualBasic.FileIO.UICancelOption]::ThrowException
            )
        }

        return $true
    }
    catch {
        return $false
    }
}

function Delete-SelectedItems {
    param (
        [string]$CommandText,
        [array]$Results
    )

    $rawNumbers = $CommandText.Substring(8).Split(",")
    $selected = @()

    foreach ($raw in $rawNumbers) {
        $trimmed = $raw.Trim()
        $num = 0

        if ([int]::TryParse($trimmed, [ref]$num)) {
            $found = $Results | Where-Object { $_.Numero -eq $num }
            if ($found) {
                $selected += $found
            }
            else {
                Write-Host "Numero nao encontrado: $num" -ForegroundColor Red
            }
        }
        else {
            Write-Host "Numero invalido: $trimmed" -ForegroundColor Red
        }
    }

    if ($selected.Count -eq 0) {
        Write-Host ""
        Write-Host "Nada para apagar." -ForegroundColor Yellow
        return
    }

    Write-Host ""
    Write-Host "Itens selecionados para apagar:" -ForegroundColor Yellow
    $selected | Format-Table Numero, Nome, Tipo, TamanhoMB, TamanhoGB -AutoSize
    Write-Host ""

    $confirm = Read-Host "Confirma? (S/N)"
    if ($confirm -notin @("S","s","Y","y")) {
        Write-Host "Operacao cancelada." -ForegroundColor Yellow
        return
    }

    for ($i = 0; $i -lt $selected.Count; $i++) {
        $item = $selected[$i]
        $percent = [int](($i / $selected.Count) * 100)

        Write-Progress -Activity "Apagando itens" `
                       -Status ("Apagando {0} de {1}: {2}" -f ($i + 1), $selected.Count, $item.Nome) `
                       -PercentComplete $percent

        if (-not (Test-Path -LiteralPath $item.Caminho)) {
            Write-Host "Ja nao existe: $($item.Nome)" -ForegroundColor Yellow
            continue
        }

        $ok = Remove-WithWindowsUI -TargetPath $item.Caminho -Tipo $item.Tipo

        if ($ok) {
            Write-Host "Apagado: $($item.Nome)" -ForegroundColor Green
        }
        else {
            Write-Host "Nao foi possivel apagar: $($item.Nome)" -ForegroundColor Red
        }
    }

    Write-Progress -Activity "Apagando itens" -Completed
    Write-Host ""
    Write-Host "Apagamento finalizado." -ForegroundColor Green
}

Show-Header

while ($true) {
    $path = Read-Host "Cole o caminho da pasta que quer analisar"

    if ($path -eq "/exit") {
        exit
    }

    if ($path -eq "/admin") {
        Restart-AsAdmin
    }

    if (!(Test-Path -LiteralPath $path)) {
        Write-Host ""
        Write-Host "Caminho invalido!" -ForegroundColor Red
        Write-Host ""
        continue
    }

    $results = Scan-Path -Path $path
    Show-Results -Results $results -Path $path

    while ($true) {
        $cmd = Read-Host "Digite um comando"

        if ($cmd -eq "/new") {
            Show-Header
            break
        }
        elseif ($cmd -eq "/exit") {
            exit
        }
        elseif ($cmd -eq "/admin") {
            Restart-AsAdmin
        }
        elseif ($cmd -like "/delete:*") {
            Delete-SelectedItems -CommandText $cmd -Results $results
            Write-Host ""
            Write-Host "Reescaneando a pasta..." -ForegroundColor Green
            $results = Scan-Path -Path $path
            Show-Results -Results $results -Path $path
        }
        else {
            Write-Host "Comando invalido." -ForegroundColor Red
            Write-Host "Use /delete:1,2,3 ou /new ou /admin ou /exit" -ForegroundColor Yellow
            Write-Host ""
        }
    }
}