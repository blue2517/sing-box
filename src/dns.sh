is_dns_list=(
    1.1.1.1
    8.8.8.8
    h3://dns.google/dns-query
    h3://cloudflare-dns.com/dns-query
    h3://family.cloudflare-dns.com/dns-query
    local
    ipv4-only
    dual
    set
    none
)

_dns_write_json() {
    local new_json
    new_json=$(jq "$1" "$is_config_json") || err "更新 DNS 配置失败: jq 处理异常."
    [[ -z $new_json ]] && err "更新 DNS 配置失败: 输出为空."
    printf '%s\n' "$new_json" >"$is_config_json"
}

dns_set() {
    [[ ! -f $is_config_json ]] && err "找不到主配置文件: $is_config_json"
    if [[ $(echo -e "1.11.99\n$is_core_ver" | sort -V | head -n1) == '1.11.99' ]]; then
        is_dns_new=1
    fi
    if [[ $1 ]]; then
        case ${1,,} in
        11 | 1111)
            is_dns_use=${is_dns_list[0]}
            ;;
        88 | 8888)
            is_dns_use=${is_dns_list[1]}
            ;;
        gg | google)
            is_dns_use=${is_dns_list[2]}
            ;;
        cf | cloudflare)
            is_dns_use=${is_dns_list[3]}
            ;;
        nosex | family)
            is_dns_use=${is_dns_list[4]}
            ;;
        local)
            is_dns_use=local
            ;;
        ipv4 | ipv4-only | ipv4_only)
            is_dns_use=ipv4-only
            ;;
        dual | ipv6 | ipv6-on | ipv6_on)
            is_dns_use=dual
            ;;
        set)
            if [[ $2 ]]; then
                is_dns_use=${2,,}
            else
                ask string is_dns_use "请输入 DNS: "
            fi
            ;;
        none)
            is_dns_use=none
            ;;
        *)
            err "无法识别 DNS 参数: $@"
            ;;
        esac
    else
        is_tmp_list=(${is_dns_list[@]})
        ask list is_dns_use null "\n请选择 DNS:\n"
        if [[ $is_dns_use == "set" ]]; then
            ask string is_dns_use "请输入 DNS: "
        fi
    fi
    is_dns_use_bak=$is_dns_use
    case $is_dns_use in
    none)
        _dns_write_json '.dns={} | del(.route.default_domain_resolver)'
        ;;
    local)
        if [[ $is_dns_new ]]; then
            _dns_write_json '
              .dns = ((.dns // {}) | .servers = [{tag:"local",type:"local"}]) |
              .route = ((.route // {}) |
                .default_domain_resolver = (
                  if (.default_domain_resolver | type) == "object" then
                    .default_domain_resolver + {server: "local"}
                  else
                    "local"
                  end
                )
              )
            '
        else
            _dns_write_json '.dns.servers=[{tag:"local",address:"local"}]'
        fi
        ;;
    ipv4-only)
        if [[ $is_dns_new ]]; then
            _dns_write_json '
              .dns = ((.dns // {}) |
                .strategy = "ipv4_only" |
                .servers = (
                  if (.servers | type) == "array" and (.servers | length) > 0 then
                    .servers
                  else
                    [{tag:"local",type:"local"}]
                  end
                )
              ) |
              .route = ((.route // {}) |
                .final = (.final // "direct") |
                .default_domain_resolver = (
                  if (.default_domain_resolver | type) == "object" then
                    .default_domain_resolver + {server: (.default_domain_resolver.server // "local"), strategy: "ipv4_only"}
                  elif (.default_domain_resolver | type) == "string" and (.default_domain_resolver | length) > 0 then
                    {server: .default_domain_resolver, strategy: "ipv4_only"}
                  else
                    {server: "local", strategy: "ipv4_only"}
                  end
                ) |
                .rules = (
                  (.rules // []) |
                  if any(.[]; .ip_version == 6 and .action == "reject") then .
                  else . + [{ip_version: 6, action: "reject"}]
                  end
                )
              )
            '
        else
            _dns_write_json '
              .dns = ((.dns // {}) | .strategy = "ipv4_only") |
              .route = ((.route // {}) | .final = (.final // "direct"))
            '
        fi
        ;;
    dual)
        _dns_write_json '
          .dns = ((.dns // {}) | del(.strategy)) |
          if (.route | type) == "object" then
            .route |= (
              if (.default_domain_resolver | type) == "object" then
                .default_domain_resolver |= del(.strategy) |
                if (.default_domain_resolver | keys) == ["server"] then
                  .default_domain_resolver = .default_domain_resolver.server
                else . end
              else . end |
              if (.rules | type) == "array" then
                .rules |= map(select((.ip_version == 6 and .action == "reject") | not)) |
                if (.rules | length) == 0 then del(.rules) else . end
              else . end
            )
          else . end
        '
        ;;
    *)
        if [[ $is_dns_new ]]; then
            dns_set_server $is_dns_use
            _dns_write_json '
              .dns = ((.dns // {}) | .servers = [{tag:"dns",type:"'$is_dns_type'",server:"'$is_dns_use'",domain_resolver:"local"},{tag:"local",type:"local"}]) |
              .route = ((.route // {}) |
                .default_domain_resolver = (
                  if (.default_domain_resolver | type) == "object" then
                    .default_domain_resolver + {server: "dns"}
                  else
                    "dns"
                  end
                )
              )
            '
        else
            _dns_write_json '.dns.servers=[{address:"'$is_dns_use'",address_resolver:"local"},{tag:"local",address:"local"}]'
        fi
        ;;
    esac
    manage restart &
    msg "\n已更新 DNS 为: $(_green $is_dns_use_bak)\n"
}

dns_set_server() {
    if [[ $(grep '://' <<<$1) ]]; then
        is_tmp_dns_set=($(awk -F '://|/' '{print $1, $2}' <<<${1,,}))
        case ${is_tmp_dns_set[0]} in
        tcp | udp | tls | https | quic | h3)
            is_dns_use=${is_tmp_dns_set[1]}
            is_dns_type=${is_tmp_dns_set[0]}
            ;;
        *)
            err "无法识别 DNS 类型!"
            ;;
        esac
    else
        is_dns_use=$1
        is_dns_type=udp
    fi
}
