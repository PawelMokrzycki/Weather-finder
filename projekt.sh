#!/usr/bin/env bash
set -euo pipefail

UA="mymeteo-project (student)"

show_help() {
  cat <<'EOF'
==================== MYMETEO ====================
Pogoda z najblizszej stacji IMGW-PIB
Uzycie: ./projekt.sh -c NazwaMiasta [-v] [-h]
Przyklad: ./projekt.sh -c Warszawa
Autor: Pawel Mokrzycki
EOF
}

VERBOSE=0
CITY=""

while getopts "c:vh" opt; do
  case "$opt" in
    c) CITY="$OPTARG" ;;
    v) VERBOSE=1 ;;
    h) show_help; exit 0 ;;
    *) show_help; exit 1 ;;
  esac
done

if [[ -z "${CITY:-}" ]]; then
  printf "Blad: podaj miasto! -c NazwaMiasta\n" >&2
  exit 1
fi

log_debug() { [[ "$VERBOSE" -eq 1 ]] && printf "%s\n" "[DEBUG] $*" >&2 || true; }

# --- kolory (tput) ---
COLORS=0
if [[ -t 1 ]]; then
  COLORS="$(tput colors 2>/dev/null || echo 0)"
fi

if [[ "$COLORS" -ge 8 ]]; then
  C_RESET="$(tput sgr0)"
  C_BOLD="$(tput bold)"
  C_GRAY="$(tput setaf 7)"
  C_DGRAY="$(tput setaf 8 2>/dev/null || tput setaf 7)"
  C_RED="$(tput setaf 1)"
  C_GREEN="$(tput setaf 2)"
  C_YELLOW="$(tput setaf 3)"
  C_BLUE="$(tput setaf 4)"
  C_MAGENTA="$(tput setaf 5)"
  C_CYAN="$(tput setaf 6)"
else
  C_RESET=""; C_BOLD=""; C_GRAY=""; C_DGRAY=""
  C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_MAGENTA=""; C_CYAN=""
fi

say() { printf "%b%s%b\n" "$1" "$2" "$C_RESET"; }

# --- util ---
distance_km() {
  awk -v lat1="$1" -v lon1="$2" -v lat2="$3" -v lon2="$4" '
    function rad(x){ return x*atan2(0,-1)/180 }
    BEGIN{
      R=6371
      dlat=rad(lat2-lat1)
      dlon=rad(lon2-lon1)
      a=sin(dlat/2)^2 + cos(rad(lat1))*cos(rad(lat2))*sin(dlon/2)^2
      c=2*atan2(sqrt(a), sqrt(1-a))
      printf "%.6f\n", R*c
    }'
}

safe_name() { echo "$1" | sed 's/[[:space:]]\+/_/g; s/[^[:alnum:]_-]/_/g'; }

to_ascii_pl() {
  local s="$1"
  s="${s//ą/a}"; s="${s//ć/c}"; s="${s//ę/e}"; s="${s//ł/l}"; s="${s//ń/n}"
  s="${s//ó/o}"; s="${s//ś/s}"; s="${s//ż/z}"; s="${s//ź/z}"
  s="${s//Ą/a}"; s="${s//Ć/c}"; s="${s//Ę/e}"; s="${s//Ł/l}"; s="${s//Ń/n}"
  s="${s//Ó/o}"; s="${s//Ś/s}"; s="${s//Ż/z}"; s="${s//Ź/z}"
  echo "$s"
}

is_valid_weather_cache() {
  [[ -f "$WEATHER_CACHE" ]] || return 1
  jq -e 'type=="object" and has("stacja")' "$WEATHER_CACHE" >/dev/null 2>&1
}

# --- cache paths ---
CACHE_DIR="$HOME/.cache/mymeteo"
mkdir -p "$CACHE_DIR"

CITY_SAFE="$(safe_name "$CITY")"
CITY_CACHE="$CACHE_DIR/${CITY_SAFE}.json"
STATIONS_CACHE="$CACHE_DIR/stations.json"
WEATHER_CACHE="$CACHE_DIR/${CITY_SAFE}-weather.json"

# --- Nominatim ---
if [[ -f "$CITY_CACHE" ]]; then
  log_debug "Cache miasta OK: $CITY_CACHE"
else
  log_debug "Pobieranie GPS: $CITY"
  Q="${CITY// /+}"
  CITY_DATA="$(curl -fsS -A "$UA" \
    "https://nominatim.openstreetmap.org/search?q=$Q&format=json&countrycodes=pl&limit=1")"
  [[ -z "$CITY_DATA" || "$CITY_DATA" == "[]" ]] && { say "$C_RED" "Blad: nie znaleziono miasta $CITY"; exit 1; }
  echo "$CITY_DATA" > "$CITY_CACHE"
fi

CITY_LAT="$(jq -r '.[0].lat // empty' "$CITY_CACHE")"
CITY_LON="$(jq -r '.[0].lon // empty' "$CITY_CACHE")"
[[ -z "$CITY_LAT" || -z "$CITY_LON" || "$CITY_LAT" == "null" || "$CITY_LON" == "null" ]] && { say "$C_RED" "Blad: brak wspolrzednych"; exit 1; }

say "$C_GRAY" "Miasto: $CITY"
say "$C_CYAN" "Wspolrzedne GPS: $CITY_LAT, $CITY_LON"

# --- stations ---
if [[ -f "$STATIONS_CACHE" ]]; then
  log_debug "Cache stacji OK: $STATIONS_CACHE"
else
  cat > "$STATIONS_CACHE" <<'EOF'
