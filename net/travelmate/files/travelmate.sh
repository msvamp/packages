#!/bin/sh
# travelmate, a wlan connection manager for travel router
# Copyright (c) 2016-2022 Dirk Brenken (dev@brenken.org)
# This is free software, licensed under the GNU General Public License v3.

# set (s)hellcheck exceptions
# shellcheck disable=1091,2086,3040,3043,3057,3060

export LC_ALL=C
export PATH="/usr/sbin:/usr/bin:/sbin:/bin"
set -o pipefail

trm_ver="2.0.8"
trm_enabled="0"
trm_debug="0"
trm_iface=""
trm_captive="1"
trm_proactive="1"
trm_netcheck="0"
trm_autoadd="0"
trm_randomize="0"
trm_mail="0"
trm_mailpgm="/etc/travelmate/travelmate.mail"
trm_vpnpgm="/etc/travelmate/travelmate.vpn"
trm_minquality="35"
trm_maxretry="3"
trm_maxwait="30"
trm_maxautoadd="5"
trm_maxscan="10"
trm_timeout="60"
trm_opensta="0"
trm_radio=""
trm_connection=""
trm_wpaflags=""
trm_uplinkcfg=""
trm_rtfile="/tmp/trm_runtime.json"
trm_wifi="$(command -v wifi)"
trm_fetch="$(command -v curl)"
trm_iwinfo="$(command -v iwinfo)"
trm_logger="$(command -v logger)"
trm_wpa="$(command -v wpa_supplicant)"
trm_captiveurl="http://detectportal.firefox.com"
trm_useragent="Mozilla/5.0 (Linux x86_64; rv:90.0) Gecko/20100101 Firefox/90.0"
trm_ntpfile="/var/state/travelmate.ntp"
trm_vpnfile="/var/state/travelmate.vpn"
trm_mailfile="/var/state/travelmate.mail"
trm_refreshfile="/var/state/travelmate.refresh"
trm_pidfile="/var/run/travelmate.pid"
trm_action="${1:-"start"}"

# load travelmate environment
#
f_env() {
	local check wpa_checks result

	if [ "${trm_action}" = "stop" ]; then
		return
	fi

	unset trm_stalist trm_radiolist trm_uplinklist trm_uplinkcfg trm_wpaflags trm_activesta trm_opensta

	trm_sysver="$(ubus -S call system board 2>/dev/null | jsonfilter -q -e '@.model' -e '@.release.description' |
		awk 'BEGIN{RS="";FS="\n"}{printf "%s, %s",$1,$2}')"

	config_cb() {
		local name="${1}" type="${2}"

		if [ "${name}" = "travelmate" ] && [ "${type}" = "global" ]; then
			option_cb() {
				local option="${1}" value="${2}"
				eval "${option}=\"${value}\""
			}
		elif [ "${name}" = "uplink" ]; then
			if [ "$(uci_get "travelmate.${type}.opensta")" = "1" ]; then
				eval "trm_opensta=\"$((${trm_opensta:-0} + 1))\""
			fi
		else
			option_cb() {
				return 0
			}
		fi
	}
	config_load travelmate

	if [ "${trm_enabled}" != "1" ]; then
		f_log "info" "travelmate is currently disabled, please set 'trm_enabled' to '1' to use this service"
		/etc/init.d/travelmate stop
	elif [ -z "${trm_iface}" ]; then
		f_log "info" "travelmate is currently not configured, please use the 'Interface Setup' in LuCI or the 'setup' option in CLI"
		/etc/init.d/travelmate stop
	elif ! ubus -t "${trm_maxwait}" wait_for network.wireless network.interface."${trm_iface}" >/dev/null 2>&1; then
		f_log "info" "travelmate interface '${trm_iface}' does not appear on ubus, please check your network setup"
		/etc/init.d/travelmate stop
	fi

	wpa_checks="sae owe eap suiteb192"
	for check in ${wpa_checks}; do
		if [ -x "${trm_wpa}" ]; then
			if "${trm_wpa}" -v"${check}" >/dev/null 2>&1; then
				result="$(f_trim "${result} ${check}: $(f_char 1)")"
			else
				result="$(f_trim "${result} ${check}: $(f_char 0)")"
			fi
		fi
	done
	trm_wpaflags="$(printf "%s" "${result}" | awk '{printf "%s %s, %s %s, %s %s, %s %s",$1,$2,$3,$4,$5,$6,$7,$8}')"

	config_load wireless
	config_foreach f_setdev "wifi-device"
	if [ -n "$(uci -q changes "wireless")" ]; then
		uci_commit "wireless"
		f_wifi
	fi

	json_load_file "${trm_rtfile}" >/dev/null 2>&1

	if ! json_select data >/dev/null 2>&1; then
		: >"${trm_rtfile}"
		json_init
		json_add_object "data"
	fi
	f_log "debug" "f_env    ::: auto_sta: ${trm_opensta:-"-"}, wpa_flags: ${trm_wpaflags}, sys_ver: ${trm_sysver}"
}

