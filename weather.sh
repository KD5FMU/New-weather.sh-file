#!/bin/bash
#
# weather.sh - 11/27/2025
#
# Input:   ZIP Code (US 5-digit, INT FR-75000, GB-EC1A1BB, CA-V6B1V2 etc.)  OR  airport code (IATA like JFK / ICAO like KXNA)
# Output:  "<TEMP F>, <TEMP C>, <RH>% RH / <COND>, Wind ..., inHG ... / Alerts: ..."
#
# Location (ZIP or Airport) -> Temp / Condition / Humidity / Pressure / Precip / Wind (+ thunder/NWS badge)
# - Open-Meteo current + minutely_15 (precip & lightning_potential look-back)
# - Optional NWS Alerts badge + compact list
# - Writes /var/tmp/temperature and /var/tmp/condition.gsm (raw GSM) for saytime.pl compatibility
# - SAFE_MODE: never modifies files under /var/lib/asterisk/sounds
#
# Updated by Mike Webb WG5EEK and Paul Aidukas KN2R
# Optimized for speed while maintaining compatibility with older systems
#
# Supports:
#   - All ZIP Codes (US 5-digit, INT FR-75000, GB-EC1A1BB, CA-V6B1V2 etc.)
#   - Airport code (ICAO like KXNA / EGCC, or IATA like JFK)
#
###########################################################################################
# IF USING AIRPORT CODES, YOU MUST RUN THIS FIRST TO BUILD THE DATABASE OF AIRPORT CODES
# DEBUG=1 will print minimal diag info to stderr (terminal only).  Usage: DEBUG=1 ./weather.sh JFK
# DEBUG=1 ./weather.sh your_airport_code
# IF YOU UPGRADED FROM AN EARLIER VERSION, DELETE /var/tmp/weather-airports.csv AND /var/tmp/airports_full.csv
###########################################################################################


DEBUG="${DEBUG:-0}"
LOCATION_RAW="$1"

set -u

########################################
# USER CONFIG
########################################
SHOW_FAHRENHEIT="YES"
SHOW_CELSIUS="YES"
Temperature_mode="F"             # F or C -> controls /var/tmp/temperature unit

SHOW_CONDITION="YES"
SHOW_HUMIDITY="YES"
SHOW_PRESSURE="NO"
SHOW_PRECIP="NO"
SHOW_WIND="YES"

SHOW_PRESSURE_INHG="NO"
SHOW_PRESSURE_HPA="NO"

SHOW_PRECIP_INCH="NO"
SHOW_PRECIP_MM="NO"
SHOW_ZERO_PRECIP="NO"
PRECIP_TRACE_MM="0.10"

SHOW_WIND_MPH="YES"
SHOW_WIND_KMH="NO"
SHOW_WIND_KN="NO"

SHOW_NWS_BADGE_ALWAYS="YES"
ENABLE_THUNDERSTORM="YES"
# Use CAPE for thunderstorm detection (legacy USE_OPENMETEO_LIGHTNING honored if set)
USE_CAPE="${USE_CAPE:-${USE_OPENMETEO_LIGHTNING:-YES}}"
LP_THRESHOLD="${LP_THRESHOLD:-100}"
TS_CLOUD_COVER_MIN="${TS_CLOUD_COVER_MIN:-60}"
LOOKBACK_SAMPLES="${LOOKBACK_SAMPLES:-4}"

FAST_MODE="YES"                  # we only ship FAST_MODE now
USE_NWS_ALERTS="NO"
SHOW_NWS_BADGE="NO"
SHOW_NWS_ALERTS_LIST="NO"
SHOW_NWS_ALERTS_SEVERITY="NO"
NWS_ALERTS_MAX="9"
NWS_USER_AGENT="${NWS_USER_AGENT:-supermon-weather/1.0 (you@example.com)}"
UA_HEADER="User-Agent: ${NWS_USER_AGENT}"

# Airport DB cache (trimmed, global, kept across runs)
AIRPORT_DB="/var/tmp/weather-airports.csv"
AIRPORT_FULL="/var/tmp/airports_full.csv"
ALLOWED_AIRPORT_TYPES="large_airport,medium_airport,small_airport,heliport,seaplane_base,balloonport,closed"

process_condition="YES"
timezone="auto"

SHOW_DEGREE_SYMBOL="${SHOW_DEGREE_SYMBOL:-YES}"
if [ "$SHOW_DEGREE_SYMBOL" = "YES" ]; then
  DEG=${DEG:-$'\xC2\xB0'}
else
  DEG=""
fi

# Runtime and cache live in /var/tmp (flat files only, no subdirectories)
destdir="/tmp"
CACHE_FILE="/var/tmp/airport-cache.txt"     # airport -> lat/lon cache
AIRPORT_MAX_AGE=604800                      # 7 days
CACHE_MAX_AGE=604800                        # 7 days

########################################
# LIGHTWEIGHT DEBUG HELPER
########################################
dbg() {
    [ "$DEBUG" = "1" ] || return 0
    echo "DEBUG: $*" >&2
}

########################################
# CLEAN OUT OLD ONE-SHOT FILES
########################################
rm -f "$destdir/temperature" \
      "$destdir/condition.gsm" \
      "$destdir/condition.gsm.tmp" \
      "$destdir/alert.gsm" \
      "$destdir/alert.gsm.txt" 2>/dev/null || true

########################################
# UTILS (math, curl, parse, cache, etc.)
########################################
has_bc() { command -v bc >/dev/null 2>&1; }

sanitize_num() {
    local raw="$1"
    raw=${raw#"${raw%%[! ]*}"}   # trim leading space
    raw=${raw%"${raw##*[! ]}"}   # trim trailing space
    case "$raw" in
        ""|null|NULL|NaN|nan|None|none|Infinity|inf|-inf|+inf) echo "0"; return;;
        +*) raw="${raw#+}";;
    esac
    case "$raw" in
        -*[!0-9.]* | *[!0-9.-]*) echo "0"; return;;
        .)  echo "0"; return;;
        .*) echo "0${raw}";;
        -.) echo "0"; return;;
        -.*) echo "-0${raw#-.}";;
        *)  echo "$raw";;
    esac
}

integer_round() {
    # halves away from zero, integer result
    local n sign intpart frac firstdigit
    n="$(sanitize_num "$1")"
    case "$n" in *.*);; *) n="${n}.0";; esac

    sign=""
    if [ "${n#-}" != "$n" ]; then sign="-"; n="${n#-}"
    elif [ "${n#+}" != "$n" ]; then sign="+"; n="${n#+}"; fi

    intpart="${n%%.*}"
    frac="${n#*.}"
    [ -z "$intpart" ] && intpart="0"
    firstdigit=$(printf '%s' "$frac" | cut -c1)
    [ -z "$firstdigit" ] && firstdigit="0"

    intpart=$(printf '%s' "$intpart" | sed 's/^0\+\([0-9]\)/\1/')
    [ -z "$intpart" ] && intpart="0"

    if [ "$firstdigit" -ge 5 ]; then
        intpart=$((intpart + 1))
    fi
    if [ "$sign" = "-" ]; then
        echo "-$intpart"
    else
        echo "$intpart"
    fi
}

round() { integer_round "$1"; }