[
  {"Name":"Warszawa","Slug":"warszawa","Lat":52.2297,"Lon":21.0122},
  {"Name":"Poznan","Slug":"poznan","Lat":52.4095,"Lon":16.9319},
  {"Name":"Krakow","Slug":"krakow","Lat":50.0647,"Lon":19.9450},
  {"Name":"Gdansk","Slug":"gdansk","Lat":54.3520,"Lon":18.6466},
  {"Name":"Wroclaw","Slug":"wroclaw","Lat":51.1079,"Lon":17.0385},
  {"Name":"Szczecin","Slug":"szczecin","Lat":53.4285,"Lon":14.5528},
  {"Name":"Lodz","Slug":"lodz","Lat":51.7592,"Lon":19.4572},
  {"Name":"Katowice","Slug":"katowice","Lat":50.2593,"Lon":19.0264}
]
EOF
fi

# --- nearest station ---
NEAREST_NAME=""
NEAREST_SLUG=""
NEAREST_LAT=""
NEAREST_LON=""
MIN_DIST="999999"

while IFS= read -r row; do
  LAT="$(jq -r '.Lat' <<<"$row")"
  LON="$(jq -r '.Lon' <<<"$row")"
  NAME="$(jq -r '.Name // empty' <<<"$row")"
  SLUG="$(jq -r '.Slug // .Name // empty' <<<"$row")"
  [[ -z "$LAT" || -z "$LON" || -z "$SLUG" ]] && continue

  D="$(distance_km "$CITY_LAT" "$CITY_LON" "$LAT" "$LON")"
  is_less="$(awk -v a="$D" -v b="$MIN_DIST" 'BEGIN{print (a<b)?1:0}')"
  if [[ "$is_less" -eq 1 ]]; then
    MIN_DIST="$D"
    NEAREST_NAME="$NAME"
    NEAREST_SLUG="$SLUG"
    NEAREST_LAT="$LAT"
    NEAREST_LON="$LON"
  fi
done < <(jq -c '.[]' "$STATIONS_CACHE")

[[ -z "$NEAREST_SLUG" ]] && { say "$C_RED" "Blad: nie wybrano stacji"; exit 1; }

printf "\n"
say "$C_CYAN" "================ STACJA METEOROLOGICZNA IMGW ================"
say "$C_GRAY" "Stacja meteorologiczna: $NEAREST_NAME"
say "$C_YELLOW" "Odleglosc od miasta: $(awk -v x="$MIN_DIST" 'BEGIN{printf "%.1f", x}') km"
say "$C_DGRAY" "=============================================================="

# --- IMGW weather ---
if is_valid_weather_cache; then
  log_debug "Cache pogody OK: $WEATHER_CACHE"
else
  [[ -f "$WEATHER_CACHE" ]] && rm -f "$WEATHER_CACHE"
  log_debug "Pobieranie pogody z IMGW..."
  SLUG_ASCII="$(to_ascii_pl "$NEAREST_SLUG" | tr '[:upper:]' '[:lower:]')"
  URL="https://danepubliczne.imgw.pl/api/data/synop/station/${SLUG_ASCII}"
  WEATHER="$(curl -fsS -A "$UA" "$URL")"
  jq -e 'type=="object" and has("stacja")' >/dev/null 2>&1 <<<"$WEATHER" || { say "$C_RED" "Blad IMGW API"; exit 1; }
  echo "$WEATHER" > "$WEATHER_CACHE"
fi

TEMP="$(jq -r '.temperatura // empty' "$WEATHER_CACHE")"
WIND="$(jq -r '.predkosc_wiatru // empty' "$WEATHER_CACHE")"
WIND_DIR="$(jq -r '.kierunek_wiatru // empty' "$WEATHER_CACHE")"
HUMID="$(jq -r '.wilgotnosc_wzgledna // empty' "$WEATHER_CACHE")"
RAIN="$(jq -r '.suma_opadu // empty' "$WEATHER_CACHE")"
PRESSURE="$(jq -r '.cisnienie // empty' "$WEATHER_CACHE")"
DATE_P="$(jq -r '.data_pomiaru // empty' "$WEATHER_CACHE")"
HOUR_P="$(jq -r '.godzina_pomiaru // empty' "$WEATHER_CACHE")"

temp_color="$C_YELLOW"
if awk -v t="$TEMP" 'BEGIN{exit !(t>25)}' 2>/dev/null; then temp_color="$C_RED"; fi
if awk -v t="$TEMP" 'BEGIN{exit !(t<0)}'  2>/dev/null; then temp_color="$C_BLUE"; fi

wind_color="$C_GREEN"
if awk -v w="$WIND" 'BEGIN{exit !(w>10)}' 2>/dev/null; then wind_color="$C_RED"; fi

printf "\n"
say "$C_CYAN" "============== AKTUALNE DANE POGODOWE =============="
say "$temp_color" "Temperatura: $TEMP C"
say "$wind_color" "Predkosc wiatru: $WIND m/s (kierunek: $WIND_DIR)"
say "$C_BLUE" "Wilgotnosc: $HUMID %"
say "$C_MAGENTA" "Suma opadu: $RAIN mm"
say "$C_CYAN" "Cisnienie: $PRESSURE hPa"
say "$C_DGRAY" "Czas pomiaru (IMGW): ${DATE_P} ${HOUR_P}:00"
say "$C_DGRAY" "==================================================="

printf "\n"
say "$C_DGRAY" "Dane pogodowe: IMGW-PIB (danepubliczne.imgw.pl)"
say "$C_DGRAY" "Geolokalizacja: OpenStreetMap Nominatim"
