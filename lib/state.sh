#!/usr/bin/env bash
# 「内容が変わったときだけ」「一定期間が過ぎたときだけ」処理を走らせるための状態記録。
#
# chezmoi の run_onchange_ / refreshPeriod に相当する最小の仕組み。宣言（利用側の設定）と
# 実際の状態（配置先の内容など）を 1 つのハッシュに畳んで記録し、次回それが一致していれば
# 処理ごと飛ばす。どちらかが変われば（宣言を直した / 外で消された・書き換えられた）再実行に
# なるので、「宣言を変えたのに反映されない」も「外で壊れたのに直らない」も起きない。
#
# 使い方（宣言だけでなく現状も畳むこと。宣言だけを見ると外部での変更に気付けない）:
#   source "$BOOCH_ROOT/lib/state.sh"
#   want=$(booch_hash_args "$name" "$@" -- "$current_state")
#   if booch_state_changed "$id" "$want"; then
#     do_something || return 1
#     booch_state_record "$id" "$(booch_hash_args "$name" "$@" -- "$new_state")"
#   fi
#
#   booch_state_fresh "$id" 86400 || { do_daily_task; booch_state_touch "$id"; }
#
# **上流の版に追従する処理をこれで囲まないこと。** apt / npm のレンジ指定 / プラグインのように
# 「宣言が変わらなくても更新が要る」ものを囲むと、宣言を直すまで古い版で止まる。対象は
# 「宣言と配置先だけで結果が決まる処理」に限る。
#
# 記録の置き場は BOOCH_STATE_DIR。未設定なら呼び出しのたびに
# ${XDG_CACHE_HOME:-$HOME/.cache}/booch/state を使う。キャッシュ配下に置くのは、消えても
# 「もう一度実行される」だけで害が無いため（消えると困る情報は持たない）。既定を変える利用側は、
# ジョブ（別プロセス）からも同じ置き場を見るよう自分で export する。
#
# 判定できないとき（sha256sum が無い、記録が読めない）は、常に「実行が要る」側へ倒す。
#
# 依存: sha256sum, stat, date, mkdir, touch（GNU coreutils）。

# id に対応する記録ファイルのパス。id は利用側が組み立てるラベルで、設定名やサーバー名が
# 入るので、英数と ._- 以外をパーセントエンコード（%XX）する。変換は単射なので別々の id が
# 同じファイルに当たらず、パス区切りでディレクトリを掘ることもない。先頭の . も符号化して、
# 隠しファイルや . / .. にならないようにする。空の id は「%」（符号化では現れない名前）にする。
_booch_state_file() { # id
  local id=$1 name="" c i LC_ALL=C
  for ((i = 0; i < ${#id}; i++)); do
    c=${id:i:1}
    if [[ $c == [A-Za-z0-9_-] || ($c == . && i -gt 0) ]]; then
      name+=$c
    else
      name+=$(printf '%%%02X' "'$c")
    fi
  done
  printf '%s/%s\n' "${BOOCH_STATE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/booch/state}" "${name:-%}"
}

# 引数列を 1 つのハッシュに畳む。区切りは NUL なので、値に空白や改行が入っても隣の引数と
# 混ざらない。sha256sum が無い環境では空を返す（booch_state_changed は「変わった」扱いにする）。
booch_hash_args() { # str...
  command -v sha256sum >/dev/null 2>&1 || return 0
  printf '%s\0' "$@" | sha256sum | cut -d' ' -f1
}

# 記録と hash が違えば 0（= 実行が要る）。未記録と、hash が空（ハッシュを取れない環境）も
# 「変わった」扱いにする。
booch_state_changed() { # id hash
  local hash=$2 file
  [ -n "$hash" ] || return 0
  file=$(_booch_state_file "$1")
  [ "$(cat "$file" 2>/dev/null)" != "$hash" ]
}

# 処理が成功したあとに hash を記録する。空の hash は記録しない（次回も実行される）。
booch_state_record() { # id hash
  local hash=$2 file
  [ -n "$hash" ] || return 0
  file=$(_booch_state_file "$1")
  mkdir -p "${file%/*}" || return 1
  printf '%s\n' "$hash" > "$file"
}

# 最後に booch_state_touch してから max_age 秒が過ぎていなければ 0（= まだ実行しなくてよい）。
# 記録が無い（stat が失敗する）、mtime が未来（時計が進んだ状態で touch した）ときは「古い」
# 扱いにする。未来のまま fresh と見なすと、時計が追いつくまで処理が飛ばされ続ける。
booch_state_fresh() { # id max_age_sec
  local max_age=$2 file mtime age
  file=$(_booch_state_file "$1")
  mtime=$(stat -c %Y "$file" 2>/dev/null) || return 1
  age=$(($(date +%s) - mtime))
  [ "$age" -ge 0 ] && [ "$age" -lt "$max_age" ]
}

# 実行した時刻を記録する（booch_state_fresh と対）。
booch_state_touch() { # id
  local file; file=$(_booch_state_file "$1")
  mkdir -p "${file%/*}" || return 1
  touch "$file"
}
