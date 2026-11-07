# /etc/profile resets PATH in login shells, which Orca's terminals are. Debian's skeleton ~/.profile
# would add ~/.local/bin back, but the home volume hides it, so claude wouldn't be found.
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) PATH="$HOME/.local/bin:$PATH" ;;
esac
