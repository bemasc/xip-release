#!/usr/bin/env bash
set -e
shopt -s nocasematch

#
# Configuration
#
XIP_DOMAIN="xip.test"
XIP_ROOT_ADDRESSES=( "127.0.0.1" )
XIP_NS_ADDRESSES=( "127.0.0.1" )
XIP_MX_RECORDS=( )
XIP_MX_DOMAINKEYS=( )
XIP_TXT_RECORDS=( )
XIP_TIMESTAMP="0"
XIP_TTL=300

if [ -a "$1" ]; then
  source "$1"
fi


#
# Protocol helpers
#
read_cmd() {
  local IFS=$'\t'
  local i=0
  local arg

  read -ra CMD
  for arg; do
    eval "$arg=\"\${CMD[$i]}\""
    let i=i+1
  done
}

send_cmd() {
  local IFS=$'\t'
  printf "%s\n" "$*"
}

fail() {
  send_cmd "FAIL"
  log "Exiting"
  exit 1
}

read_helo() {
  read_cmd HELO VERSION
  [ "$HELO" = "HELO" ] && [ "$VERSION" = "1" ]
}

read_query() {
  read_cmd TYPE QNAME QCLASS QTYPE ID IP
}

send_answer() {
  local type="$1"
  shift
  send_cmd "DATA" "$QNAME" "$QCLASS" "$type" "$XIP_TTL" "$ID" "$@"
}

log() {
  printf "[xip-pdns:$$] %s\n" "$@" >&2
}


#
# xip.io domain helpers
#
XIP_DOMAIN_PATTERN="(^|\.)${XIP_DOMAIN//./\.}\$"
NS_SUBDOMAIN_PATTERN="^ns-([0-9]+)\$"
IP_SUBDOMAIN_PATTERN="(^|\.)(((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?))\$"
DASHED_IP_SUBDOMAIN_PATTERN="(^|-|\.)(((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)-){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?))\$"
BASE36_SUBDOMAIN_PATTERN="(^|\.)([a-z0-9]{1,7})\$"

qtype_is() {
  [ "$QTYPE" = "$1" ] || [ "$QTYPE" = "ANY" ]
}

qname_matches_domain() {
  [[ "$QNAME" =~ $XIP_DOMAIN_PATTERN ]]
}

qname_is_root_domain() {
  [ "$QNAME" = "$XIP_DOMAIN" ]
}

qname_is_mx_domainkey() {
  [ "$QNAME" = "mx._domainkey.$XIP_DOMAIN" ]
}

extract_subdomain_from_qname() {
  SUBDOMAIN="${QNAME:0:${#QNAME}-${#XIP_DOMAIN}}"
  SUBDOMAIN="${SUBDOMAIN%.}"
}

subdomain_is_ns() {
  [[ "$SUBDOMAIN" =~ $NS_SUBDOMAIN_PATTERN ]]
}

subdomain_is_ip() {
  [[ "$SUBDOMAIN" =~ $IP_SUBDOMAIN_PATTERN ]]
}

subdomain_is_dashed_ip() {
  [[ "$SUBDOMAIN" =~ $DASHED_IP_SUBDOMAIN_PATTERN ]]
}

subdomain_is_base36() {
  [[ "$SUBDOMAIN" =~ $BASE36_SUBDOMAIN_PATTERN ]]
}

resolve_ns_subdomain() {
  local index="${SUBDOMAIN:3}"
  echo "${XIP_NS_ADDRESSES[$index-1]}"
}

resolve_ip_subdomain() {
  [[ "$SUBDOMAIN" =~ $IP_SUBDOMAIN_PATTERN ]] || true
  echo "${BASH_REMATCH[2]}"
}

resolve_dashed_ip_subdomain() {
  [[ "$SUBDOMAIN" =~ $DASHED_IP_SUBDOMAIN_PATTERN ]] || true
  echo "${BASH_REMATCH[2]//-/.}"
}

resolve_base36_subdomain() {
  [[ "$SUBDOMAIN" =~ $BASE36_SUBDOMAIN_PATTERN ]] || true
  local ip=$(( 36#${BASH_REMATCH[2]} ))
  printf "%d.%d.%d.%d" $(( ip&0xFF )) $(( (ip>>8)&0xFF )) $(( (ip>>16)&0xFF )) $(( (ip>>24)&0xFF ))
}

answer_soa_query() {
  send_answer "SOA" "admin.$XIP_DOMAIN ns-1.$XIP_DOMAIN $XIP_TIMESTAMP $XIP_TTL $XIP_TTL $XIP_TTL $XIP_TTL"
}

answer_ns_query() {
  local i=1
  local ns_address
  for ns_address in "${XIP_NS_ADDRESSES[@]}"; do
    send_answer "NS" "ns-$i.$XIP_DOMAIN"
    let i+=1
  done
}

answer_root_a_query() {
  local address
  for address in "${XIP_ROOT_ADDRESSES[@]}"; do
    send_answer "A" "$address"
  done
}

answer_mx_query() {
  set -- "${XIP_MX_RECORDS[@]}"
  while [ $# -gt 1 ]; do
    send_answer "MX" "$1	$2"
  shift 2
  done
}

answer_mx_domainkey_query() {
  for rdata in "${XIP_MX_DOMAINKEYS[@]}"; do
    send_answer "TXT" "$rdata"
  done
}

answer_txt_query() {
  for rdata in "${XIP_TXT_RECORDS[@]}"; do
    send_answer "TXT" "$rdata"
  done
}

answer_subdomain_a_query_for() {
  local type="$1"
  local address="$(resolve_${type}_subdomain)"
  if [ -n "$address" ]; then
    send_answer "A" "$address"
  fi
}


#
# PowerDNS pipe backend implementation
#
trap fail err
read_helo
send_cmd "OK" "xip.io PowerDNS pipe backend (protocol version 1)"

while read_query; do
  log "Query: type=$TYPE qname=$QNAME qclass=$QCLASS qtype=$QTYPE id=$ID ip=$IP"

  if qname_matches_domain; then
    if qname_is_root_domain; then
      if qtype_is "SOA"; then
        answer_soa_query
      fi

      if qtype_is "NS"; then
        answer_ns_query
      fi

      if qtype_is "A"; then
        answer_root_a_query
      fi

      if qtype_is "MX"; then
        answer_mx_query
      fi

      if qtype_is "TXT"; then
        answer_txt_query
      fi

    elif qname_is_mx_domainkey; then
      if qtype_is "TXT"; then
        answer_mx_domainkey_query
      fi

    elif qtype_is "A"; then
      extract_subdomain_from_qname

      if subdomain_is_ns; then
        answer_subdomain_a_query_for ns

      elif subdomain_is_dashed_ip; then
        answer_subdomain_a_query_for dashed_ip

      elif subdomain_is_ip; then
        answer_subdomain_a_query_for ip

      elif subdomain_is_base36; then
        answer_subdomain_a_query_for base36
      fi
    fi
  fi

  send_cmd "END"
done
