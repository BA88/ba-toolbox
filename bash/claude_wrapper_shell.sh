#!/usr/bin/env bash
# Claude CLI wrapper: direnv env vars, cwd default name, CLI overrides.
#
# Install (once in ~/.bashrc or ~/.bash_aliases):
#   source "/path/to/claude_wrapper_shell.sh"
#
# Per-project (.envrc via direnv):
#   export CLAUDE_WRAPPER_NAME='CC-My Project'
#   export CLAUDE_WRAPPER_COLOR='green'
#
# Priority for --name:
#   1. --name on the command line (value optional; see below)
#   2. CLAUDE_WRAPPER_NAME when set
#   3. Default: basename of $PWD
#   Then, if --now (or CLAUDE_WRAPPER_ENABLE_NOW): append timestamp.
#
# --name with no value (missing, empty, or next token is any flag) uses
# basename of $PWD. Flags include /color, --color, --now, and - options.
#
# Priority for color:
#   1. /color COLOR or --color COLOR when COLOR is non-empty on the CLI
#   2. CLAUDE_WRAPPER_COLOR when set
#   3. CLAUDE_WRAPPER_DEFAULT_COLOR (default: default)
#
# Bare --color or /color with no COLOR uses steps 2-3 (not random /color).
#
# Color is always the last argv word: "/color NAME". Omitting it lets the
# CLI pick a non-default hue; the wrapper always passes an explicit color.
#
# Wrapper-only flag (stripped, not passed to claude):
#   --now  Append local date and time to the resolved session name.
#
# Help:
#   -h, --help     Claude CLI help (no --name or /color injection).
#   -H, --HELP     This wrapper's help (SCRIPT help).
#
# Debug: CLAUDE_WRAPPER_DEBUG=1 prints path and resolved command.
#
# Timezone: date(1) uses the process timezone. Set TZ for a zone, e.g.
#   export TZ=America/New_York
# Unset TZ uses the system default. This is the usual Unix convention.
#
# Examples:
#   claude                       # ... --name ... '/color default' last
#   claude -p 'hello'            # -p hello --name ... '/color default' last
#   claude --now                 # my_project 2026-05-17 14:32
#   claude --name 'Other'        # Other
#   claude '/color blue'         # '/color blue' last
#   claude --color blue          # same as /color blue
#   claude --name -p 'hello'     # -p is a flag; session name is cwd tail
#   claude --help                # Claude help (no injection)
#   claude -H                    # wrapper help


# Absolute path to this file (set when sourced or executed).
if [[ -n "${BASH_SOURCE[0]:-}" ]]; then
  _script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  export CLAUDE_WRAPPER_PATH="${_script_dir}/$(basename "${BASH_SOURCE[0]}")"
  unset _script_dir
fi

# Return 0 if $@ contains a token equal to NEEDLE.
_claude_argv_includes() {
  local needle="$1"
  shift
  local x
  for x in "$@"; do
    [[ "$x" == "$needle" ]] && return 0
  done
  return 1
}

# Return 0 if the user asked for this wrapper's help (-H / --HELP).
_claude_wants_script_help() {
  _claude_argv_includes -H "$@" && return 0
  _claude_argv_includes --HELP "$@" && return 0
  return 1
}

# Return 0 if the user asked for Claude CLI help (-h / --help).
_claude_wants_claude_help() {
  _claude_argv_includes -h "$@" && return 0
  _claude_argv_includes --help "$@" && return 0
  return 1
}

# Build argv for Claude help: drop wrapper-only tokens, forward the rest.
_claude_passthrough_for_claude_help() {
  _claude_filtered_args=()
  local arg
  for arg in "$@"; do
    case "$arg" in
      --now | -H | --HELP) ;;
      *) _claude_filtered_args+=("$arg") ;;
    esac
  done
}

