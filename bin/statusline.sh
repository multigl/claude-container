#!/bin/sh
# Default status line for both flavors -- robbyrussell-inspired.
# Mounted over at /opt/claude/statusline.sh if the host has a
# script at ~/.claude/statusline-command.sh; otherwise this fallback is used.
input=$(cat)

cwd=$(echo "$input" | jq -r '.workspace.current_dir // .cwd')
# Container mounts host $PWD -> /workspace, so basename "$cwd" is always
# "workspace". CLAUDE_HOST_DIR (injected by the launcher) carries the real host
# path; fall back to $cwd when it is unset (e.g. running the script outside the
# container).
dir=$(basename "${CLAUDE_HOST_DIR:-$cwd}")

model=$(echo "$input" | jq -r '.model.display_name // ""')

remaining=$(echo "$input" | jq -r '.context_window.remaining_percentage // empty')

branch=$(git -C "$cwd" symbolic-ref --short HEAD 2>/dev/null || git -C "$cwd" rev-parse --short HEAD 2>/dev/null)

if [ -n "$branch" ]; then
  git_part=$(printf "\033[1;34mgit:(\033[0;31m%s\033[1;34m)\033[0m" "$branch")
  dir_git=$(printf "\033[0;36m%s\033[0m %s" "$dir" "$git_part")
else
  dir_git=$(printf "\033[0;36m%s\033[0m" "$dir")
fi

if [ -n "$remaining" ]; then
  suffix=$(printf "\033[2m%s  ctx: %s%% left\033[0m" "$model" "$remaining")
else
  suffix=$(printf "\033[2m%s\033[0m" "$model")
fi

# Flavor badge: baked per-image as CLAUDE_FLAVOR_NAME. vertex=green, gateway=magenta.
case "$CLAUDE_FLAVOR_NAME" in
  vertex)  badge=$(printf "\033[1;32m[%s]\033[0m " "$CLAUDE_FLAVOR_NAME") ;;
  gateway) badge=$(printf "\033[1;35m[%s]\033[0m " "$CLAUDE_FLAVOR_NAME") ;;
  ?*)      badge=$(printf "\033[1m[%s]\033[0m " "$CLAUDE_FLAVOR_NAME") ;;
  *)       badge="" ;;
esac

printf "%s%s  %s\n" "$badge" "$dir_git" "$suffix"