float_mul() {
    has_bc || { echo "0"; return; }
    printf 'scale=6\n%s * %s\n' "$(sanitize_num "$1")" "$(sanitize_num "$2")" \
      | bc 2>/dev/null | sed 's/^\./0./'
}
float_div() {
    has_bc || { echo "0"; return; }
    local b="$(sanitize_num "$2")"
    [ "$b" = "0" ] && { echo "0"; return; }
    printf 'scale=6\n%s / %s\n' "$(sanitize_num "$1")" "$b" \
      | bc 2>/dev/null | sed 's/^\./0./'
}
float_add() {
    has_bc || { echo "0"; return; }
    printf 'scale=6\n%s + %s\n' "$(sanitize_num "$1")" "$(sanitize_num "$2")" \
      | bc 2>/dev/null | sed 's/^\./0./'
}
float_sub() {
    has_bc || { echo "0"; return; }
    printf 'scale=6\n%s - %s\n' "$(sanitize_num "$1")" "$(sanitize_num "$2")" \
      | bc 2>/dev/null | sed 's/^\./0./'
}
format_fixed_2() {
    local n="$1" whole frac
    case "$n" in *.*);; *) n="${n}.00";; esac
    whole="${n%%.*}"
    frac="${n#*.}00"
    frac=$(printf '%s' "$frac" | cut -c1-2)
    echo "${whole}.${frac}"
}
# NEW: helpers for exact one-decimal display (no jq required)
format_one_decimal() {
    local n
    n="$(sanitize_num "$1")"
    printf '%.1f' "$n"
}
force_one_decimal() {
  case "$1" in
    *.*) printf '%s\n' "$(printf '%s' "$1" | sed -E 's/^(-?[0-9]+)(\.[0-9]).*$/\1\2/')";;
    *)   printf '%s.0\n' "$1";;
  esac
}

c_to_f() {
    local c="$(sanitize_num "$1")"
    if has_bc; then
        integer_round "$(float_add "$(float_div "$(float_mul "$c" 9)" 5)" 32)"
    else
        local ci="${c%.*}"
        echo $(( ((ci * 9) / 5) + 32 ))
    fi
}
f_to_c() {
    local f="$(sanitize_num "$1")"
    if has_bc; then
        integer_round "$(float_div "$(float_mul "$(float_sub "$f" 32)" 5)" 9)"
    else
        local fi="${f%.*}"
        echo $(( ((fi - 32) * 5) / 9 ))
    fi
}

hpa_to_inhg() {
    local h="$(sanitize_num "$1")"
    if has_bc; then
        local prod="$(float_mul "$h" "0.02953")"
        format_fixed_2 "$prod"
    else
        local hi="${h%.*}"; case "$hi" in ''|*[^0-9-]*) hi=0;; esac
        local cents=$(( (hi * 2953 + 500) / 1000 ))
        local whole=$(( cents / 100 ))
        local frac=$(( cents % 100 ))
        printf "%d.%02d" "$whole" "$frac"
    fi
}

ms_to_mph() {
    local m="$(sanitize_num "$1")"
    if has_bc; then
        local prod="$(float_mul "$m" "2.23694")"
        integer_round "$prod"
    else
        local mi="${m%.*}"; case "$mi" in ''|*[^0-9-]*) mi=0;; esac
        echo $(( (mi * 223694 + 50000) / 100000 ))
    fi
}

to_cardinal() {
    local raw d scaled idx
    raw="$(sanitize_num "$1")"
    d="$(integer_round "$raw")"
    d="${d%.*}"
    while [ "$d" -lt 0 ];  do d=$(( d + 360 )); done
    while [ "$d" -ge 360 ]; do d=$(( d - 360 )); done
    scaled=$(( d * 100 + 1125 ))
    idx=$(( scaled / 2250  ))
    [ "$idx" -ge 16 ] && idx=0
    case "$idx" in
        0)  echo "N";; 1)  echo "NNE";; 2)  echo "NE";; 3)  echo "ENE";;
        4)  echo "E";; 5)  echo "ESE";; 6)  echo "SE";; 7)  echo "SSE";;
        8)  echo "S";; 9)  echo "SSW";; 10) echo "SW";; 11) echo "WSW";;
        12) echo "W";; 13) echo "WNW";; 14) echo "NW";; 15) echo "NNW";;
        *)  echo "N";;
    esac
}

mm_to_in() {
    local mm="$(sanitize_num "$1")"
    if has_bc; then
        local div; div="$(float_div "$mm" "25.4")"
        format_fixed_2 "$div"
    else
        local mi frac frac2 mm100
        mi="${mm%%.*}"
        frac="${mm#*.}"
        [ "$frac" = "$mm" ] && frac=""
        frac="${frac}00"
        frac2=$(printf '%s' "$frac" | cut -c1-2)
        case "$mi" in ''|*[^0-9-]*) mi=0;; esac
        case "$frac2" in ''|*[^0-9]*) frac2=0;; esac
        mm100=$(( mi * 100 + frac2 ))
        local hundredths=$(( (mm100 * 10 + 127) / 254 ))
        local whole=$(( hundredths / 100 ))
        local frac_out=$(( hundredths % 100 ))
        printf "%d.%02d" "$whole" "$frac_out"
    fi
}

curl_try_weather() {
    local url="$1"
    local hdr="${2:-}"
    local base_opts=(--silent --show-error --location --retry 2 --retry-delay 1 --connect-timeout 3 --max-time 6)
    local body=""

    if [ -n "$hdr" ]; then
        body="$(curl -4 --insecure "${base_opts[@]}" -H "$hdr" "$url" 2>/dev/null || true)"
    else
        body="$(curl -4 --insecure "${base_opts[@]}" "$url" 2>/dev/null || true)"
    fi
    [ -n "$body" ] && { printf '%s' "$body"; return; }

    if [ -n "$hdr" ]; then
        body="$(curl -6 "${base_opts[@]}" -H "$hdr" "$url" 2>/dev/null || true)"
    else
        body="$(curl -6 "${base_opts[@]}" "$url" 2>/dev/null || true)"
    fi

    dbg "curl_try_weather($url): len=${#body}"
    printf '%s' "$body"
}

curl_try() {
    local url="$1"
    local hdr="${2:-}"
    local base_opts=(--silent --show-error --location --retry 2 --retry-delay 1 --connect-timeout 3 --max-time 6)
    local body=""

    body="$(curl -4 --insecure "${base_opts[@]}" ${hdr:+-H "$hdr"} "$url" 2>/dev/null || true)"
    [ -n "$body" ] && { printf '%s' "$body"; return; }

    base_opts+=("--fail")
    body="$(curl -6 "${base_opts[@]}" ${hdr:+-H "$hdr"} "$url" 2>/dev/null || true)"

    dbg "curl_try($url): len=${#body}"
    printf '%s' "$body"
}

parse_lat_lon_openmeteo() {
    local blob="$1" lat lon
    printf '%s' "$blob" | grep -q '"results"[[:space:]]*:[[:space:]]*\[' || return 1
    lat=$(printf '%s' "$blob" | sed -n 's/.*"latitude"[[:space:]]*:[[:space:]]*\([-0-9.]\+\).*/\1/p' | head -n1)
    lon=$(printf '%s' "$blob" | sed -n 's/.*"longitude"[[:space:]]*:[[:space:]]*\([-0-9.]\+\).*/\1/p' | head -n1)
    [ -n "$lat" ] && [ -n "$lon" ] || return 1
    printf '%s %s\n' "$lat" "$lon"
}