# Print wrapper usage (stdout). See -H / --HELP.
_claude_print_help() {
  cat <<'EOF'
A shell wrapper for the Claude CLI (session name and terminal color).

Usage: claude [OPTIONS] [CLAUDE_ARGS]...

Arguments:
  [CLAUDE_ARGS]...
          Arguments passed to the real claude program (optional)

Options:
  --color <COLOR>
  /color <COLOR>
          Claude prompt bar color for this session
  -h, --help
          Show real Claude CLI help
  -H, --HELP
          Show this wrapper help
  --name [<NAME>]
          Session title shown in Claude (directory name if NAME omitted)
  --now
          Add the current date and time to the session title

Environment variable options:
  CLAUDE_WRAPPER_COLOR
          Default prompt bar color when --color or /color not specified
  CLAUDE_WRAPPER_DEBUG
          Print the resolved command line before starting Claude
  CLAUDE_WRAPPER_DEFAULT_COLOR
          Prompt bar color when nothing else is set
  CLAUDE_WRAPPER_ENABLE_NOW
          Always add date and time to the session title
  CLAUDE_WRAPPER_NAME
          Default session title when you do not pass --name
  CLAUDE_WRAPPER_PATH
          Full path to this script (set when you source the file)
  TZ
          Time zone used for --now timestamps

Examples:
  claude
          Start Claude; session title is this directory basename; color is random
  claude --name 'CC•My Project'
          Session title CC•My Project; color from env or random
  claude --now
          Session title is directory basename plus current date and time
  claude --color blue
          Blue prompt bar color for this session
  claude --color
          prompt bar color from CLAUDE_WRAPPER_COLOR, or random if unset
  claude --help
          Claude program help only
  claude -H
          This help text
EOF
  local path="${CLAUDE_WRAPPER_PATH:-/path/to/claude_wrapper_shell.sh}"
  cat <<EOF

Install:
  Add to shell profile (eg, ~/.bashrc), once for all projects:
    source '${path}'

  Per-project (eg, add to direnv's .envrc):
    source '${path}'
    export CLAUDE_WRAPPER_NAME='CC•My Project'
    export CLAUDE_WRAPPER_COLOR='red'
    export CLAUDE_WRAPPER_ENABLE_NOW=1

  CLAUDE_WRAPPER_PATH is set to this file's full pathname when sourced.
EOF
}

# Return whether a word may be used as the value following --name.
#
# --name sets the Claude session title, not a Unix username. Used while
# parsing the invocation: after --name, the next token is passed here.
# Success means consume it as the session name; failure means no value was
# given and the parser uses basename of $PWD.
#
# Args:
#   $1: Candidate token (the word immediately after --name).
#
# Returns:
#   0 if t is a non-empty string and not a flag (see below).
#   1 if t is empty, is /color*, a wrapper flag, or starts with -.
#
# Examples:
#   _claude_is_name_value_token 'CC-AT'  # success
#   _claude_is_name_value_token ''       # failure (empty)
#   _claude_is_name_value_token --now    # failure (- flag)
#   _claude_is_name_value_token -p       # failure (- flag)
#   _claude_is_name_value_token /color   # failure (/color)
_claude_is_name_value_token() {
  local t="$1"
  [[ -n "$t" ]] || return 1
  [[ "$t" == /color* || "$t" == --color || "$t" == --now \
    || "$t" == --name ]] && return 1
  [[ "$t" == -* ]] && return 1
  return 0
}

# Parse claude invocation args into filtered passthrough and side effects.
#
# Reads "$@" and sets:
#   _claude_filtered_args     Words forwarded (no color; color goes last).
#   _claude_session_name_set  True if user passed --name.
#   _claude_session_name      Value after --name, or basename $PWD if none.
#   _claude_use_now           True if user passed --now.
#   _claude_has_color         True if user passed /color or --color.
#   _claude_color_value       Color name from CLI (may be empty).
#
# Strips --now, --name (+ value), and color flags from the forwarded list.
_claude_parse_invoke_args() {
  _claude_filtered_args=()
  _claude_session_name_set=false
  _claude_session_name=
  _claude_use_now=false
  _claude_has_color=false
  _claude_color_value=
  local -a args=("$@")
  local i=0
  while (( i < ${#args[@]} )); do
    case "${args[i]}" in
      --now)
        _claude_use_now=true
        ;;
      --name)
        _claude_session_name_set=true
        if (( i + 1 < ${#args[@]} )) \
          && _claude_is_name_value_token "${args[i + 1]}"; then
          _claude_session_name="${args[i + 1]}"
          i=$((i + 2))
          continue
        else
          _claude_session_name="$(basename "$PWD")"
          i=$((i + 1))
          continue
        fi
        ;;
      --color)
        _claude_has_color=true
        if (( i + 1 < ${#args[@]} )); then
          _claude_color_value="${args[i + 1]}"
          i=$((i + 2))
          continue
        fi
        i=$((i + 1))
        continue
        ;;
      /color*)
        _claude_has_color=true
        if [[ "${args[i]}" == /color ]]; then
          if (( i + 1 < ${#args[@]} )); then
            _claude_color_value="${args[i + 1]}"
            i=$((i + 2))
            continue
          fi
        else
          _claude_color_value="${args[i]#/color}"
          _claude_color_value="${_claude_color_value# }"
        fi
        i=$((i + 1))
        continue
        ;;
      *)
        _claude_filtered_args+=("${args[i]}")
        ;;
    esac
    i=$((i + 1))
  done
}

# Build trailing "/color NAME" from CLI, env, or default (see file header).
#
# Sets _claude_color_tail (always non-empty).
_claude_resolve_color_tail() {
  local color_name
  if $_claude_has_color && [[ -n "${_claude_color_value:-}" ]]; then
    color_name="$_claude_color_value"
  elif [[ -n "${CLAUDE_WRAPPER_COLOR:-}" ]]; then
    color_name="$CLAUDE_WRAPPER_COLOR"
  else
    color_name="${CLAUDE_WRAPPER_DEFAULT_COLOR:-default}"
  fi
  if [[ -n "$color_name" ]]; then
    _claude_color_tail="/color ${color_name}"
  else
    _claude_color_tail="/color"
  fi
}

# Wrapper for the Claude CLI: inject --name and trailing /color when needed.
#
# Forwards user args first, then --name, then "/color NAME" last always.
#
# Environment variables:
#   CLAUDE_WRAPPER_PATH:          Absolute path to this script (on source).
#   CLAUDE_WRAPPER_NAME:          Session name when user omits --name.
#   CLAUDE_WRAPPER_COLOR:         Used when CLI omits COLOR name.
#   CLAUDE_WRAPPER_DEFAULT_COLOR: When no CLI/env color (default: default).
#   CLAUDE_WRAPPER_ENABLE_NOW:    If non-empty, always append timestamp.
#   CLAUDE_WRAPPER_DEBUG:         If non-empty, print path and command.
#   TZ:                              Optional timezone for --now (see header).
#
# Args:
#   $@: All arguments; wrapper flags are stripped, rest forwarded.
#
# Returns:
#   Exit status of command claude (passthrough).
#
# Examples (PWD basename my_project; env unset unless noted):
#
# +----------------------------------+--------------------------------+
# | User runs                        | Result argv pattern            |
# +----------------------------------+--------------------------------+
# | claude (no color env)            | --name X '/color default' last |
# | claude -p 'hello'                | -p hello --name X '/color ...' |
# | claude --color blue --resume     | --resume --name X '/color blue'|
# | CLAUDE_WRAPPER_COLOR=green     | --name X '/color green' last   |
# |   claude                         |                                |
# +----------------------------------+--------------------------------+
claude() {
  if _claude_wants_script_help "$@"; then
    _claude_print_help
    return 0
  fi

  if _claude_wants_claude_help "$@"; then
    _claude_passthrough_for_claude_help "$@"
    if [[ -n "${CLAUDE_WRAPPER_DEBUG:-}" ]]; then
      printf '# CLAUDE_WRAPPER_PATH=%q\n' \
        "${CLAUDE_WRAPPER_PATH:-}"
      printf 'command claude'
      printf ' %q' "${_claude_filtered_args[@]}"
      printf '\n'
    fi
    command claude "${_claude_filtered_args[@]}"
    return $?
  fi

  _claude_parse_invoke_args "$@"

  if [[ -n "${CLAUDE_WRAPPER_ENABLE_NOW:-}" ]]; then
    _claude_use_now=true
  fi

  local final_name
  if $_claude_session_name_set; then
    final_name="$_claude_session_name"
  elif [[ -n "${CLAUDE_WRAPPER_NAME:-}" ]]; then
    final_name="$CLAUDE_WRAPPER_NAME"
  else
    final_name="$(basename "$PWD")"
  fi

  if $_claude_use_now; then
    final_name="${final_name} $(date '+%Y-%m-%d %H:%M')"
  fi

  _claude_resolve_color_tail

  local -a name_args=(--name "$final_name")
  local -a color_args=("${_claude_color_tail}")

  if [[ -n "${CLAUDE_WRAPPER_DEBUG:-}" ]]; then
    printf '# CLAUDE_WRAPPER_PATH=%q\n' "${CLAUDE_WRAPPER_PATH:-}"
    printf 'command claude'
    printf ' %q' "${_claude_filtered_args[@]}" "${name_args[@]}" \
      "${color_args[@]}"
    printf '\n'
  fi

  command claude "${_claude_filtered_args[@]}" "${name_args[@]}" \
    "${color_args[@]}"
}