# trim helper function
#
f_trim() {
	local trim="${1}"

	trim="${trim#"${trim%%[![:space:]]*}"}"
	trim="${trim%"${trim##*[![:space:]]}"}"
	printf "%s" "${trim}"
}

# status helper function
#
f_char() {
	local result input="${1}"

	if [ "${input}" = "1" ]; then
		result="✔"
	else
		result="✘"
	fi
	printf "%s" "${result}"
}

# wifi helper function
#
f_wifi() {
	local status radio radio_up timeout="0"

	"${trm_wifi}" reload
	for radio in ${trm_radiolist}; do
		while true; do
			if [ "${timeout}" -ge "${trm_maxwait}" ]; then
				break 2
			fi
			status="$("${trm_wifi}" status 2>/dev/null)"
			if [ "$(printf "%s" "${status}" | jsonfilter -q -l1 -e "@.${radio}.up")" != "true" ] ||
				[ "$(printf "%s" "${status}" | jsonfilter -q -l1 -e "@.${radio}.pending")" != "false" ]; then
				if [ "${radio}" != "${radio_up}" ]; then
					"${trm_wifi}" up "${radio}"
					radio_up="${radio}"
				fi
				timeout="$((timeout + 1))"
				sleep 1
			else
				continue 2
			fi
		done
	done
	if [ "${timeout}" -lt "${trm_maxwait}" ]; then
		sleep "$((trm_maxwait / 6))"
		timeout="$((timeout + (trm_maxwait / 6)))"
	fi
	f_log "debug" "f_wifi   ::: radio_list: ${trm_radiolist}, radio: ${radio}, timeout: ${timeout}"
}

# vpn helper function
#
f_vpn() {
	local rc vpn vpn_service vpn_iface vpn_action="${1}"

	vpn="$(f_getval "vpn")"
	vpn_service="$(f_getval "vpnservice")"
	vpn_iface="$(f_getval "vpniface")"

	if [ -x "${trm_vpnpgm}" ] && [ -n "${vpn}" ] && [ -n "${vpn_service}" ] && [ -n "${vpn_iface}" ] && [ -f "${trm_ntpfile}" ]; then
		if { [ "${vpn_action}" = "disable" ] && [ -f "${trm_vpnfile}" ]; } ||
			{ [ "${vpn}" = "1" ] && [ "${vpn_action}" = "enable" ] && [ ! -f "${trm_vpnfile}" ]; } ||
			{ [ "${vpn}" != "1" ] && [ "${vpn_action}" = "enable" ] && [ -f "${trm_vpnfile}" ]; }; then
			"${trm_vpnpgm}" "${vpn}" "${vpn_action}" "${vpn_service}" "${vpn_iface}" >/dev/null 2>&1
			rc="${?}"
		fi
		if [ "${vpn}" = "1" ] && [ "${vpn_action}" = "enable" ] && [ "${rc}" = "0" ]; then
			: >"${trm_vpnfile}"
		elif { [ "${vpn}" != "1" ] || [ "${vpn_action}" = "disable" ]; } && [ -f "${trm_vpnfile}" ]; then
			rm -f "${trm_vpnfile}"
		fi
		[ -n "${rc}" ] && f_jsnup
	fi
	f_log "debug" "f_vpn    ::: enabled: ${vpn:-"-"}, action: ${vpn_action}, service: ${vpn_service:-"-"}, iface: ${vpn_iface:-"-"}, rc: ${rc:-"-"}, program: ${trm_vpnpgm}"
}

# mac helper function
#
f_mac() {
	local result ifname macaddr action="${1}" section="${2}"

	if [ "${action}" = "set" ]; then
		macaddr="$(f_getval "macaddr")"
		if [ -n "${macaddr}" ]; then
			result="${macaddr}"
			uci_set "wireless" "${section}" "macaddr" "${result}"
		elif [ "${trm_randomize}" = "1" ]; then
			result="$(hexdump -n6 -ve '/1 "%.02X "' /dev/random 2>/dev/null |
				awk -v local="2,6,A,E" -v seed="$(date +%s)" 'BEGIN{srand(seed)}NR==1{split(local,b,",");
				seed=int(rand()*4+1);printf "%s%s:%s:%s:%s:%s:%s",substr($1,0,1),b[seed],$2,$3,$4,$5,$6}')"
			uci_set "wireless" "${section}" "macaddr" "${result}"
		else
			uci_remove "wireless" "${section}" "macaddr" 2>/dev/null
			ifname="$(ubus -S call network.wireless status 2>/dev/null | jsonfilter -q -l1 -e '@.*.interfaces[@.config.mode="sta"].ifname')"
			result="$(${trm_iwinfo} "${ifname}" info 2>/dev/null | awk '/Access Point:/{printf "%s",$3}')"
		fi
	elif [ "${action}" = "get" ]; then
		result="$(uci_get "wireless" "${section}" "macaddr")"
		if [ -z "${result}" ]; then
			ifname="$(ubus -S call network.wireless status 2>/dev/null | jsonfilter -q -l1 -e '@.*.interfaces[@.config.mode="sta"].ifname')"
			result="$(${trm_iwinfo} "${ifname}" info 2>/dev/null | awk '/Access Point:/{printf "%s",$3}')"
		fi
	fi
	printf "%s" "${result}"
	f_log "debug" "f_mac    ::: action: ${action:-"-"}, section: ${section:-"-"}, macaddr: ${macaddr:-"-"}, result: ${result:-"-"}"
}