parse_lat_lon_nominatim() {
    local blob="$1" lat lon
    [ "$blob" = "[]" ] && return 1
    [ -z "$blob" ] && return 1
    lat=$(printf '%s' "$blob" | sed -n 's/.*"lat"[[:space:]]*:[[:space:]]*"\([-0-9.]\+\)".*/\1/p' | head -n1)
    lon=$(printf '%s' "$blob" | sed -n 's/.*"lon"[[:space:]]*:[[:space:]]*"\([-0-9.]\+\)".*/\1/p' | head -n1)
    [ -n "$lat" ] && [ -n "$lon" ] || return 1
    printf '%s %s\n' "$lat" "$lon"
}

########################################
# JSON array helpers (sed/grep only)
########################################
has_json_array(){ printf '%s' "$2" | grep -q '"'$1'"[[:space:]]*:\s*\['; }

get_json_array_tail_nums(){
    local key="$1" N="$2" blob="$3"
    local arr
    arr="$(printf '%s' "$blob" | sed -n 's/.*"'"$key"'"[[:space:]]*:[[:space:]]*\[\([^]]*\)\].*/\1/p' | head -n1)"
    [ -z "$arr" ] && return 0

    local cleaned item
    cleaned=""
    IFS=',' read -r -a nums_raw <<< "$arr"
    for item in "${nums_raw[@]}"; do
        item="$(printf '%s' "$item" | sed 's/^[[:space:]]\+//; s/[[:space:]]\+$//')"
        case "$item" in
            null|"") continue;;
            *[!0-9.+-]*)
                if ! printf '%s' "$item" | grep -Eq '^[+-]?[0-9]*([.][0-9]+)?$'; then
                    continue
                fi
                ;;
        esac
        cleaned="$cleaned $item"
    done

    cleaned="$(printf '%s' "$cleaned" | sed 's/^[[:space:]]\+//')"
    [ -z "$cleaned" ] && return 0

    IFS=' ' read -r -a nums <<< "$cleaned"
    local count=${#nums[@]}
    local start=$((count - N)); [ $start -lt 0 ] && start=0
    local out="" i=$start
    while [ $i -lt $count ]; do
        [ -n "${nums[$i]}" ] && out="$out ${nums[$i]}"
        i=$((i+1))
    done
    printf '%s\n' "$out" | sed 's/^[[:space:]]\+//'
}

max_numeric_list() {
    local max="" n
    for n in $@; do
        n="$(sanitize_num "$n")"
        if [ -z "$max" ]; then
            max="$n"
        else
            if has_bc; then
                local gt
                gt="$(echo "$n > $max" | bc 2>/dev/null || echo 0)"
                [ "$gt" = "1" ] && max="$n"
            else
                local ni="${n%.*}"
                local mi="${max%.*}"
                [ "$ni" -gt "$mi" ] && max="$n"
            fi
        fi
    done
    [ -z "$max" ] && max="0"
    echo "$max"
}

cond_from_wmo() {
    local wmo="$1" cloud_cov="${2:-50}" is_day_flag="${3:-1}"
    case "$wmo" in
        95|96|99) echo "Thunderstorms"; return;;
        80|81|82|61|63|65|66|67|51|53|55|56|57) echo "Rain"; return;;
        71|73|75|77|85|86) echo "Snow"; return;;
        45|48) echo "Fog"; return;;
        89|90) echo "Hail"; return;;
    esac
    if [ "$cloud_cov" -le 10 ] 2>/dev/null; then
        [ "$is_day_flag" = "1" ] && echo "Sunny" || echo "Clear"
    elif [ "$cloud_cov" -le 35 ] 2>/dev/null; then
        [ "$is_day_flag" = "1" ] && echo "Mostly Sunny" || echo "Mostly Clear"
    elif [ "$cloud_cov" -le 65 ] 2>/dev/null; then
        echo "Partly Cloudy"
    elif [ "$cloud_cov" -lt 90 ] 2>/dev/null; then
        echo "Mostly Cloudy"
    else
        echo "Overcast"
    fi
}

build_condition_gsm() {
    local raw="${1:-}"
    [ -z "$raw" ] && return 1

    local base
    base="${raw%% — *}"
    base="$(printf '%s' "$base" | tr '[:upper:]' '[:lower:]')"
    base="$(printf '%s' "$base" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//; s/[[:space:]]+/ /g')"

    base="$(printf '%s' "$base" \
      | sed -E \
        -e 's/thunderstorms/thunderstorm/g' \
        -e 's/snow showers/snow/g' \
        -e 's/showers/rain/g' \
        -e 's/light rain/rain/g' \
        -e 's/light drizzle/rain/g' \
        -e 's/drizzle/rain/g' \
        -e 's/freezing drizzle/freezing rain/g' \
        -e 's/wintry mix/freezing rain/g' \
        -e 's/mixed precipitation/freezing rain/g' \
        -e 's/ice pellets/hail/g' \
        -e 's/sleet and freezing rain/sleet/g' \
        -e 's/freezing fog/fog/g' \
        -e 's/haze/foggy/g' \
        -e 's/smoky/foggy/g' \
        -e 's/smoke/foggy/g' \
        -e 's/mist/misty/g' \
        -e 's/misty/foggy/g' \
        -e 's/overcast/mostly cloudy/g' \
        -e 's/partly sunny/partly cloudy/g' \
        -e 's/mostly sunny/mostly clear/g' \
        -e 's/clear and windy/clear windy/g' \
        -e 's/clear and breezy/clear windy/g' \
        -e 's/windy and clear/clear windy/g' \
        -e 's/blowing snow/snow/g' \
        -e 's/blizzard/snow/g' \
        -e 's/flurries/snow/g' \
        -e 's/heavy snow/snow/g' \
        -e 's/heavy rain/rain/g' \
        -e 's/torrential rain/rain/g' \
        -e 's/downpour/rain/g' \
        -e 's/passing rain/rain/g' \
        -e 's/scattered rain/rain/g' \
        -e 's/scattered showers/rain/g' \
        -e 's/isolated showers/rain/g' \
        -e 's/scattered t-storms/thunderstorm/g' \
        -e 's/isolated t-storms/thunderstorm/g' \
        -e 's/t-storms/thunderstorm/g' \
        -e 's/t[- ]?storm(s)?/thunderstorm/g' \
    )"

    base="$(printf '%s' "$base" | sed -E 's/[^a-z]+/ /g; s/[[:space:]]+/ /g; s/^[[:space:]]+//; s/[[:space:]]+$//')"

    set -f
    IFS=' ' read -r w1 w2 w3 _ <<< "$base"
    set +f

    word_to_gsm() {
        case "$1" in
            mostly)        echo "/var/lib/asterisk/sounds/mostly.gsm" ;;
            partly)        echo "/var/lib/asterisk/sounds/partly.gsm" ;;
            patchy)        echo "/var/lib/asterisk/sounds/patchy.gsm" ;;
            scattered)     echo "/var/lib/asterisk/sounds/scattered.gsm" ;;
            cloudy|clouds) echo "/var/lib/asterisk/sounds/cloudy.gsm" ;;
            clear|sunny|sun) echo "/var/lib/asterisk/sounds/clear.gsm" ;;
            windy|wind|breezy) echo "/var/lib/asterisk/sounds/windy.gsm" ;;
            rain|rainy)    echo "/var/lib/asterisk/sounds/rain.gsm" ;;
            freezing)      echo "/var/lib/asterisk/sounds/freezing.gsm" ;;
            sleet|sleeting) echo "/var/lib/asterisk/sounds/sleet.gsm" ;;
            snow|snowy|snowing) echo "/var/lib/asterisk/sounds/snow.gsm" ;;
            hail)          echo "/var/lib/asterisk/sounds/hail.gsm" ;;
            fog|foggy|misty|haze|smoke|smoky) echo "/var/lib/asterisk/sounds/foggy.gsm" ;;
            thunderstorms|thunderstorm|thunder|storms|storm) echo "/var/lib/asterisk/sounds/thunderstorm.gsm" ;;
            fair)          echo "/var/lib/asterisk/sounds/clear.gsm" ;;
            tornado)       echo "/var/lib/asterisk/sounds/tornado.gsm" ;;
            hurricane|typhoon) echo "/var/lib/asterisk/sounds/hurricane.gsm" ;;
            *)             echo "" ;;
        esac
    }

    local f1 f2 f3
    f1="$(word_to_gsm "$w1")"
    f2="$(word_to_gsm "$w2")"
    f3="$(word_to_gsm "$w3")"

    if [ -z "$f1" ] && [ -z "$f2" ] && [ -z "$f3" ]; then
        rm -f "$destdir/condition.gsm" 2>/dev/null || true
        dbg "no gsm match for '$raw'"
        return 2
    fi

    if [ "$DEBUG" = "1" ]; then
        dbg "cond tokens: '$w1' '$w2' '$w3'"
        dbg "cond files: '${f1:-}' '${f2:-}' '${f3:-}'"
    fi
    if ! cat ${f1:+$f1} ${f2:+$f2} ${f3:+$f3} > "$destdir/condition.gsm.tmp" 2>/dev/null; then
        dbg "Failed to build condition.gsm.tmp"
        return 1
    fi
    [ -s "$destdir/condition.gsm.tmp" ] || { rm -f "$destdir/condition.gsm.tmp"; return 1; }

    if ! mv -f "$destdir/condition.gsm.tmp" "$destdir/condition.gsm" 2>/dev/null; then
        rm -f "$destdir/condition.gsm.tmp" 2>/dev/null
        dbg "Failed final mv -> condition.gsm"
        return 1
    fi

    return 0
}

