param([string]$City, [switch]$Help, [switch]$Verbose)

function Show-Loading {
    param([string]$Message)
    $dots = @(".", "..", "...")
    for ($i = 0; $i -lt 3; $i++) {
        Write-Host "`r$Message $($dots[$i])" -NoNewline -ForegroundColor Gray
        Start-Sleep -Milliseconds 400
    }
    Write-Host "`r$Message OK" -NoNewline -ForegroundColor Green
    Write-Host ""
}

function Get-WindDirection {
    param([double]$degrees)
    $deg = [math]::Round($degrees/22.5)
    switch ($deg) {
        0 {" N "}
        1 {" N "}
        2 {"NE "}
        3 {"NE "}
        4 {" E "}
        5 {" E "}
        6 {"SE "}
        7 {"SE "}
        8 {" S "}
        9 {" S "}
        10{"SW "}
        11{"SW "}
        12{" W "}
        13{" W "}
        14{"NW "}
        15{"NW "}
        default {" N "}
    }
}

if ($Help -or (-not $City -and -not (Test-Path "$env:USERPROFILE\.mymeteorc"))) {
    Write-Host "==================== MYMETEO ====================" -ForegroundColor Cyan
    Write-Host "Pogoda z najblizszej stacji IMGW-PIB" -ForegroundColor Cyan
    Write-Host "Uzycie: .\projekt.ps1 -City NazwaMiasta [-Verbose] [-Help]" -ForegroundColor White
    Write-Host "Przyklad: .\projekt.ps1 -City Warszawa" -ForegroundColor White
    Write-Host "Autor: Pawel Mokrzycki" -ForegroundColor Gray
    exit 0
}

$rcFile = "$env:USERPROFILE\.mymeteorc"
if (-not $City -and (Test-Path $rcFile)) {
    $rc = Get-Content $rcFile | ConvertFrom-Json
    $City = $rc.City
    if ($Verbose) { Write-Host "[DEBUG] Wczytano z RC: $City" -ForegroundColor Gray }
}

if (-not $City) {
    Write-Host "Blad: podaj miasto! Przyklad: -City Warszawa" -ForegroundColor Red
    exit 1
}

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
Write-Host "Miasto: $City" -ForegroundColor White
if ($Verbose) { Show-Loading "Inicjalizacja" }

function DistanceKm($lat1, $lon1, $lat2, $lon2) {
    $R = 6371
    $dLat = ($lat2 - $lat1) * [math]::PI / 180
    $dLon = ($lon2 - $lon1) * [math]::PI / 180
    $a = [math]::Sin($dLat/2)*[math]::Sin($dLat/2) +
         [math]::Cos($lat1*[math]::PI/180)*[math]::Cos($lat2*[math]::PI/180)*
         [math]::Sin($dLon/2)*[math]::Sin($dLon/2)
    $c = 2*[math]::Atan2([math]::Sqrt($a), [math]::Sqrt(1-$a))
    return $R * $c
}

$cacheDir = "$env:USERPROFILE\.cache\mymeteo"
if (-not (Test-Path $cacheDir)) { New-Item -ItemType Directory -Path $cacheDir | Out-Null }
$cityCache = "$cacheDir\$City.json"
$stationsCache = "$cacheDir\stations.json"
$weatherCache = "$cacheDir\$City-weather.json"

if (Test-Path $cityCache) {
    $cityData = Get-Content $cityCache | ConvertFrom-Json
    if ($Verbose) { Write-Host "[DEBUG] Cache miasta OK" -ForegroundColor Gray }
} else {
    if ($Verbose) { Show-Loading "Pobieranie GPS $City" }
    $url = 'https://nominatim.openstreetmap.org/search?q={0}&format=json&countrycodes=pl&limit=1' -f $City
    $headers = @{ "User-Agent" = "mymeteo-project (student)" }
    $cityData = Invoke-RestMethod -Uri $url -Headers $headers
    if (-not $cityData) { 
        Write-Host "Blad: Nie znaleziono miasta $City" -ForegroundColor Red
        exit 1 
    }
    $cityData | ConvertTo-Json | Set-Content $cityCache
}

$cityLat = [double]$cityData[0].lat
$cityLon = [double]$cityData[0].lon
Write-Host "Wspolrzedne GPS: $cityLat, $cityLon" -ForegroundColor Cyan