# set connection information
#
f_ctrack() {
	local expiry action="${1}"

	if [ -n "${trm_uplinkcfg}" ]; then
		case "${action}" in
			"start")
				uci_remove "travelmate" "${trm_uplinkcfg}" "con_start" 2>/dev/null
				uci_remove "travelmate" "${trm_uplinkcfg}" "con_end" 2>/dev/null
				if [ -f "${trm_ntpfile}" ]; then
					uci_set "travelmate" "${trm_uplinkcfg}" "con_start" "$(date "+%Y.%m.%d-%H:%M:%S")"
				fi
				;;
			"refresh")
				if [ -f "${trm_ntpfile}" ] && [ -z "$(uci_get "travelmate" "${trm_uplinkcfg}" "con_start")" ]; then
					uci_set "travelmate" "${trm_uplinkcfg}" "con_start" "$(date "+%Y.%m.%d-%H:%M:%S")"
				fi
				;;
			"end")
				if [ -f "${trm_ntpfile}" ]; then
					uci_set "travelmate" "${trm_uplinkcfg}" "con_end" "$(date "+%Y.%m.%d-%H:%M:%S")"
				fi
				;;
			"start_expiry")
				if [ -f "${trm_ntpfile}" ]; then
					expiry="$(uci_get "travelmate" "${trm_uplinkcfg}" "con_start_expiry")"
					uci_set "travelmate" "${trm_uplinkcfg}" "enabled" "0"
					uci_set "travelmate" "${trm_uplinkcfg}" "con_end" "$(date "+%Y.%m.%d-%H:%M:%S")"
					f_log "info" "uplink '${radio}/${essid}/${bssid:-"-"}' expired after ${expiry} minutes"
				fi
				;;
			"end_expiry")
				if [ -f "${trm_ntpfile}" ]; then
					expiry="$(uci_get "travelmate" "${trm_uplinkcfg}" "con_end_expiry")"
					uci_set "travelmate" "${trm_uplinkcfg}" "enabled" "1"
					uci_remove "travelmate" "${trm_uplinkcfg}" "con_start" 2>/dev/null
					uci_remove "travelmate" "${trm_uplinkcfg}" "con_end" 2>/dev/null
					f_log "info" "uplink '${radio}/${essid}/${bssid:-"-"}' re-enabled after ${expiry} minutes"
				fi
				;;
			"disabled")
				uci_set "travelmate" "${trm_uplinkcfg}" "enabled" "0"
				if [ -f "${trm_ntpfile}" ]; then
					uci_set "travelmate" "${trm_uplinkcfg}" "con_end" "$(date "+%Y.%m.%d-%H:%M:%S")"
				fi
				;;
		esac
		if [ -n "$(uci -q changes "travelmate")" ]; then
			uci_commit "travelmate"
			if [ ! -f "${trm_refreshfile}" ]; then
				printf "%s" "cfg_reload" >"${trm_refreshfile}"
			fi
		fi
	fi
	f_log "debug" "f_ctrack ::: action: ${action:-"-"}, uplink_config: ${trm_uplinkcfg:-"-"}"
}

# get wan gateway addresses
#
f_getgw() {
	local result wan4_if wan4_gw wan6_if wan6_gw

	network_flush_cache
	network_find_wan wan4_if
	network_find_wan6 wan6_if
	network_get_gateway wan4_gw "${wan4_if}"
	network_get_gateway6 wan6_gw "${wan6_if}"
	if [ -n "${wan4_gw}" ] || [ -n "${wan6_gw}" ]; then
		result="${wan4_gw} ${wan6_gw}"
	fi
	printf "%s" "${result}"
	f_log "debug" "f_getgw  ::: wan4_gw: ${wan4_gw:-"-"}, wan6_gw: ${wan6_gw:-"-"}, result: ${result:-"-"}"
}

# get uplink config section
#
f_getcfg() {
	local t_radio t_essid t_bssid radio="${1}" essid="${2}" bssid="${3}" cnt="0"

	while uci_get "travelmate" "@uplink[${cnt}]" >/dev/null 2>&1; do
		t_radio="$(uci_get "travelmate" "@uplink[${cnt}]" "device")"
		t_essid="$(uci_get "travelmate" "@uplink[${cnt}]" "ssid")"
		t_bssid="$(uci_get "travelmate" "@uplink[${cnt}]" "bssid")"
		if [ -n "${radio}" ] && [ -n "${essid}" ] &&
			[ "${t_radio}" = "${radio}" ] && [ "${t_essid}" = "${essid}" ] && [ "${t_bssid}" = "${bssid}" ]; then
			trm_uplinkcfg="@uplink[${cnt}]"
			break
		fi
		cnt="$((cnt + 1))"
	done
	f_log "debug" "f_getcfg ::: status: ${status}, section: ${section}, uplink_config: ${trm_uplinkcfg:-"-"}"
}

# get travelmate option value in 'uplink' sections
#
f_getval() {
	local result t_option="${1}"

	if [ -n "${trm_uplinkcfg}" ]; then
		result="$(uci_get "travelmate" "${trm_uplinkcfg}" "${t_option}")"
		printf "%s" "${result}"
	fi
	f_log "debug" "f_getval ::: option: ${t_option:-"-"}, result: ${result:-"-"}, uplink_config: ${trm_uplinkcfg:-"-"}"
}

# set 'wifi-device' sections
#
f_setdev() {
	local disabled radio="${1}"

	disabled="$(uci_get "wireless" "${radio}" "disabled")"
	if [ "${disabled}" = "1" ]; then
		uci_set wireless "${radio}" "disabled" "0"
	fi
	if [ -n "${trm_radio}" ] && [ -z "${trm_radiolist}" ]; then
		trm_radiolist="${trm_radio}"
	elif [ -z "${trm_radio}" ] && ! printf "%s" "${trm_radiolist}" | grep -q "${radio}"; then
		trm_radiolist="$(f_trim "${trm_radiolist} ${radio}")"
	fi
	f_log "debug" "f_setdev ::: radio: ${radio:-"-"}, radio_list(cnf/cur): ${trm_radio:-"-"}/${trm_radiolist:-"-"}, disabled: ${disabled:-"-"}"
}