########################################
# AIRPORT CACHE (/var/tmp only, flat files)
########################################
init_cache() {
    if [ ! -f "$CACHE_FILE" ]; then
        : > "$CACHE_FILE" 2>/dev/null || return 1
        chmod 666 "$CACHE_FILE" 2>/dev/null || true
    fi
    [ -w "$CACHE_FILE" ] || return 1
    return 0
}

load_from_cache() {
    local code="$1" now code_up
    [ -r "$CACHE_FILE" ] || return 1
    now=$(date +%s)
    code_up=$(printf '%s' "$code" | tr '[:lower:]' '[:upper:]')
    while IFS='|' read -r cached lat lon tz country ts; do
        [ -z "$cached" ] && continue
        [ "$cached" = "$code_up" ] || continue
        [ $((now - ts)) -gt "$CACHE_MAX_AGE" ] && continue
        printf '%s %s %s %s\n' "$lat" "$lon" "$tz" "$country"
        return 0
    done < "$CACHE_FILE"
    return 1
}

save_to_cache() {
    local code="$1" lat="$2" lon="$3" tz="$4" country="$5"
    [ -z "$code" ] && return 1
    [ -z "$lat"  ] && return 1
    [ -z "$lon"  ] && return 1

    init_cache || return 1

    local tmp_file="$CACHE_FILE.tmp.$$" now
    now=$(date +%s)

    if [ -f "$CACHE_FILE" ]; then
        while IFS='|' read -r cached lat_c lon_c tz_c country_c ts; do
            [ -z "$cached" ] && continue
            [ "$cached" = "$code" ] && continue
            [ $((now - ts)) -gt "$CACHE_MAX_AGE" ] && continue
            printf '%s|%s|%s|%s|%s|%d\n' \
                "$cached" "$lat_c" "$lon_c" "$tz_c" "$country_c" "$ts" >> "$tmp_file"
        done < "$CACHE_FILE"
    fi

    printf '%s|%s|%s|%s|%s|%d\n' "$code" "$lat" "$lon" "$tz" "$country" "$now" >> "$tmp_file"

    mv -f "$tmp_file" "$CACHE_FILE" 2>/dev/null || {
        rm -f "$tmp_file" 2>/dev/null
        return 1
    }
    chmod 666 "$CACHE_FILE" 2>/dev/null || true
    return 0
}

airport_download_raw() {
    local url_https="https://ourairports.com/data/airports.csv"
    local url_http="http://ourairports.com/data/airports.csv"
    local base_opts=(--silent --show-error --location --retry 2 --retry-delay 1 --connect-timeout 5 --max-time 10)
    local data

    data="$(curl -4 --insecure "${base_opts[@]}" "$url_https" 2>/dev/null || true)"
    [ -n "$data" ] && { printf '%s' "$data"; return; }

    data="$(curl -6 "${base_opts[@]}" --fail "$url_https" 2>/dev/null || true)"
    [ -n "$data" ] && { printf '%s' "$data"; return; }

    data="$(curl -4 --insecure "${base_opts[@]}" "$url_http" 2>/dev/null || true)"
    [ -n "$data" ] && { printf '%s' "$data"; return; }

    printf ''
}

airport_file_age() {
    local f="$1"
    [ -f "$f" ] || { echo 999999999; return; }
    local mtime now
    mtime=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo 0)
    now=$(date +%s)
    echo $(( now - mtime ))
}

ensure_airport_db() {
    if [ -s "$AIRPORT_DB" ]; then
        if [ "$(wc -l < "$AIRPORT_DB" 2>/dev/null)" -gt 1 ]; then
            dbg "using cached $AIRPORT_DB"
            return 0
        fi
        dbg "$AIRPORT_DB exists but looks empty, will try rebuild"
    fi

    dbg "no valid airport DB, bootstrapping in /var/tmp (no new dirs)"

    rm -f "$AIRPORT_FULL" "${AIRPORT_DB}.tmp" 2>/dev/null || true

    curl -4 --insecure --silent --show-error --location --retry 2 --retry-delay 1 \
         --connect-timeout 5 --max-time 20 \
         "https://ourairports.com/data/airports.csv" > "$AIRPORT_FULL" 2>/dev/null || true

    if [ ! -s "$AIRPORT_FULL" ]; then
        curl --insecure --silent --show-error --location --retry 2 --retry-delay 1 \
             --connect-timeout 5 --max-time 20 \
             "https://ourairports.com/data/airports.csv" > "$AIRPORT_FULL" 2>/dev/null || true
    fi

    if [ ! -s "$AIRPORT_FULL" ]; then
        dbg "download failed or empty; cannot build airport DB"
        rm -f "$AIRPORT_FULL" "${AIRPORT_DB}.tmp" 2>/dev/null || true
        return 1
    fi

    {
        echo "ident,type,name,lat,lon,iso_country,iata_code"
        awk -F',' 'NR>1 {
            # OurAirports CSV fields:
            # 1:id, 2:ident, 3:type, 4:name, 5:lat, 6:lon
            # 9:iso_country, 14:iata_code

            ident=$2;
            type=$3;
            name=$4;
            lat=$5;
            lon=$6;
            iso=$9;
            iata=$14;

            # strip quotes
            gsub(/^"|"$/, "", ident)
            gsub(/^"|"$/, "", type)
            gsub(/^"|"$/, "", name)
            gsub(/^"|"$/, "", lat)
            gsub(/^"|"$/, "", lon)
            gsub(/^"|"$/, "", iso)
            gsub(/^"|"$/, "", iata)

            print ident","type","name","lat","lon","iso","iata;
        }' "$AIRPORT_FULL"
    } > "${AIRPORT_DB}.tmp" 2>/dev/null

    if [ "$(wc -l < "${AIRPORT_DB}.tmp" 2>/dev/null)" -le 1 ]; then
        dbg "trim step produced no data or header-only; aborting"
        rm -f "$AIRPORT_FULL" "${AIRPORT_DB}.tmp" 2>/dev/null || true
        return 1
    fi

    mv -f "${AIRPORT_DB}.tmp" "$AIRPORT_DB" 2>/dev/null || {
        dbg "failed to move airport DB tmp file"
        rm -f "$AIRPORT_FULL" "${AIRPORT_DB}.tmp" 2>/dev/null || true
        return 1
    }

    chmod 644 "$AIRPORT_DB" 2>/dev/null || true
    rm -f "$AIRPORT_FULL" 2>/dev/null || true

    dbg "airport DB built successfully at $AIRPORT_DB"
    return 0
}


