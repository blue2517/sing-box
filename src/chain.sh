# 链式代理管理模块：为任意入站绑定上游 SOCKS5 出站与分流规则

_chain_urldecode() {
    local s=$1
    printf '%b' "${s//%/\\x}"
}

chain_parse_socks_url() {
    local raw=${1%%#*}
    raw=${raw%/}
    chain_user=
    chain_pass=
    chain_server=
    chain_port=

    raw=${raw#socks5://}
    raw=${raw#socks://}
    [[ -z $raw ]] && err "SOCKS5 地址不能为空."

    local hostport=$raw
    if [[ $raw == *@* ]]; then
        local auth=${raw%@*}
        hostport=${raw##*@}
        if [[ $auth == *:* ]]; then
            chain_user=$(_chain_urldecode "${auth%%:*}")
            chain_pass=$(_chain_urldecode "${auth#*:}")
        else
            chain_user=$(_chain_urldecode "$auth")
        fi
    fi

    [[ $hostport != *:* ]] && err "SOCKS5 地址缺少端口: $1"
    chain_port=${hostport##*:}
    chain_server=${hostport%:*}
    chain_server=${chain_server#[}
    chain_server=${chain_server%]}

    [[ -z $chain_server ]] && err "无法解析 SOCKS5 服务器地址: $1"
    if [[ ! $(is_test port "$chain_port") ]]; then
        err "无效的 SOCKS5 端口: $chain_port"
    fi
}

_ensure_config_json_route_final() {
    if [[ ! -f $is_config_json ]]; then
        create config.json
        return
    fi
    local has_final
    has_final=$(jq -r '.route.final // empty' "$is_config_json" 2>/dev/null)
    if [[ -z $has_final ]]; then
        local patched
        patched=$(jq '.outbounds = (if (.outbounds | type) == "array" and (.outbounds | length) > 0 then (if any(.outbounds[]; .tag == "direct") then .outbounds else .outbounds + [{tag: "direct", type: "direct"}] end) else [{tag: "direct", type: "direct"}] end) | .route = ((.route // {}) | .final = "direct")' "$is_config_json") || err "更新主配置 route.final 失败."
        printf '%s\n' "$patched" >"$is_config_json"
    fi
}

chain_set() {
    is_dont_show_info=1
    get info "$1"
    is_dont_show_info=

    local chain_url=$2
    local chain_bypass=$3
    if [[ ! $chain_url ]]; then
        ask string chain_url "请输入上游 SOCKS5 地址 (例如 socks5://user:pass@host:port, 或输入 off 解除):"
        if [[ ! ${chain_url,,} =~ ^(off|none|clear|direct)$ && ! $chain_bypass ]]; then
            echo -ne "可选: 直连绕过域名 (逗号分隔如 youtube.com,googlevideo.com, 直接回车跳过): "
            read -r chain_bypass
        fi
    fi

    local src_file="$is_conf_dir/$is_config_file"
    local old_tag
    old_tag=$(jq -r --arg d "$is_config_file" '.inbounds[0].tag // $d' "$src_file")

    local backup_file
    backup_file=$(mktemp)
    cp -pf "$src_file" "$backup_file"

    if [[ ${chain_url,,} =~ ^(off|none|clear|direct)$ ]]; then
        local target_name=$is_config_file
        if [[ $is_config_file == *-CHAIN-* ]]; then
            target_name=${is_config_file/-CHAIN-/-}
        fi
        local dst_file="$is_conf_dir/$target_name"

        local new_json
        new_json=$(jq --arg old_tag "$old_tag" --arg new_tag "$target_name" '
          .inbounds[0].tag = $new_tag |
          if (.outbounds | type) == "array" then
            .outbounds |= map(select(.type == "direct" or ((.tag // "") | startswith("public_key_")))) |
            if (.outbounds | length) == 0 then del(.outbounds) else . end
          else . end |
          if (.route | type) == "object" then
            if (.route.rules | type) == "array" then
              .route.rules |= map(select(((.inbound // []) | index($old_tag)) | not)) |
              if (.route.rules | length) == 0 then .route |= del(.rules) else . end
            else . end |
            if (.route | length) == 0 then del(.route) else . end
          else . end
        ' "$src_file") || { rm -f "$backup_file"; err "解除链式代理失败."; }

        if [[ $dst_file != "$src_file" ]]; then
            printf '%s\n' "$new_json" >"$dst_file"
            rm -f "$src_file"
            if ! _validate_singbox_config; then
                mv -f "$backup_file" "$src_file"
                rm -f "$dst_file"
                err "sing-box 配置校验失败, 已回滚: $src_file"
            fi
            rm -f "$backup_file"
        else
            _commit_config_json "$src_file" "$new_json" "$backup_file"
        fi
        manage restart &
        msg "\n已解除 ($is_config_file) 的链式代理, 恢复直连出网.\n"
        is_protocol=
        info "$target_name"
        return
    fi

    chain_parse_socks_url "$chain_url"
    _ensure_config_json_route_final

    local target_name=$is_config_file
    if [[ $is_config_file != *-CHAIN-* && $is_config_file == *"-${port}.json" ]]; then
        target_name="${is_config_file%-${port}.json}-CHAIN-${port}.json"
    fi
    local dst_file="$is_conf_dir/$target_name"
    local chain_tag="socks-chain-${port}"

    local bypass_json="[]"
    if [[ -n $chain_bypass ]]; then
        bypass_json=$(jq -R -c 'split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0))' <<<"$chain_bypass")
    fi

    local new_json
    new_json=$(jq \
        --arg old_tag "$old_tag" \
        --arg new_tag "$target_name" \
        --arg chain_tag "$chain_tag" \
        --arg srv "$chain_server" \
        --arg prt "$chain_port" \
        --arg usr "$chain_user" \
        --arg pwd "$chain_pass" \
        --argjson bypass "$bypass_json" '
      .inbounds[0].tag = $new_tag |
      (
        {tag: $chain_tag, type: "socks", server: $srv, server_port: ($prt | tonumber)} +
        (if ($usr | length) > 0 then {username: $usr} else {} end) +
        (if ($pwd | length) > 0 then {password: $pwd} else {} end)
      ) as $chain_out |
      .outbounds = (
        ((.outbounds // []) | map(select(((.tag // "") | startswith("public_key_")) or .type == "direct"))) + [$chain_out]
      ) |
      .route = (
        (.route // {}) |
        .rules = (
          ((.rules // []) | map(select((((.inbound // []) | index($old_tag)) | not) and (((.inbound // []) | index($new_tag)) | not)))) +
          (if ($bypass | length) > 0 then [{inbound: [$new_tag], action: "sniff"}, {inbound: [$new_tag], domain_suffix: $bypass, outbound: "direct"}] else [] end) +
          [{inbound: [$new_tag], action: "route", outbound: $chain_tag}]
        )
      )
    ' "$src_file") || { rm -f "$backup_file"; err "生成链式代理配置失败."; }

    if [[ $dst_file != "$src_file" ]]; then
        printf '%s\n' "$new_json" >"$dst_file"
        chmod 600 "$dst_file"
        rm -f "$src_file"
        if ! _validate_singbox_config; then
            mv -f "$backup_file" "$src_file"
            rm -f "$dst_file"
            err "sing-box 配置校验失败, 已回滚: $src_file"
        fi
        rm -f "$backup_file"
    else
        _commit_config_json "$src_file" "$new_json" "$backup_file" 600
    fi

    manage restart &
    msg "\n已为 ($target_name) 绑定上游链式代理: $(_green "${chain_server}:${chain_port}")\n"
    is_protocol=
    info "$target_name"
}