# set 'wifi-iface' sections
#
f_setif() {
	local mode radio essid bssid enabled disabled con_start con_end con_start_expiry con_end_expiry section="${1}" proactive="${2}"

	mode="$(uci_get "wireless" "${section}" "mode")"
	radio="$(uci_get "wireless" "${section}" "device")"
	essid="$(uci_get "wireless" "${section}" "ssid")"
	bssid="$(uci_get "wireless" "${section}" "bssid")"
	disabled="$(uci_get "wireless" "${section}" "disabled")"

	f_getcfg "${radio}" "${essid}" "${bssid}"

	enabled="$(f_getval "enabled")"
	con_start="$(f_getval "con_start")"
	con_end="$(f_getval "con_end")"
	con_start_expiry="$(f_getval "con_start_expiry")"
	con_end_expiry="$(f_getval "con_end_expiry")"

	if [ "${enabled}" = "0" ] && [ -n "${con_end}" ] && [ -n "${con_end_expiry}" ] && [ "${con_end_expiry}" != "0" ]; then
		d1="$(date -d "${con_end}" "+%s")"
		d2="$(date "+%s")"
		d3="$(((d2 - d1) / 60))"
		if [ "${d3}" -ge "${con_end_expiry}" ]; then
			enabled="1"
			f_ctrack "end_expiry"
		fi
	elif [ "${enabled}" = "1" ] && [ -n "${con_start}" ] && [ -n "${con_start_expiry}" ] && [ "${con_start_expiry}" != "0" ]; then
		d1="$(date -d "${con_start}" "+%s")"
		d2="$(date "+%s")"
		d3="$((d1 + (con_start_expiry * 60)))"
		if [ "${d2}" -gt "${d3}" ]; then
			enabled="0"
			f_ctrack "start_expiry"
		fi
	fi

	if [ "${mode}" = "sta" ]; then
		if [ "${enabled}" = "0" ] || { { [ -z "${disabled}" ] || [ "${disabled}" = "0" ]; } &&
			{ [ "${proactive}" = "0" ] || [ "${trm_ifstatus}" != "true" ]; }; }; then
			uci_set "wireless" "${section}" "disabled" "1"
		elif [ "${enabled}" = "1" ] && [ "${disabled}" = "0" ] && [ "${trm_ifstatus}" = "true" ] && [ "${proactive}" = "1" ]; then
			if [ -z "${trm_activesta}" ]; then
				trm_activesta="${section}"
			else
				uci_set "wireless" "${section}" "disabled" "1"
			fi
		fi
		if [ "${enabled}" = "1" ]; then
			trm_stalist="$(f_trim "${trm_stalist} ${section}-${radio}")"
		fi
	fi
	f_log "debug" "f_setif  ::: enabled: ${enabled}, section: ${section}, active_sta: ${trm_activesta:-"-"}, uplink_config: ${trm_uplinkcfg:-"-"}"
}

# add open uplinks
#
f_addsta() {
	local uci_cfg new_uplink="1" offset="1" radio="${1}" essid="${2}"

	if [ "${trm_maxautoadd}" = "0" ] || [ "${trm_opensta:-0}" -lt "${trm_maxautoadd}" ]; then
		config_cb() {
			local type="${1}" name="${2}"

			if [ "${type}" = "wifi-iface" ]; then
				if [ "$(uci_get "wireless.${name}.ssid")" = "${essid}" ] &&
					[ "$(uci_get "wireless.${name}.device")" = "${radio}" ]; then
					new_uplink="0"
					return 0
				fi
				offset="$((offset + 1))"
			fi
		}
		config_load wireless
	else
		new_uplink="0"
	fi

	if [ "${new_uplink}" = "1" ]; then
		uci_cfg="trm_uplink$((offset + 1))"
		while [ -n "$(uci_get "wireless.${uci_cfg}")" ]; do
			offset="$((offset + 1))"
			uci_cfg="trm_uplink${offset}"
		done
		uci -q batch <<-EOC
			set wireless."${uci_cfg}"="wifi-iface"
			set wireless."${uci_cfg}".mode="sta"
			set wireless."${uci_cfg}".network="${trm_iface}"
			set wireless."${uci_cfg}".device="${radio}"
			set wireless."${uci_cfg}".ssid="${essid}"
			set wireless."${uci_cfg}".encryption="none"
			set wireless."${uci_cfg}".disabled="1"
		EOC
		uci_cfg="$(uci -q add travelmate uplink)"
		uci -q batch <<-EOC
			set travelmate."${uci_cfg}".device="${radio}"
			set travelmate."${uci_cfg}".ssid="${essid}"
			set travelmate."${uci_cfg}".opensta="1"
			set travelmate."${uci_cfg}".con_start_expiry="0"
			set travelmate."${uci_cfg}".con_end_expiry="0"
			set travelmate."${uci_cfg}".enabled="1"
		EOC
		if [ -n "$(uci -q changes "travelmate")" ] || [ -n "$(uci -q changes "wireless")" ]; then
			trm_opensta="$((trm_opensta + 1))"
			uci_commit "travelmate"
			uci_commit "wireless"
			f_wifi
			if [ ! -f "${trm_refreshfile}" ]; then
				printf "%s" "ui_reload" >"${trm_refreshfile}"
			fi
			f_log "info" "open uplink '${radio}/${essid}' added to wireless config"
		fi
	fi
	f_log "debug" "f_addsta ::: radio: ${radio:-"-"}, essid: ${essid}, opensta/maxautoadd: ${trm_opensta:-"-"}/${trm_maxautoadd:-"-"}, new_uplink: ${new_uplink}, offset: ${offset}"
}