lookup_airport_coords() {
    local CODE_UP ROW SAFE_ROW TMP ch inquote i len
    local col1 col2 col3 col4 col5 col6 rest
    local ident type name lat lon iso_country
    local allowed needle

    CODE_UP="$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')"
    dbg "lookup_airport_coords($CODE_UP) using $AIRPORT_DB"

    [ -r "$AIRPORT_DB" ] || return 1

    ROW="$(grep -i '^"'"$CODE_UP"'"' "$AIRPORT_DB" | head -n1 || true)"
    [ -z "${ROW:-}" ] && ROW="$(grep -i '^'"$CODE_UP"',' "$AIRPORT_DB" | head -n1 || true)"
    if [ -z "${ROW:-}" ]; then
        ROW="$(grep -i "\"$CODE_UP\"" "$AIRPORT_DB" | head -n1 || true)"
    fi
    if [ -z "${ROW:-}" ]; then
        dbg "no row found for $CODE_UP"
        return 1
    fi

    SAFE_ROW="${ROW}"
    TMP=""
    inquote=0
    i=1
    len=${#SAFE_ROW}
    while [ $i -le $len ]; do
        ch=$(printf '%s' "$SAFE_ROW" | cut -c$i)
        if [ "$ch" = "\"" ]; then
            if [ $inquote -eq 0 ]; then inquote=1; else inquote=0; fi
            TMP="${TMP}${ch}"
        elif [ $inquote -eq 1 ] && [ "$ch" = "," ]; then
            TMP="${TMP}"$'\x1F'
        else
            TMP="${TMP}${ch}"
        fi
        i=$((i+1))
    done

    IFS=',' read -r col1 col2 col3 col4 col5 col6 rest <<< "$TMP"

    restore_commas() { printf '%s' "$1" | tr '\x1F' ','; }
    clean_field() { printf '%s' "$1" | sed 's/^"//; s/"$//; s/^[[:space:]]*//; s/[[:space:]]*$//'; }

    ident="$(clean_field "$(restore_commas "${col1:-}")")"
    type="$(clean_field "$(restore_commas "${col2:-}")")"
    name="$(clean_field "$(restore_commas "${col3:-}")")"
    lat="$(clean_field "$(restore_commas "${col4:-}")")"
    lon="$(clean_field "$(restore_commas "${col5:-}")")"
    iso_country="$(clean_field "$(restore_commas "${col6:-}")")"

    lat="$(printf '%s' "$lat" | sed 's/[^0-9+.\-].*$//')"
    lon="$(printf '%s' "$lon" | sed 's/[^0-9+.\-].*$//')"

    if [ -z "${lat:-}" ] || [ -z "${lon:-}" ]; then
        dbg "row for $CODE_UP missing lat/lon"
        return 1
    fi

    allowed=",$ALLOWED_AIRPORT_TYPES,"
    needle=",$type,"
    if ! printf '%s' "$allowed" | grep -qF "$needle"; then
        dbg "type '$type' for $CODE_UP not allowed (allowed=$ALLOWED_AIRPORT_TYPES)"
        return 1
    fi

    dbg "$CODE_UP matched ident='$ident' type='$type' name='$name' lat=$lat lon=$lon country=${iso_country:-??}"
    printf '%s %s %s %s\n' "$lat" "$lon" "auto" "${iso_country:-US}"
    return 0
}

########################################
#  ICAO LOOKUP  (4-letter)
########################################
lookup_airport_icao() {
    local code="$1"
    awk -F',' -v c="$code" '
        NR>1 {
            # Strip quotes from each column
            for (i=1;i<=NF;i++) gsub(/^"|"$/, "", $i)

            ident = toupper($1)
            if (ident == c) {
                printf "%s %s auto %s\n", $4, $5, $6
                exit 0
            }
        }
    ' "$AIRPORT_DB"
}

########################################
#  IATA LOOKUP  (3-letter)
########################################
lookup_airport_iata() {
    local code="$1"
    awk -F',' -v c="$code" '
        NR>1 {
            for (i=1;i<=NF;i++) gsub(/^"|"$/, "", $i)

            iata = toupper($7)

            if (iata == c) {
                printf "%s %s auto %s\n", $4, $5, $6
                exit 0
            }
        }
    ' "$AIRPORT_DB"
}


########################################
# CLEAN INPUT
########################################
RAW="$(printf '%s' "$LOCATION_RAW" \
    | tr '[:lower:]' '[:upper:]' \
    | sed 's/[[:space:]]//g')"

dbg "RAW NORMALIZED = $RAW"

########################################
# Ensure Airport DB exists BEFORE any airport lookup
########################################
ensure_airport_db || {
    dbg "Could not initialize airport DB"
}

MODE=""
LAT=""
LON=""
COUNTRY=""
TZ_USED="auto"
COUNTRY_PREFIX=""
POSTAL=""
FOUND=""


########################################
# 1) AIRPORT IDENT EXACT MATCH (ICAO or IATA)
########################################

# Normalize RAW is already uppercase
CODE="$RAW"

# ICAO (4 letters)
if echo "$RAW" | grep -Eq '^[A-Z]{4}$'; then
    dbg "ICAO FORCED AIRPORT FOR $RAW"
    MODE="AIRPORT_FORCED"
fi

# IATA (3 letters)
if [ -z "$MODE" ] && echo "$RAW" | grep -Eq '^[A-Z]{3}$'; then
    if lookup_airport_iata "$RAW" >/dev/null; then
        dbg "IATA FORCED AIRPORT FOR $RAW"
        MODE="AIRPORT_FORCED"
    else
        dbg "3-letter code '$RAW' not found in IATA column → not forcing airport"
    fi
fi