if (Test-Path $stationsCache) {
    $stations = Get-Content $stationsCache | ConvertFrom-Json
    if ($Verbose) { Write-Host "[DEBUG] Cache stacji OK" -ForegroundColor Gray }
} else {
    if ($Verbose) { Show-Loading "Lista stacji IMGW" }
    $stations = @(
        @{ Name="Warszawa"; Lat=52.2297; Lon=21.0122 }
        @{ Name="Poznan";   Lat=52.4095; Lon=16.9319 }
        @{ Name="Krakow";   Lat=50.0647; Lon=19.9450 }
        @{ Name="Gdansk";   Lat=54.3520; Lon=18.6466 }
        @{ Name="Wroclaw";  Lat=51.1079; Lon=17.0385 }
        @{ Name="Szczecin"; Lat=53.4285; Lon=14.5528 }
        @{ Name="Lodz";     Lat=51.7592; Lon=19.4572 }
        @{ Name="Katowice"; Lat=50.2593; Lon=19.0264 }
    )
    $stations | ConvertTo-Json | Set-Content $stationsCache
}

if ($Verbose) { Show-Loading "Najblizsza stacja" }
$nearest = $null
$minDist = 999999
foreach ($s in $stations) {
    $d = DistanceKm $cityLat $cityLon $s.Lat $s.Lon
    if ($d -lt $minDist) { $minDist=$d; $nearest=$s }
}

Write-Host ""
Write-Host "================ STACJA METEOROLOGICZNA IMGW ================" -ForegroundColor Cyan
Write-Host "Stacja meteorologiczna: $($nearest.Name)" -ForegroundColor White
Write-Host "Odleglosc od miasta: $([math]::Round($minDist,1)) km" -ForegroundColor Yellow
Write-Host "===========================================================" -ForegroundColor Gray

$fetchWeather = $true
if (Test-Path $weatherCache) {
    $cached = Get-Content $weatherCache | ConvertFrom-Json
    $weather = $cached
    $fetchWeather = $false
    if ($Verbose) { Write-Host "[DEBUG] Cache pogody OK" -ForegroundColor Gray }
}

if ($fetchWeather) {
    if ($Verbose) { Show-Loading "Pogoda z IMGW" }
    $urlWeather = "https://danepubliczne.imgw.pl/api/data/synop/station/$($nearest.Name.ToLower())"
    try {
        $weather = Invoke-RestMethod -Uri $urlWeather
        $weather | Add-Member NoteProperty time (Get-Date) -Force
        $weather | ConvertTo-Json | Set-Content $weatherCache
    } catch {
        Write-Host "Blad IMGW API" -ForegroundColor Red
        exit 1
    }
}

$tempColor = if ($weather.temperatura -gt 25) { "Red" } elseif ($weather.temperatura -lt 0) { "Blue" } else { "Yellow" }
$windColor = if ($weather.predkosc_wiatru -gt 10) { "Red" } else { "Green" }

Write-Host ""
Write-Host "============== AKUALNE DANE POGODOWE ==============" -ForegroundColor Cyan
Write-Host "Temperatura: $([math]::Round($weather.temperatura,1)) C" -ForegroundColor $tempColor
Write-Host "Predkosc wiatru: $([math]::Round($weather.predkosc_wiatru,1)) m/s  $(Get-WindDirection $weather.kierunek_wiatru)" -ForegroundColor $windColor
Write-Host "Wilgotnosc: $([math]::Round($weather.wilgotnosc_wzgledna,1)) %" -ForegroundColor Blue
Write-Host "Suma opadu: $([math]::Round($weather.suma_opadu,2)) mm" -ForegroundColor Magenta
Write-Host "Cisnienie: $([math]::Round($weather.cisnienie,1)) hPa" -ForegroundColor Cyan

$currentTime = Get-Date -Format "yyyy-MM-dd HH:mm"
Write-Host "Czas pomiaru: $currentTime" -ForegroundColor Gray
Write-Host "==================================================" -ForegroundColor Gray

Write-Host ""
Write-Host "Dane pogodowe: IMGW-PIB (danepubliczne.imgw.pl)" -ForegroundColor DarkGray
Write-Host "Geolokalizacja: OpenStreetMap Nominatim" -ForegroundColor DarkGray
Write-Host "Autor: Pawel Mokrzycki" -ForegroundColor DarkGray