# check net status
#
f_net() {
	local err_msg raw html_raw html_cp json_raw json_ec json_rc json_cp json_ed result="net nok"

	raw="$(${trm_fetch} --user-agent "${trm_useragent}" --referer "http://www.example.com" --header "Cache-Control: no-cache, no-store, must-revalidate, max-age=0" --write-out "%{json}" --silent --max-time $((trm_maxwait / 6)) "${trm_captiveurl}")"
	json_raw="${raw#*\{}"
	html_raw="${raw%%\{*}"
	if [ -n "${json_raw}" ]; then
		json_ec="$(printf "%s" "{${json_raw}" | jsonfilter -q -l1 -e '@.exitcode')"
		json_rc="$(printf "%s" "{${json_raw}" | jsonfilter -q -l1 -e '@.response_code')"
		json_cp="$(printf "%s" "{${json_raw}" | jsonfilter -q -l1 -e '@.redirect_url' | awk 'BEGIN{FS="/"}{printf "%s",tolower($3)}')"
		if [ "${json_ec}" = "0" ]; then
			if [ -n "${json_cp}" ]; then
				result="net cp '${json_cp}'"
			else
				if [ "${json_rc}" = "200" ] || [ "${json_rc}" = "204" ]; then
					html_cp="$(printf "%s" "${html_raw}" | awk 'match(tolower($0),/^.*<meta[ \t]+http-equiv=['\''"]*refresh.*[ \t;]url=/){print substr(tolower($0),RLENGTH+1)}' | awk 'BEGIN{FS="[:/]"}{printf "%s",$4;exit}')"
					if [ -n "${html_cp}" ]; then
						result="net cp '${html_cp}'"
					else
						result="net ok"
					fi
				fi
			fi
		else
			err_msg="$(printf "%s" "{${json_raw}" | jsonfilter -q -l1 -e '@.errormsg')"
			json_ed="$(printf "%s" "{${err_msg}" | awk '/([[:alnum:]_-]{1,63}\.)+[[:alpha:]]+$/{printf "%s",tolower($NF)}')"
			if [ "${json_ec}" = "6" ]; then
				if [ -n "${json_ed}" ] && [ "${json_ed}" != "${trm_captiveurl#http*://*}" ]; then
					result="net cp '${json_ed}'"
				fi
			elif [ "${json_ec}" = "28" ]; then
				if [ -n "$(f_getgw)" ]; then
					result="net ok"
				fi
			fi
		fi
	fi
	printf "%s" "${result}"
	f_log "debug" "f_net    ::: fetch: ${trm_fetch}, timeout: $((trm_maxwait / 6)), cp (json/html): ${json_cp:-"-"}/${html_cp:-"-"}, result: ${result}, error (rc/msg): ${json_ec}/${err_msg:-"-"}, url: ${trm_captiveurl}, user_agent: ${trm_useragent}"
}

# check interface status
#
f_check() {
	local ifname radio dev_status result login_script login_script_args cp_domain wait_time="1" enabled="1" mode="${1}" status="${2}" sta_radio="${3}" sta_essid="${4}" sta_bssid="${5}"

	if [ "${mode}" = "initial" ] || [ "${mode}" = "dev" ]; then
		json_get_var station_id "station_id"
		sta_radio="${station_id%%/*}"
		sta_essid="${station_id%/*}"
		sta_essid="${sta_essid#*/}"
		sta_bssid="${station_id##*/}"
		sta_bssid="${sta_bssid//-/}"
	fi
	f_getcfg "${sta_radio}" "${sta_essid}" "${sta_bssid}"

	if [ "${mode}" != "rev" ] && [ -n "${sta_radio}" ] && [ "${sta_radio}" != "-" ] && [ -n "${sta_essid}" ] && [ "${sta_essid}" != "-" ]; then
		enabled="$(f_getval "enabled")"
	fi
	if { [ "${mode}" != "initial" ] && [ "${mode}" != "dev" ] && [ "${status}" = "false" ]; } ||
		{ [ "${mode}" = "dev" ] && { [ "${status}" = "false" ] || { [ "${trm_ifstatus}" != "${status}" ] && [ "${enabled}" = "0" ]; }; }; }; then
		f_wifi
	fi
	while [ "${wait_time}" -le "${trm_maxwait}" ]; do
		dev_status="$(ubus -S call network.wireless status 2>/dev/null)"
		if [ -n "${dev_status}" ]; then
			if [ "${mode}" = "dev" ]; then
				if [ "${trm_ifstatus}" != "${status}" ]; then
					trm_ifstatus="${status}"
					f_jsnup
				fi
				if [ "${status}" = "false" ]; then
					sleep "$((trm_maxwait / 5))"
				fi
				break
			elif [ "${mode}" = "rev" ]; then
				unset trm_connection
				trm_ifstatus="${status}"
				break
			else
				ifname="$(printf "%s" "${dev_status}" | jsonfilter -q -l1 -e '@.*.interfaces[@.config.mode="sta"].ifname')"
				if [ -n "${ifname}" ] && [ "${enabled}" = "1" ]; then
					trm_ifquality="$(${trm_iwinfo} "${ifname}" info 2>/dev/null | awk -F '[ ]' '/Link Quality:/{split($NF,var0,"/");printf "%i\n",(var0[1]*100/var0[2])}')"
					if [ "${trm_ifquality}" -ge "${trm_minquality}" ]; then
						trm_ifstatus="$(ubus -S call network.interface dump 2>/dev/null | jsonfilter -q -l1 -e "@.interface[@.device=\"${ifname}\"].up")"
						if [ "${trm_ifstatus}" = "true" ]; then
							result="$(f_net)"
							if [ "${trm_captive}" = "1" ]; then
								while true; do
									cp_domain="$(printf "%s" "${result}" | awk -F '['\''| ]' '/^net cp/{printf "%s",$4}')"
									if [ -x "/etc/init.d/dnsmasq" ] && [ -f "/etc/config/dhcp" ] &&
										[ -n "${cp_domain}" ] && ! uci_get "dhcp" "@dnsmasq[0]" "rebind_domain" | grep -q "${cp_domain}"; then
										uci_add_list "dhcp" "@dnsmasq[0]" "rebind_domain" "${cp_domain}"
										uci_commit "dhcp"
										/etc/init.d/dnsmasq reload
										f_log "info" "captive portal domain '${cp_domain}' added to to dhcp rebind whitelist"
									else 
										break
									fi
									result="$(f_net)"
								done
								if [ -n "${cp_domain}" ]; then
									trm_connection="${result:-"-"}/${trm_ifquality}"
									f_jsnup
									login_script="$(f_getval "script")"
									if [ -x "${login_script}" ]; then
										login_script_args="$(f_getval "script_args")"
										"${login_script}" ${login_script_args} >/dev/null 2>&1
										rc="${?}"
										if [ "${rc}" = "255" ]; then
											f_log "info" "captive portal login script for '${cp_domain}' failed with rc '${rc}'"
											unset trm_connection
											trm_ifstatus="${status}"
											f_jsnup
											break
										else
											f_log "info" "captive portal login script for '${cp_domain}' has been finished  with rc '${rc}'"
											if [ "${rc}" = "0" ]; then
												result="$(f_net)"
											fi
										fi
									fi
								fi
							fi
							if [ "${trm_netcheck}" = "1" ] && [ "${result}" = "net nok" ]; then
								f_log "info" "uplink has no internet"
								f_vpn "disable"
								trm_ifstatus="${status}"
								f_jsnup
								break
							fi
							trm_connection="${result:-"-"}/${trm_ifquality}"
							f_jsnup
							break
						fi
					elif [ -n "${trm_connection}" ] && { [ "${trm_netcheck}" = "1" ] || [ "${mode}" = "initial" ]; }; then
						f_log "info" "uplink is out of range (${trm_ifquality}/${trm_minquality})"
						f_vpn "disable"
						unset trm_connection
						trm_ifstatus="${status}"
						f_ctrack "end"
						f_jsnup
						break
					elif [ "${mode}" = "initial" ] || [ "${mode}" = "sta" ]; then
						unset trm_connection
						trm_ifstatus="${status}"
						f_jsnup
						break
					fi
				elif [ -n "${trm_connection}" ]; then
					f_vpn "disable"
					unset trm_connection
					trm_ifstatus="${status}"
					f_jsnup
					break
				elif [ "${mode}" = "initial" ]; then
					trm_ifstatus="${status}"
					f_jsnup
					break
				fi
			fi
		fi
		if [ "${mode}" = "initial" ]; then
			trm_ifstatus="${status}"
			f_jsnup
			break
		fi
		wait_time="$((wait_time + 1))"
		sleep 1
	done
	f_log "debug" "f_check  ::: mode: ${mode}, name: ${ifname:-"-"}, status: ${trm_ifstatus}, enabled: ${enabled}, connection: ${trm_connection:-"-"}, wait: ${wait_time}, max_wait: ${trm_maxwait}, min_quality: ${trm_minquality}, captive: ${trm_captive}, netcheck: ${trm_netcheck}"
}

# update runtime information
#
f_jsnup() {
	local vpn section last_date last_station sta_iface sta_radio sta_essid sta_bssid sta_mac dev_status last_status status="${trm_ifstatus}" ntp_done="0" vpn_done="0" mail_done="0"

	if [ "${status}" = "true" ]; then
		status="connected (${trm_connection:-"-"})"
		dev_status="$(ubus -S call network.wireless status 2>/dev/null)"
		section="$(printf "%s" "${dev_status}" | jsonfilter -q -l1 -e '@.*.interfaces[@.config.mode="sta"].section')"
		if [ -n "${section}" ]; then
			sta_iface="$(uci_get "wireless" "${section}" "network")"
			sta_radio="$(uci_get "wireless" "${section}" "device")"
			sta_essid="$(uci_get "wireless" "${section}" "ssid")"
			sta_bssid="$(uci_get "wireless" "${section}" "bssid")"
			sta_mac="$(f_mac "get" "${section}")"
			f_getcfg "${sta_radio}" "${sta_essid}" "${sta_bssid}"
			vpn="$(f_getval "vpn")"
		fi
		json_get_var last_date "last_run"
		json_get_var last_station "station_id"
		json_get_var last_status "travelmate_status"

		if { [ -f "${trm_ntpfile}" ] && [ ! -s "${trm_ntpfile}" ]; } || [ "${last_status}" = "running (not connected)" ] ||
			{ [ -n "${last_station}" ] && [ "${last_station}" != "${sta_radio:-"-"}/${sta_essid:-"-"}/${sta_bssid:-"-"}" ]; }; then
			last_date="$(date "+%Y.%m.%d-%H:%M:%S")"
			if [ -f "${trm_ntpfile}" ] && [ ! -s "${trm_ntpfile}" ]; then
				printf "%s" "${last_date}" >"${trm_ntpfile}"
			fi
		fi
	elif [ "${status}" = "error" ]; then
		unset trm_connection
		status="program error"
	else
		unset trm_connection
		status="running (not connected)"
	fi
	if [ -z "${last_date}" ]; then
		last_date="$(date "+%Y.%m.%d-%H:%M:%S")"
	fi
	if [ -s "${trm_ntpfile}" ]; then
		ntp_done="1"
	fi
	if [ "${vpn}" = "1" ] && [ -f "${trm_vpnfile}" ]; then
		vpn_done="1"
	fi
	if [ "${trm_mail}" = "1" ] && [ -f "${trm_mailfile}" ]; then
		mail_done="1"
	fi
	json_add_string "travelmate_status" "${status}"
	json_add_string "travelmate_version" "${trm_ver}"
	json_add_string "station_id" "${sta_radio:-"-"}/${sta_essid:-"-"}/${sta_bssid:-"-"}"
	json_add_string "station_mac" "${sta_mac:-"-"}"
	json_add_string "station_interface" "${sta_iface:-"-"}"
	json_add_string "wpa_flags" "${trm_wpaflags:-"-"}"
	json_add_string "run_flags" "captive: $(f_char ${trm_captive}), proactive: $(f_char ${trm_proactive}), netcheck: $(f_char ${trm_netcheck}), autoadd: $(f_char ${trm_autoadd}), randomize: $(f_char ${trm_randomize})"
	json_add_string "ext_hooks" "ntp: $(f_char ${ntp_done}), vpn: $(f_char ${vpn_done}), mail: $(f_char ${mail_done})"
	json_add_string "last_run" "${last_date}"
	json_add_string "system" "${trm_sysver}"
	json_dump >"${trm_rtfile}"

	if [ "${status%% (net ok/*}" = "connected" ] && [ "${trm_mail}" = "1" ] && [ -x "${trm_mailpgm}" ] && [ "${ntp_done}" = "1" ] && [ "${mail_done}" = "0" ]; then
		if [ "${vpn}" != "1" ] || [ "${vpn_done}" = "1" ]; then
			: >"${trm_mailfile}"
			"${trm_mailpgm}" >/dev/null 2>&1
		fi
	fi
	f_log "debug" "f_jsnup  ::: section: ${section:-"-"}, status: ${status:-"-"}, sta_iface: ${sta_iface:-"-"}, sta_radio: ${sta_radio:-"-"}, sta_essid: ${sta_essid:-"-"}, sta_bssid: ${sta_bssid:-"-"}, ntp: ${ntp_done}, vpn: ${vpn:-"0"}/${vpn_done}, mail: ${trm_mail}/${mail_done}"
}

# write to syslog
#
f_log() {
	local class="${1}" log_msg="${2}"

	if [ -n "${log_msg}" ] && { [ "${class}" != "debug" ] || [ "${trm_debug}" = "1" ]; }; then
		if [ -x "${trm_logger}" ]; then
			"${trm_logger}" -p "${class}" -t "trm-${trm_ver}[${$}]" "${log_msg}"
		else
			printf "%s %s %s\n" "${class}" "trm-${trm_ver}[${$}]" "${log_msg}"
		fi
		if [ "${class}" = "err" ]; then
			trm_ifstatus="error"
			f_jsnup
			: >"${trm_pidfile}"
			exit 1
		fi
	fi
}

# main function for connection handling
#
f_main() {
	local radio cnt retrycnt scan_dev scan_list scan_essid scan_bssid scan_open scan_quality
	local station_id section sta sta_essid sta_bssid sta_radio sta_mac config_essid config_bssid config_radio

	f_check "initial" "false"
	f_log "debug" "f_main-1 ::: status: ${trm_ifstatus}, proactive: ${trm_proactive}"
	if [ "${trm_ifstatus}" != "true" ] || [ "${trm_proactive}" = "1" ]; then
		config_load wireless
		config_foreach f_setif wifi-iface "${trm_proactive}"
		if [ "${trm_ifstatus}" = "true" ] && [ -n "${trm_activesta}" ] && [ "${trm_proactive}" = "1" ]; then
			json_get_var station_id "station_id"
			config_radio="${station_id%%/*}"
			config_essid="${station_id%/*}"
			config_essid="${config_essid#*/}"
			config_bssid="${station_id##*/}"
			config_bssid="${config_bssid//-/}"
			f_check "dev" "true"
			f_log "debug" "f_main-2 ::: config_radio: ${config_radio}, config_essid: \"${config_essid}\", config_bssid: ${config_bssid:-"-"}"
		else
			uci_commit "wireless"
			f_check "dev" "false"
		fi
		f_log "debug" "f_main-3 ::: radio_list: ${trm_radiolist:-"-"}, sta_list: ${trm_stalist:-"-"}"

		# radio loop
		#
		for radio in ${trm_radiolist}; do
			if ! printf "%s" "${trm_stalist}" | grep -q "\\-${radio}"; then
				if [ "${trm_autoadd}" = "0" ]; then
					f_log "info" "no enabled station on radio '${radio}'"
					continue
				fi
			fi
			scan_list=""

			# station loop
			#
			for sta in ${trm_stalist:-"${radio}"}; do
				if [ "${sta}" != "${radio}" ]; then
					section="${sta%%-*}"
					sta_radio="$(uci_get "wireless" "${section}" "device")"
					sta_essid="$(uci_get "wireless" "${section}" "ssid")"
					sta_bssid="$(uci_get "wireless" "${section}" "bssid")"
					sta_mac="$(f_mac "get" "${section}")"
					if [ -z "${sta_radio}" ] || [ -z "${sta_essid}" ]; then
						f_log "info" "invalid wireless section '${section}'"
						continue
					fi
					if [ -n "${trm_connection}" ] && [ "${radio}" = "${config_radio}" ] && [ "${sta_radio}" = "${config_radio}" ] &&
						[ "${sta_essid}" = "${config_essid}" ] && [ "${sta_bssid}" = "${config_bssid}" ]; then
						f_ctrack "refresh"
						f_log "info" "uplink still in range '${config_radio}/${config_essid}/${config_bssid:-"-"}' with mac '${sta_mac:-"-"}'"
						f_vpn "enable"
						return 0
					fi
					f_log "debug" "f_main-4 ::: sta_radio: ${sta_radio}, sta_essid: \"${sta_essid}\", sta_bssid: ${sta_bssid:-"-"}"
				fi
				if [ -z "${scan_list}" ]; then
					scan_dev="$(ubus -S call network.wireless status 2>/dev/null | jsonfilter -q -l1 -e "@.${radio}.interfaces[0].ifname")"
					scan_list="$("${trm_iwinfo}" "${scan_dev:-${radio}}" scan 2>/dev/null |
						awk 'BEGIN{FS="[[:space:]]"}/Address:/{var1=$NF}/ESSID:/{var2="";for(i=12;i<=NF;i++)if(var2==""){var2=$i}else{var2=var2" "$i}}
						/Quality:/{split($NF,var0,"/")}/Encryption:/{if($NF=="none"){var3="+"}else{var3="-"};
						printf "%i %s %s %s\n",(var0[1]*100/var0[2]),var3,var1,var2}' | sort -rn | head -qn "${trm_maxscan}")"
					f_log "debug" "f_main-5 ::: radio: ${radio}, scan_device: ${scan_dev}, scan_max: ${trm_maxscan}"
					if [ -z "${scan_list}" ]; then
						f_log "info" "no scan results on '${radio}'"
						continue 2
					fi
				fi

				# scan loop
				#
				while read -r scan_quality scan_open scan_bssid scan_essid; do
					if [ -n "${scan_quality}" ] && [ -n "${scan_open}" ] && [ -n "${scan_bssid}" ] && [ -n "${scan_essid}" ]; then
						f_log "debug" "f_main-6 ::: radio(sta/scan): ${sta_radio}/${radio}, essid(sta/scan): \"${sta_essid}\"/${scan_essid}, bssid(sta/scan): ${sta_bssid}/${scan_bssid}, quality(min/scan): ${trm_minquality}/${scan_quality}, open: ${scan_open}"
						if [ "${scan_quality}" -ge "${trm_minquality}" ]; then
							if { { [ "${scan_essid}" = "\"${sta_essid}\"" ] && { [ -z "${sta_bssid}" ] || [ "${scan_bssid}" = "${sta_bssid}" ]; }; } ||
								{ [ "${scan_bssid}" = "${sta_bssid}" ] && [ "${scan_essid}" = "unknown" ]; }; } && [ "${radio}" = "${sta_radio}" ]; then
								if [ -n "${config_radio}" ]; then
									f_vpn "disable"
									uci_set "wireless" "${trm_activesta}" "disabled" "1"
									uci_commit "wireless"
									f_check "rev" "false"
									f_ctrack "end"
									f_log "info" "uplink connection terminated '${config_radio}/${config_essid}/${config_bssid:-"-"}'"
									unset config_radio config_essid config_bssid
								fi

								# retry loop
								#
								retrycnt="1"
								f_getcfg "${sta_radio}" "${sta_essid}" "${sta_bssid}"
								while [ "${retrycnt}" -le "${trm_maxretry}" ]; do
									sta_mac="$(f_mac "set" "${section}")"
									uci_set "wireless" "${section}" "disabled" "0"
									f_check "sta" "false" "${sta_radio}" "${sta_essid}" "${sta_bssid}"
									if [ "${trm_ifstatus}" = "true" ]; then
										rm -f "${trm_mailfile}"
										uci_commit "wireless"
										f_ctrack "start"
										f_log "info" "connected to uplink '${sta_radio}/${sta_essid}/${sta_bssid:-"-"}' with mac '${sta_mac:-"-"}' (${retrycnt}/${trm_maxretry})"
										f_vpn "enable"
										return 0
									else
										uci -q revert "wireless"
										f_check "rev" "false"
										if [ "${retrycnt}" = "${trm_maxretry}" ]; then
											f_ctrack "disabled"
											f_log "info" "uplink has been disabled '${sta_radio}/${sta_essid}/${sta_bssid:-"-"}' (${retrycnt}/${trm_maxretry})"
											break 2
										else
											f_jsnup
											f_log "info" "can't connect to uplink '${sta_radio}/${sta_essid}/${sta_bssid:-"-"}' (${retrycnt}/${trm_maxretry})"
										fi
									fi
									retrycnt="$((retrycnt + 1))"
									sleep "$((trm_maxwait / 6))"
								done
							elif [ "${trm_autoadd}" = "1" ] && [ "${scan_open}" = "+" ] && [ "${scan_essid}" != "unknown" ]; then
								scan_essid="${scan_essid%?}"
								scan_essid="${scan_essid:1}"
								f_addsta "${radio}" "${scan_essid}"
							fi
						fi
					fi
				done <<-EOV
					${scan_list}
				EOV
			done
		done
	fi
}

# source required system libraries
#
if [ -r "/lib/functions.sh" ] && [ -r "/lib/functions/network.sh" ] && [ -r "/usr/share/libubox/jshn.sh" ]; then
	. "/lib/functions.sh"
	. "/lib/functions/network.sh"
	. "/usr/share/libubox/jshn.sh"
else
	f_log "err" "system libraries not found"
fi

# control travelmate actions
#
while true; do
	if [ "${trm_action}" = "stop" ]; then
		if [ -s "${trm_pidfile}" ]; then
			f_log "info" "travelmate instance stopped ::: action: ${trm_action}, pid: $(cat ${trm_pidfile} 2>/dev/null)"
			: >"${trm_rtfile}"
			: >"${trm_pidfile}"
		fi
		break
	elif [ -n "${trm_action}" ]; then
		f_log "info" "travelmate instance started ::: action: ${trm_action}, pid: ${$}"
		f_env
		f_main
		unset trm_action
	fi
	while true; do
		sleep "${trm_timeout}" 0
		rc="${?}"
		if [ "${rc}" != "0" ]; then
			if [ -z "$(f_getgw)" ]; then
				rc="0"
			fi
		fi
		if [ "${rc}" = "0" ]; then
			break
		fi
	done
	json_cleanup
	f_env
	f_main
done