########################################
# 2) INTERNATIONAL POSTAL (only if not forced AIRPORT)
########################################
if [ -z "$MODE" ]; then

    # pattern: JP-100-0005, FR75000, CAK1A0B1, etc.
    if echo "$RAW" | grep -Eq '^([A-Z]{2})[-_ ]*([A-Z0-9-]+)$'; then

        COUNTRY_PREFIX="${RAW:0:2}"

        # strip prefix and remove ALL hyphens/underscores/spaces
        POSTAL="$(echo "$RAW" \
            | sed -E 's/^[A-Z]{2}[-_ ]*//' \
            | sed 's/[-_ ]//g')"

        dbg "INTL_POSTAL DETECTED: COUNTRY=$COUNTRY_PREFIX / POSTAL=$POSTAL"

        if [ -n "$POSTAL" ]; then
            UA="User-Agent: supermon-weather/1.0 (https://wg5eek.com/contact)"
            REF="Referer: https://wg5eek.com/"

            URL1="https://nominatim.openstreetmap.org/search?countrycodes=${COUNTRY_PREFIX}&postalcode=${POSTAL}&format=json&limit=1"
            dbg "Nominatim Postal URL1: $URL1"
            GEO="$(curl -s -H "$UA" -H "$REF" "$URL1")"

            # Fallback
            if [ -z "$GEO" ] || [ "${#GEO}" -lt 20 ]; then
                URL2="https://nominatim.openstreetmap.org/search?q=${POSTAL}%20${COUNTRY_PREFIX}&format=json&limit=1"
                dbg "Nominatim Postal URL2: $URL2"
                GEO="$(curl -s -H "$UA" -H "$REF" "$URL2")"
            fi

            LAT="$(echo "$GEO" | sed -n 's/.*"lat":"\([^"]*\)".*/\1/p' | head -n1)"
            LON="$(echo "$GEO" | sed -n 's/.*"lon":"\([^"]*\)".*/\1/p' | head -n1)"

            if [ -n "$LAT" ] && [ -n "$LON" ]; then
                dbg "INTL POSTAL MATCH LAT=$LAT LON=$LON COUNTRY=$COUNTRY_PREFIX"
                MODE="INTL"
                COUNTRY="$COUNTRY_PREFIX"
            else
                dbg "INTL_POSTAL FAILED"
            fi
        fi
    fi
fi



########################################
# 3) US ZIP MODE (only if not INTL / not forced AIRPORT)
########################################
if [ -z "$MODE" ]; then
    if echo "$RAW" | grep -Eq '^[0-9]{5}$'; then
        ZIP="$RAW"
        dbg "ZIP lookup $ZIP"

        GEO="$(curl_try_weather "https://geocoding-api.open-meteo.com/v1/search?name=${ZIP}&count=1&language=en&format=json")"
        if [ -n "$GEO" ]; then
            read LAT LON < <(parse_lat_lon_openmeteo "$GEO" || true)
        fi

        # ZIP fallback Nominatim
        if [ -z "$LAT" ] || [ -z "$LON" ]; then
            NOMI_URL="https://nominatim.openstreetmap.org/search?country=US&postalcode=${ZIP}&format=json&limit=1"
            GEO2="$(curl_try "$NOMI_URL" "User-Agent: ${NWS_USER_AGENT}")"
            read LAT LON < <(parse_lat_lon_nominatim "$GEO2" || true)
        fi

        if [ -n "$LAT" ] && [ -n "$LON" ]; then
            MODE="ZIP"
            COUNTRY="US"
        fi
    fi
fi


########################################
# 4) AIRPORT IDENT DB EXACT MATCH (ICAO + IATA)
########################################
if [ -z "$MODE" ] || [ "$MODE" = "AIRPORT_FORCED" ]; then

    result="$(lookup_airport_icao "$RAW")"
    if [ -n "$result" ]; then
        read LAT LON TZ_USED COUNTRY <<< "$result"
        dbg "AIRPORT_DIRECT_HIT (ICAO) $RAW → LAT=$LAT LON=$LON COUNTRY=$COUNTRY"
        MODE="AIRPORT"
    else
        if [ ${#RAW} -eq 3 ]; then
            result="$(lookup_airport_iata "$RAW")"
            if [ -n "$result" ]; then
                read LAT LON TZ_USED COUNTRY <<< "$result"
                dbg "AIRPORT_IATA_HIT $RAW → LAT=$LAT LON=$LON COUNTRY=$COUNTRY"
                MODE="AIRPORT"
            fi
        fi
    fi
fi


########################################
# 5) AIRPORT API GEOCODING FALLBACK
########################################
if [ -z "$MODE" ] || [ "$MODE" = "AIRPORT_FORCED" ]; then
    dbg "AIRPORT fallback geocode $RAW"

    for SEARCH in "$RAW" "${RAW} AIRPORT" "${RAW} INTERNATIONAL AIRPORT"; do
        S_ESC="$(echo "$SEARCH" | sed 's/ /%20/g')"
        GEO="$(curl_try_weather "https://geocoding-api.open-meteo.com/v1/search?name=${S_ESC}&count=5&language=en&format=json")"

        if printf '%s' "$GEO" | grep -qi 'airport'; then
            read LAT LON < <(parse_lat_lon_openmeteo "$GEO" || true)
            COUNTRY="$(echo "$GEO" | sed -n 's/.*"country_code":"\([^"]*\)".*/\1/p')"
            dbg "AIRPORT API MATCH LAT=$LAT LON=$LON COUNTRY=$COUNTRY"
            MODE="AIRPORT"
            break
        fi
    done
fi


########################################
# 6) AIRPORT DB FALLBACK (final last chance)
########################################
if [ -z "$MODE" ]; then
    dbg "Airport DB fallback"
    result="$(lookup_airport_ident "$RAW")"
    if [ -n "$result" ]; then
        read LAT LON TZ_USED COUNTRY <<< "$result"
        dbg "AIRPORT_DB_MATCH LAT=$LAT LON=$LON COUNTRY=$COUNTRY"
        MODE="AIRPORT"
    fi
fi


########################################
# FINAL VALIDATION
########################################
if [ -z "$LAT" ] || [ -z "$LON" ]; then
    echo "No Report"
    exit 1
fi

dbg "USING MODE=$MODE LAT=$LAT LON=$LON COUNTRY=$COUNTRY"

########################################
# FETCH CURRENT WX FROM OPEN-METEO
########################################
if [ "$Temperature_mode" = "F" ]; then
    temperature_unit="fahrenheit"
else
    temperature_unit="celsius"
fi

API_BASE="http://api.open-meteo.com/v1/forecast"
CUR_KEYS="temperature_2m,weather_code,relative_humidity_2m,pressure_msl,wind_speed_10m,wind_direction_10m,wind_gusts_10m,precipitation,rain,showers,snowfall,cloud_cover,is_day"
QS="latitude=${LAT}&longitude=${LON}&timezone=${TZ_USED}&temperature_unit=${temperature_unit}&wind_speed_unit=ms&precipitation_unit=mm&current=${CUR_KEYS}&minutely_15=precipitation&hourly=cape"
URL="${API_BASE}?${QS}"

dbg "Open-Meteo URL: $URL"
RAW="$(curl_try_weather "$URL")"
[ -n "$RAW" ] || { echo "No Report"; exit 1; }

JSON="$(printf '%s' "$RAW" | tr -d '\n' | tr -d '\r')"
printf '%s' "$JSON" | grep -q '"error"[[:space:]]*:[[:space:]]*true' && { echo "No Report"; exit 1; }

CUR_CHUNK="$(printf '%s' "$JSON" | sed -n 's/.*"current"[[:space:]]*:{\([^}]*\)}.*/\1/p')"
[ -n "$CUR_CHUNK" ] || CUR_CHUNK="$JSON"

quick_field () {
    local k="$1"
    printf '%s' "$2" \
      | sed -n 's/.*"'"$k"'":[[:space:]]*\([-0-9.]\+\).*/\1/p' \
      | head -n1
}

T_NOW="$(quick_field temperature_2m "$CUR_CHUNK")"
[ -n "$T_NOW" ] || { echo "No Report"; exit 1; }

WCODE="$(quick_field weather_code "$CUR_CHUNK")"
RH="$(quick_field relative_humidity_2m "$CUR_CHUNK")"
PMSL="$(quick_field pressure_msl "$CUR_CHUNK")"
WS="$(quick_field wind_speed_10m "$CUR_CHUNK")"
WD="$(quick_field wind_direction_10m "$CUR_CHUNK")"
WG="$(quick_field wind_gusts_10m "$CUR_CHUNK")"
CC="$(quick_field cloud_cover "$CUR_CHUNK")"
IS_DAY="$(quick_field is_day "$CUR_CHUNK")"

# --- temps in both units (force C to one decimal) ---
if [ "$Temperature_mode" = "F" ]; then
    TF="$(round "$T_NOW")"
    # Use raw T_NOW (in F here) → C with exactly 1 decimal
    if has_bc; then
        TC_1DP="$(echo "scale=6; (($T_NOW - 32) * 5) / 9" | bc 2>/dev/null | awk '{printf("%.1f",$0)}')"
    else
        TC_1DP="$(awk 'BEGIN{printf("%.1f", (('"$T_NOW"'-32)*5)/9)}')"
    fi
    TOUT="$TF"
else
    # Temperature_mode=C: T_NOW is °C. Keep integer for /var/tmp/temperature, show 1dp for display.
    TC_INT="$(round "$T_NOW")"
    if has_bc; then
        TC_1DP="$(echo "$T_NOW" | awk '{printf("%.1f",$0)}')"
    else
        TC_1DP="$(awk 'BEGIN{printf("%.1f", '"$T_NOW"') }')"
    fi
    TF="$(c_to_f "$TC_INT")"
    TOUT="$TC_INT"
fi

# --- degree strings (C always 1dp) ---
if [ "$Temperature_mode" = "F" ]; then
    MAIN_DEG="${TF}${DEG}F"
    ALT_DEG="${TC_1DP}${DEG}C"
else
    MAIN_DEG="${TC_1DP}${DEG}C"
    ALT_DEG="${TF}${DEG}F"
fi

COND_TITLE="$(cond_from_wmo "$WCODE" "${CC:-}" "${IS_DAY:-}")"

# Optional thunderstorm override using CAPE (hourly only)
if [ "${ENABLE_THUNDERSTORM}" = "YES" ] && [ "${USE_CAPE}" = "YES" ]; then
    CAPE_ARR=$(printf '%s' "$JSON" \
        | sed -n 's/.*"cape"[[:space:]]*:[[:space:]]*\[\([^]]*\)\].*/\1/p' \
        | head -n1)
    if [ -n "$CAPE_ARR" ]; then
        CAPE_STUB='{"cape":['"$CAPE_ARR"']}'
        CAPE_TAIL="$(get_json_array_tail_nums "cape" "${LOOKBACK_SAMPLES}" "$CAPE_STUB" || true)"
        CAPE_MAX="$(max_numeric_list $CAPE_TAIL)"
        if [ -n "${CAPE_MAX:-}" ]; then
            PR_NOW="$(quick_field precipitation "$CUR_CHUNK")"
            RAIN_NOW="$(quick_field rain "$CUR_CHUNK")"
            SHOWERS_NOW="$(quick_field showers "$CUR_CHUNK")"
            PRECIP_NOW_MAX="$(max_numeric_list ${PR_NOW:-0} ${RAIN_NOW:-0} ${SHOWERS_NOW:-0})"

            cape_ok=0; precip_ok=0; cloud_ok=0
            if has_bc; then
                cape_ok="$(echo "$(sanitize_num "$CAPE_MAX") >= $(sanitize_num "${LP_THRESHOLD:-0}")" | bc 2>/dev/null || echo 0)"
                precip_ok="$(echo "$(sanitize_num "${PRECIP_NOW_MAX:-0}") >= $(sanitize_num "${PRECIP_TRACE_MM:-0}")" | bc 2>/dev/null || echo 0)"
                cloud_ok="$(echo "$(sanitize_num "${CC:-0}") >= $(sanitize_num "${TS_CLOUD_COVER_MIN:-0}")" | bc 2>/dev/null || echo 0)"
            else
                cmi="${CAPE_MAX%.*}"; lpi="${LP_THRESHOLD%.*}"; [ "$cmi" -ge "$lpi" ] && cape_ok=1 || cape_ok=0
                printf '%s' "${PRECIP_NOW_MAX:-0}" | grep -Eq '^[+-]?0*(\.0+)?$' && precip_ok=0 || precip_ok=1
                cci="${CC%.*}"; tci="${TS_CLOUD_COVER_MIN%.*}"; [ "$cci" -ge "$tci" ] && cloud_ok=1 || cloud_ok=0
            fi

            if [ "${cape_ok}" = "1" ] && [ "${precip_ok}" = "1" ] && [ "${cloud_ok}" = "1" ]; then
                COND_TITLE="Thunderstorms"
            fi
        fi
    fi
fi

########################################
# NWS ALERTS (short list)
########################################
ALERTS_JOINED=""
if [ "$USE_NWS_ALERTS" = "YES" ]; then
    NWS_URL="https://api.weather.gov/alerts/active?point=${LAT},${LON}"
    HDR="User-Agent: ${NWS_USER_AGENT}"
    NWS_JSON="$(curl_try "$NWS_URL" "$HDR")"
    if [ -n "$NWS_JSON" ]; then
        EVENTS_RAW="$(printf '%s' "$NWS_JSON" \
          | grep -o '"event"[[:space:]]*:[[:space:]]*"[^"]\+"' \
          | sed 's/.*"event"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')"
        if [ -n "$EVENTS_RAW" ]; then
            uniq_alerts=""
            while IFS= read -r ev_raw; do
                [ -z "$ev_raw" ] && continue
                echo "$uniq_alerts" | grep -Fx "$ev_raw" >/dev/null 2>&1 && continue
                uniq_alerts="${uniq_alerts}${uniq_alerts:+$'\n'}${ev_raw}"
            done <<EOF
$EVENTS_RAW
EOF
            count=0
            joined_tmp=""
            ALERT_FIRST=""
            while IFS= read -r ev_one; do
                [ -z "$ev_one" ] && continue
                count=$((count+1))
                [ $count -eq 1 ] && ALERT_FIRST="$ev_one"
                joined_tmp="${joined_tmp:+$joined_tmp, }${ev_one}"
                [ $count -ge ${NWS_ALERTS_MAX:-3} ] && break
            done <<EOF
$uniq_alerts
EOF
            ALERTS_JOINED="$joined_tmp"
            [ -n "$ALERT_FIRST" ] && printf '%s\n' "$ALERT_FIRST" > "$destdir/alert.gsm.txt"
        fi
    fi
fi

########################################
# BUILD SEGMENTS
########################################
HUMIDITY_STR=""
[ -n "${RH:-}" ] && HUMIDITY_STR="$(round "$RH")% RH"

PRESSURE_STR=""
if [ -n "$PMSL" ]; then
    PARTS=""

    if [ "$SHOW_PRESSURE_INHG" = "YES" ]; then
        INHG="$(hpa_to_inhg "$PMSL")"
        if [ -n "$INHG" ]; then
            PARTS="${PARTS}${PARTS:+ / }${INHG} inHG"
        fi
    fi

    if [ "$SHOW_PRESSURE_HPA" = "YES" ]; then
        HPA_VAL="$(round "$PMSL")"
        if [ -n "$HPA_VAL" ]; then
            PARTS="${PARTS}${PARTS:+ / }${HPA_VAL} hPa"
        fi
    fi

    PRESSURE_STR="$PARTS"
fi

WIND_STR=""
if [ -n "$WS" ]; then
    mph="$(ms_to_mph "$WS")"

    # km/h: m/s × 3.6
    if has_bc; then
        kmh="$(echo "$WS*3.6" | bc | awk '{printf("%d",$0+0.5)}')"
    else
        ws_int="${WS%.*}"; kmh=$(( (ws_int * 36 + 5) / 10 ))
    fi

    # knots: m/s × 1.94384
    if has_bc; then
        kn="$(echo "$WS*1.94384" | bc | awk '{printf("%d",$0+0.5)}')"
    else
        ws_int="${WS%.*}"; kn=$(( (ws_int * 194384 + 50000)/100000 ))
    fi

    WIND_STR="Wind"

    [ "$SHOW_WIND_MPH" = "YES" ] && WIND_STR="${WIND_STR} ${mph} mph"
    [ "$SHOW_WIND_KMH" = "YES" ] && WIND_STR="${WIND_STR} / ${kmh} km/h"
    [ "$SHOW_WIND_KN"  = "YES" ] && WIND_STR="${WIND_STR} / ${kn} kt"

    if [ -n "$WD" ]; then
        DIR="$(to_cardinal "$WD")"
        WIND_STR="${WIND_STR} ${DIR}"
    fi

    # gusts
    if [ -n "$WG" ]; then
        gust_mph="$(ms_to_mph "$WG")"
        WIND_STR="${WIND_STR} (gust ${gust_mph})"
    fi
fi


MAIN_DEG=""
ALT_DEG=""

# Build Fahrenheit string
if [ "$SHOW_FAHRENHEIT" = "YES" ]; then
    if [ "$Temperature_mode" = "F" ]; then
        MAIN_DEG="${TF}${DEG}F"
    else
        ALT_DEG="${TF}${DEG}F"
    fi
fi

# Build Celsius string (1 decimal)
if [ "$SHOW_CELSIUS" = "YES" ]; then
    if [ "$Temperature_mode" = "C" ]; then
        MAIN_DEG="$(force_one_decimal "$TC_1DP")${DEG}C"
    else
        ALT_DEG="$(force_one_decimal "$TC_1DP")${DEG}C"
    fi
fi

# Build SEG1
SEG1="$MAIN_DEG"
if [ -n "$ALT_DEG" ]; then
    SEG1="$SEG1, $ALT_DEG"
fi


SEG1="$MAIN_DEG"
[ -n "$ALT_DEG" ]      && SEG1="$SEG1, $ALT_DEG"
[ -n "$HUMIDITY_STR" ] && SEG1="$SEG1, $HUMIDITY_STR"

SEG2="$COND_TITLE"
[ "$SHOW_PRECIP" = "YES" ] && {
    PRECIP_STR=""
    PR_RECENT=""
    PR_CUR=""
    ARR="$(printf '%s' "$JSON" \
        | sed -n 's/.*"minutely_15"[[:space:]]*:{[^}]*"precipitation"[[:space:]]*:[[:space:]]*\[\([^]]*\)\].*/\1/p' \
        | head -n1)"
    if [ -n "$ARR" ]; then
        STUB='{"precipitation":['"$ARR"']}'
        PR_LASTS="$(get_json_array_tail_nums "precipitation" "${LOOKBACK_SAMPLES}" "$STUB" || true)"
        PR_RECENT="$(max_numeric_list $PR_LASTS)"
    fi
    PR_CUR="$(quick_field precipitation "$CUR_CHUNK")"
    PR_MM="${PR_RECENT:-}"
    if [ -n "$PR_CUR" ]; then
        if [ -z "$PR_MM" ]; then
            PR_MM="$PR_CUR"
        else
            if has_bc; then
                cmp="$(echo "$(sanitize_num "$PR_CUR") > $(sanitize_num "$PR_MM")" | bc 2>/dev/null || echo 0)"
                [ "$cmp" = "1" ] && PR_MM="$PR_CUR"
            else
                ci="${PR_CUR%.*}"; mi="${PR_MM%.*}"; [ "$ci" -gt "$mi" ] && PR_MM="$PR_CUR"
            fi
        fi
    fi

    if [ -n "$PR_MM" ]; then
        showp=1
        if [ "${SHOW_ZERO_PRECIP}" != "YES" ]; then
            if has_bc; then
                gt="$(echo "$(sanitize_num "$PR_MM") >= $(sanitize_num "${PRECIP_TRACE_MM:-0}")" | bc 2>/dev/null || echo 0)"
                [ "$gt" != "1" ] && showp=0
            else
                printf '%s' "$PR_MM" | grep -Eq '^[+-]?0*(\.0+)?$' && showp=0 || true
            fi
        fi
        if [ "${showp:-0}" -eq 1 ]; then
            units_join=""
            inches_zero=0
            mm_zero=0
            if [ "$SHOW_PRECIP_INCH" = "YES" ]; then
                INCHES="$(mm_to_in "$PR_MM")"
                if [ -n "$INCHES" ]; then
                    units_join="$INCHES in"
                    if [ "$SHOW_ZERO_PRECIP" != "YES" ]; then
                        case "$INCHES" in 0.00|-0.00|+0.00) inches_zero=1;; esac
                    fi
                fi
            fi
            if [ "$SHOW_PRECIP_MM" = "YES" ]; then
                MMF="$(format_fixed_2 "$PR_MM")"
                if [ -n "$MMF" ]; then
                    if [ -n "$units_join" ]; then units_join="$units_join / ${MMF} mm"; else units_join="${MMF} mm"; fi
                    if [ "$SHOW_ZERO_PRECIP" != "YES" ]; then
                        case "$MMF" in 0.00|-0.00|+0.00) mm_zero=1;; esac
                    fi
                fi
            fi
            if [ "$SHOW_ZERO_PRECIP" != "YES" ] && [ "$SHOW_PRECIP_INCH" = "YES" ] && [ "$inches_zero" -eq 1 ]; then
                if [ "$SHOW_PRECIP_MM" != "YES" ] || [ "$mm_zero" -eq 1 ]; then
                    units_join=""
                fi
            fi
            [ -n "$units_join" ] && PRECIP_STR="Precip ${units_join}"
        fi
    fi
    [ -n "$PRECIP_STR" ] && SEG2="$SEG2, $PRECIP_STR"
}
[ -n "$WIND_STR" ]     && SEG2="$SEG2, $WIND_STR"
[ -n "$PRESSURE_STR" ] && SEG2="$SEG2, $PRESSURE_STR"

SEG3=""
[ -n "$ALERTS_JOINED" ] && SEG3="Alerts: $ALERTS_JOINED"

if [ -n "$SEG3" ]; then
    FINAL_LINE="$SEG1 / $SEG2 / $SEG3"
else
    FINAL_LINE="$SEG1 / $SEG2"
fi

# Single-line text output
echo "$FINAL_LINE"

########################################
# WRITE /var/tmp FILES FOR ASTERISK
########################################
if [ "$Temperature_mode" = "C" ]; then
    tmin=-60; tmax=60
else
    tmin=-100; tmax=150
fi

if [ -n "${TOUT:-}" ] &&
   [ "$TOUT" -ge "$tmin" ] 2>/dev/null &&
   [ "$TOUT" -le "$tmax" ] 2>/dev/null; then
    echo "$TOUT" > "$destdir/temperature" 2>/dev/null || true
fi

if [ "$process_condition" = "YES" ] && [ -n "${COND_TITLE:-}" ]; then
    build_condition_gsm "$COND_TITLE" || true
fi

exit 0
